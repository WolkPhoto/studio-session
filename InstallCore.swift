import Foundation

/// v1.46.7: puts a new copy of the app in place without ever leaving Applications empty.
/// Before, the installer moved the old app to the Trash first and then copied the new one;
/// a failed copy (disk full, no permission) left no app in Applications, and the alert said
/// "Nothing else was changed" (second audit, Nov 11, F03). Now:
///   1. copy the new app next to the old one under a hidden staging name;
///   2. check the copy has its program inside;
///   3. move the old app aside (a rename on the same disk), move the new one into place;
///      if that fails, the old app is moved straight back;
///   4. only then does the old app go to the Trash (never deleted).
/// Foundation only, so the smoke tests can run it with fake bundles.
enum DigiInstallCore {
    struct Failure: Error {
        let message: String
        /// True when Applications is exactly as it was before the attempt.
        let unchanged: Bool
    }

    enum Outcome: Equatable {
        case installed
        /// Installed, but the old copy couldn't go to the Trash; it was renamed and left here.
        case installedOldKept(String)
    }

    /// The bundle's program: Contents/MacOS/<CFBundleExecutable> exists and can run.
    static func bundleLooksComplete(_ app: URL) -> Bool {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty else { return false }
        let program = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        return FileManager.default.isExecutableFile(atPath: program.path)
    }

    static func dittoCopy(_ source: URL, _ target: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [source.path, target.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "DigiInstall", code: Int(ditto.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "The copy stopped (ditto exit \(ditto.terminationStatus))."])
        }
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    static func replace(_ destination: URL, with source: URL,
                        copy: (URL, URL) throws -> Void = dittoCopy,
                        trash: (URL) throws -> Void = moveToTrash) throws -> Outcome {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let name = destination.deletingPathExtension().lastPathComponent
        let token = UUID().uuidString.prefix(8)
        let staging = folder.appendingPathComponent(".\(name)-installing-\(token).app", isDirectory: true)
        let previous = folder.appendingPathComponent(".\(name)-previous-\(token).app", isDirectory: true)

        // 1-2. Copy beside it and check the copy. Any failure: remove the partial copy only.
        do {
            try copy(source, staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw Failure(message: "The new copy couldn't be made: " + error.localizedDescription, unchanged: true)
        }
        guard bundleLooksComplete(staging) else {
            try? fm.removeItem(at: staging)
            throw Failure(message: "The new copy was incomplete.", unchanged: true)
        }

        // 3. Swap.
        let hadOld = fm.fileExists(atPath: destination.path)
        if hadOld {
            do { try fm.moveItem(at: destination, to: previous) } catch {
                try? fm.removeItem(at: staging)
                throw Failure(message: "The copy already in Applications couldn't be moved aside: " + error.localizedDescription,
                              unchanged: true)
            }
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            let moveError = error.localizedDescription
            try? fm.removeItem(at: staging)
            if hadOld {
                do { try fm.moveItem(at: previous, to: destination) } catch {
                    throw Failure(message: "The new copy couldn't be put in place (" + moveError + "), and the old copy "
                                  + "couldn't be put back. It is at " + previous.path, unchanged: false)
                }
            }
            throw Failure(message: "The new copy couldn't be put in place: " + moveError, unchanged: true)
        }

        // 4. Old copy to the Trash. If that fails, keep it under a visible name rather than delete it.
        guard hadOld else { return .installed }
        do {
            try trash(previous)
            return .installed
        } catch {
            let kept = folder.appendingPathComponent("\(name) (previous version).app", isDirectory: true)
            if !fm.fileExists(atPath: kept.path), (try? fm.moveItem(at: previous, to: kept)) != nil {
                return .installedOldKept(kept.path)
            }
            return .installedOldKept(previous.path)
        }
    }
}
