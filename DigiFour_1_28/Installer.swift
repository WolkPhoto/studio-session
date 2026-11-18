import AppKit

/// Version 20.11: offers to copy Digi Suite into /Applications and keep it in
/// the Dock. An older copy in Applications goes to the Trash, never deleted.
@MainActor enum DigiInstaller {
    static let destination = URL(fileURLWithPath: "/Applications/\(DigiBrand.name).app", isDirectory: true)
    private static let neverAskKey = "DigiSuite.installPrompt.never"

    static var runningURL: URL { Bundle.main.bundleURL.standardizedFileURL }
    static var isInApplications: Bool { runningURL.path.hasPrefix("/Applications/") }

    /// Called once at launch. Silent when installed or when the user said not to ask.
    static func offerAtLaunch() {
        guard !isInApplications else { return }
        // The five apps show their tour first; the install offer follows it.
        if !DigiBrand.isClassic && !UserDefaults.standard.bool(forKey: "DigiBrand.tourFinished.v1") { return }
        guard !UserDefaults.standard.bool(forKey: neverAskKey) else { return }
        showInstallDialog(allowNeverAsk: true)
    }

    /// Called from the Digi Suite menu. Always shows something.
    static func offerFromMenu() {
        if !isInApplications {
            showInstallDialog(allowNeverAsk: false)
            return
        }
        if isInDock(runningURL.path) {
            simpleAlert("\(DigiBrand.name) is already installed", "It is in Applications and in the Dock.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add \(DigiBrand.name) to the Dock?"
        alert.informativeText = "\(DigiBrand.name) is installed in Applications but is not in the Dock."
        alert.addButton(withTitle: "Add to Dock")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if addToDock(runningURL.path) {
                simpleAlert("Added to the Dock", "The Dock refreshes for a moment.")
            } else {
                simpleAlert("Could not add to the Dock", "Drag \(DigiBrand.name) from Applications to the Dock instead.")
            }
        }
    }

    private static func showInstallDialog(allowNeverAsk: Bool) {
        let alert = NSAlert()
        alert.messageText = "Install \(DigiBrand.name) in Applications?"
        var info = "\(DigiBrand.name) is running from \(runningURL.deletingLastPathComponent().path). Installing copies it to Applications and reopens it from there."
        if FileManager.default.fileExists(atPath: destination.path) {
            info += " The copy already in Applications goes to the Trash."
        }
        alert.informativeText = info
        let dock = NSButton(checkboxWithTitle: "Keep in Dock", target: nil, action: nil)
        dock.state = .on
        alert.accessoryView = dock
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        if allowNeverAsk {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
        }
        let answer = alert.runModal()
        if allowNeverAsk, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: neverAskKey)
        }
        guard answer == .alertFirstButtonReturn else { return }
        install(keepInDock: dock.state == .on)
    }

    private static func install(keepInDock: Bool) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = [runningURL.path, destination.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0, fm.fileExists(atPath: destination.path) else {
                simpleAlert("Install did not finish", "\(DigiBrand.name) could not be copied to Applications. Nothing else was changed.")
                return
            }
        } catch {
            simpleAlert("Install did not finish", error.localizedDescription)
            return
        }
        var dockNote = ""
        if keepInDock && !isInDock(destination.path) && !addToDock(destination.path) {
            dockNote = " It could not be added to the Dock; drag it there from Applications."
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let note = dockNote
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, error in
            let problem = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let problem {
                        simpleAlert("Installed in Applications", "Open it from Applications." + note + " (" + problem + ")")
                    } else {
                        if !note.isEmpty { simpleAlert("Installed in Applications", note.trimmingCharacters(in: .whitespaces)) }
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    // MARK: Dock

    static func isInDock(_ path: String) -> Bool {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] else { return false }
        for app in apps {
            guard let tile = app["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let raw = file["_CFURLString"] as? String else { continue }
            let url: URL? = raw.hasPrefix("file://") ? URL(string: raw) : URL(fileURLWithPath: raw)
            if let url, url.standardizedFileURL.path == wanted { return true }
        }
        return false
    }

    @discardableResult
    static func addToDock(_ path: String) -> Bool {
        let entry = "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>\(path)</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
        guard run("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", entry]) else { return false }
        _ = run("/usr/bin/killall", ["Dock"])
        return true
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func simpleAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
