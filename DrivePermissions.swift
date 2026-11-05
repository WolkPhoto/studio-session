import AppKit

/// v1.6: when a backup drive won't let this Mac write to it (common with
/// drives formatted on another Mac or by another user), offer to turn on
/// "Ignore ownership on this volume", the same setting as Finder's Get Info.
/// It needs the Mac's admin password, which macOS asks for itself.
/// Nothing on the drive is moved, changed or deleted.
@MainActor enum DigiDrivePermissions {
    /// The /Volumes/<name> mount for a path on an external drive, or nil.
    static func volumeRoot(for url: URL) -> URL? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/" + parts[2], isDirectory: true)
    }

    static func canWrite(_ folder: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: folder.path)
    }

    private static func isReadOnlyVolume(_ volume: URL) -> Bool {
        let values = try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly ?? false
    }

    /// Returns true when the folder can be written to, fixing permissions first
    /// if the person agrees. Always answers with a dialog when it can't help.
    static func ensureWritable(_ folder: URL) -> Bool {
        if canWrite(folder) { return true }
        guard let volume = volumeRoot(for: folder) else {
            alert("\(DigiBrand.name) can't write to this folder",
                  "You don't have permission to write to \(folder.path). Choose a folder on a backup drive, or change this folder's permissions in Finder: select it, choose File > Get Info, then Sharing & Permissions.")
            return false
        }
        let name = volume.lastPathComponent
        if isReadOnlyVolume(volume) {
            alert("\(name) is read-only",
                  "macOS can only read this drive, not write to it. This usually means it's formatted for Windows (NTFS) or it's locked. To use it for backups, copy anything you need off it, then erase it as APFS in Disk Utility.")
            return false
        }
        let ask = NSAlert()
        ask.messageText = "\(name) won't let \(DigiBrand.name) write to it"
        ask.informativeText = "This drive was set up on another Mac or by another user, so macOS is blocking changes to it.\n\n\(DigiBrand.name) can turn on \"Ignore ownership on this volume\" for \(name). It's the same setting as the checkbox in Finder's Get Info window, and it lets this Mac read and write everything on the drive.\n\nNo files are moved, changed or deleted. macOS will ask for your Mac's password."
        ask.alertStyle = .informational
        ask.addButton(withTitle: "Fix Permissions")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return false }

        let command = "/usr/sbin/diskutil disableOwnership " + shellQuoted(volume.path)
        if let problem = runAsAdmin(command) {
            if problem.contains("-128") { return false } // Cancelled at the password prompt.
            alert("Permissions were not changed", "macOS said: \(problem)")
            return false
        }
        if canWrite(folder) { return true }
        alert("\(name) still can't be written to",
              "Ownership is now ignored on \(name), but this folder is still locked. In Finder, select the folder, choose File > Get Info, and set Sharing & Permissions to Read & Write. Then try again.")
        return false
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a command with administrator privileges. macOS shows its own password
    /// dialog. Returns nil on success, otherwise the error text.
    private static func runAsAdmin(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"" + escaped + "\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return "Could not prepare the request." }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
        return message + " (" + String(number) + ")"
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
