import AppKit
import Foundation

// v1.25: Check for Updates. Reads the latest release from GitHub
// (github.com/<owner>/<repo>/releases). The repository is set when the app is
// built (UPDATE_REPO in build.command, stored as DigiUpdateRepository in
// Info.plist). Nothing is installed automatically: the person sees what's new
// and clicks Download, which opens the release's DMG in their browser.

@MainActor
enum DigiUpdater {
    nonisolated static let autoKey = "DigiSuite.autoUpdateCheck"
    nonisolated static let lastCheckKey = "DigiSuite.lastUpdateCheck"
    nonisolated static let skipKey = "DigiSuite.skipUpdateVersion"

    nonisolated static var repository: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "DigiUpdateRepository") as? String ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    nonisolated static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    struct Release: Sendable {
        let version: String
        let notes: String
        let pageURL: URL?
        let downloadURL: URL?
    }

    /// "v1.26.0" > "1.25.3"? Compares number by number.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate)
        let b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func fetchLatest(_ repository: String) async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/" + repository + "/releases/latest") else {
            throw NSError(domain: "DigiUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "The update address isn't valid."])
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("StudioSession-UpdateCheck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 {
            throw NSError(domain: "DigiUpdater", code: 404, userInfo: [NSLocalizedDescriptionKey: "No published release was found. (The releases page may be private.)"])
        }
        guard code == 200 else {
            throw NSError(domain: "DigiUpdater", code: code, userInfo: [NSLocalizedDescriptionKey: "The update server answered \(code)."])
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "DigiUpdater", code: 2, userInfo: [NSLocalizedDescriptionKey: "The update information couldn't be read."])
        }
        let tag = object["tag_name"] as? String ?? ""
        let notes = object["body"] as? String ?? ""
        let page = (object["html_url"] as? String).flatMap { URL(string: $0) }
        var download: URL?
        if let assets = object["assets"] as? [[String: Any]] {
            for asset in assets {
                let name = (asset["name"] as? String ?? "").lowercased()
                if name.hasSuffix(".dmg"), let link = asset["browser_download_url"] as? String {
                    download = URL(string: link)
                    break
                }
            }
        }
        return Release(version: tag, notes: notes, pageURL: page, downloadURL: download)
    }

    /// From the menu: always says something, even "you're up to date".
    static func checkNow() {
        check(manual: true)
    }

    /// At launch: at most once a day, and only speaks up when there's an update.
    static func checkInBackgroundIfDue() {
        guard autoCheck, !repository.isEmpty else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        check(manual: false)
    }

    private static func check(manual: Bool) {
        let repo = repository
        guard !repo.isEmpty else {
            if manual { tell("Updates aren't set up for this copy", "This build of " + DigiBrand.name + " doesn't know where its updates are published.") }
            return
        }
        Task {
            do {
                let release = try await fetchLatest(repo)
                UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                let current = currentVersion
                guard isNewer(release.version, than: current) else {
                    if manual { tell("You're up to date", DigiBrand.name + " " + current + " is the newest version.") }
                    return
                }
                let clean = release.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                if !manual, UserDefaults.standard.string(forKey: skipKey) == clean { return }
                offer(release, version: clean, current: current)
            } catch {
                if manual { tell("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    private static func offer(_ release: Release, version: String, current: String) {
        let alert = NSAlert()
        alert.messageText = DigiBrand.name + " " + version + " is available"
        var notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 900 { notes = String(notes.prefix(900)) + "…" }
        alert.informativeText = "You have " + current + "." + (notes.isEmpty ? "" : "\n\nWhat's new:\n" + notes) +
            "\n\nQuit " + DigiBrand.name + " (after any backup finishes) before installing the new version."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        let answer = alert.runModal()
        if answer == .alertFirstButtonReturn {
            if let link = release.downloadURL ?? release.pageURL { NSWorkspace.shared.open(link) }
        } else if answer == .alertThirdButtonReturn {
            UserDefaults.standard.set(version, forKey: skipKey)
        }
    }

    private static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
