import Foundation

// v1.46.7: Jeff's three shoot-day tests (Vanish, Grow, Stale) at full size, without the app's
// window. Runs a backup the way Back Up Now does (WrapModel.syncFolder): the drive lock, the
// Checking mode from the app's own settings, archive changed and removed on, the same engine.
// While a backup runs, a watcher thread does what a person would do in Terminal: deletes files,
// grows the session database, or saves a file again.
//
// Arguments: <checking mode: full|quick|off> <backup folder>
// The originals are made in a temporary folder and removed afterwards. The backup folder is
// left as it is (never deleted here); the .command script decides where it is.

private struct TestFailure: Error, CustomStringConvertible { let description: String }

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(description: message) }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
    var get: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct RealScenarioTests {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            print("Usage: RealScenarioTests <full|quick|off> <backup folder>")
            exit(2)
        }
        let mode = arguments[0]
        let backupRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("StudioSession-Scenarios-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let type = DigiStreamEngine.filesystemType(backupRoot)
        print("Checking: \(mode) · backup drive format: \(type.isEmpty ? "unknown" : type)")

        var failed = false
        for (name, scenario) in [("Vanish", vanish), ("Grow", grow), ("Stale", stale)] as [(String, (URL, URL, String) async throws -> String)] {
            let source = work.appendingPathComponent(name, isDirectory: true)
            let target = backupRoot.appendingPathComponent(name + "Backup", isDirectory: true)
            do {
                try fm.createDirectory(at: source, withIntermediateDirectories: true)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                let started = Date()
                let note = try await scenario(source, target, mode)
                print(String(format: "PASS (%@, %.0f s): ", name, Date().timeIntervalSince(started)) + note)
            } catch {
                print("FAIL (\(name)): \(error)")
                failed = true
            }
        }
        exit(failed ? 1 : 0)
    }

    /// Back Up Now for one drive, as WrapModel.syncFolder does it.
    static func backUp(_ source: URL, _ target: URL, mode: String) async -> SyncProgress {
        let lock = DigiDestinationLock.acquire(target)
        if case .busy = lock {
            var busy = SyncProgress(destination: target.path)
            busy.status = DigiDestinationLock.busyStatus
            return busy
        }
        let result = await DigiStreamEngine.sync(source: source, destination: target, archiveChanged: true, archiveRemoved: true,
                                                 filter: BackupFilter(), control: BackupControl(),
                                                 verify: mode != "off", readBack: mode == "full", report: { _ in })
        withExtendedLifetime(lock) {}
        return result
    }

    static func randomFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { throw TestFailure(description: "couldn't create " + url.path) }
        defer { try? handle.close() }
        var left = bytes
        var generator = SystemRandomNumberGenerator()
        while left > 0 {
            let count = min(left, 8 * 1_048_576)
            var chunk = Data(count: count)
            chunk.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt64.self)
                for index in 0..<words.count { words[index] = generator.next() }
            }
            handle.write(chunk)
            left -= count
        }
    }

    /// Calls `action` once, as soon as a .shootwrap- temp file appears anywhere under `target`.
    static func whenCopyStarts(in target: URL, done: Flag, _ action: @escaping @Sendable () -> Void) -> Flag {
        let fired = Flag()
        Thread.detachNewThread {
            while done.get == 0 && fired.get == 0 {
                let walker = FileManager.default.enumerator(atPath: target.path)
                while let path = walker?.nextObject() as? String {
                    if (path as NSString).lastPathComponent.hasPrefix(".shootwrap-") && path.hasSuffix(".tmp") {
                        action()
                        fired.set(1)
                        break
                    }
                }
                usleep(2_000)
            }
        }
        return fired
    }

    // Vanish: 300 photos of 2 MB; 50 of them deleted the moment copying starts.
    static func vanish(_ source: URL, _ target: URL, _ mode: String) async throws -> String {
        let fm = FileManager.default
        for number in 1...300 { try randomFile(source.appendingPathComponent("Capture/IMG_\(number).CR3"), bytes: 2_000_000) }
        let done = Flag()
        let fired = whenCopyStarts(in: target, done: done) {
            for number in 250...299 { try? FileManager.default.removeItem(at: source.appendingPathComponent("Capture/IMG_\(number).CR3")) }
        }
        let first = await backUp(source, target, mode: mode)
        done.set(1)
        let copied = ((try? fm.contentsOfDirectory(atPath: target.appendingPathComponent("Capture").path)) ?? []).filter { $0.hasSuffix(".CR3") }.count
        try check(fired.get == 1, "the deletions never happened (backup finished before copying was seen)")
        try check(first.status == DigiFastBackupEngine.completeStatus && first.errorCount == 0,
                  "first backup: \"\(first.status)\" (1.46.6 stopped here with an error)")
        try check(first.skippedFiles > 0 && copied + first.skippedFiles == 300,
                  "copied \(copied) + skipped \(first.skippedFiles) should be 300")
        let second = await backUp(source, target, mode: mode)
        try check(second.status == DigiFastBackupEngine.completeStatus && second.errorCount == 0 && second.completedFiles == 0,
                  "second backup: \"\(second.status)\", copied \(second.completedFiles)")
        return "\"Up to date\", \(copied) copied, \(first.skippedFiles) deleted mid-backup were skipped; next backup clean"
    }

    // Grow: a 1 GB session database that grows by 1 MB while it is being copied.
    static func grow(_ source: URL, _ target: URL, _ mode: String) async throws -> String {
        let fm = FileManager.default
        let database = source.appendingPathComponent("Session.cosessiondb")
        try randomFile(database, bytes: 1_000_000_000)
        for number in 1...3 { try Data("<settings \(number)/>".utf8).write(to: source.appendingPathComponent("Settings\(number).cos")) }
        let done = Flag()
        let fired = Flag()
        Thread.detachNewThread {
            // Wait until the database's own temp copy is part-way (over 64 MB), then grow the original.
            while done.get == 0 && fired.get == 0 {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
                for name in names where name.hasPrefix(".shootwrap-") {
                    let size = ((try? FileManager.default.attributesOfItem(atPath: target.appendingPathComponent(name).path))?[.size] as? NSNumber)?.int64Value ?? 0
                    if size > 64 * 1_048_576 {
                        if let handle = try? FileHandle(forWritingTo: database) {
                            handle.seekToEndOfFile()
                            handle.write(Data(repeating: 0x42, count: 1_000_000))
                            try? handle.close()
                        }
                        fired.set(1)
                    }
                }
                usleep(1_000)
            }
        }
        let first = await backUp(source, target, mode: mode)
        done.set(1)
        try check(fired.get == 1, "the database never grew mid-copy (copy finished first)")
        try check(first.status == DigiFastBackupEngine.completeStatus && first.errorCount == 0,
                  "first backup: \"\(first.status)\" (1.46.6: \"Source size changed while copying\")")
        let settings = ((try? fm.contentsOfDirectory(atPath: target.path)) ?? []).filter { $0.hasSuffix(".cos") }.count
        try check(first.skippedFiles == 1 && settings == 3 && !fm.fileExists(atPath: target.appendingPathComponent("Session.cosessiondb").path),
                  "skipped \(first.skippedFiles), settings copied \(settings)")
        let second = await backUp(source, target, mode: mode)
        try check(second.errorCount == 0 && second.completedFiles == 1, "second backup: \"\(second.status)\", copied \(second.completedFiles)")
        let same = fm.contentsEqual(atPath: database.path, andPath: target.appendingPathComponent("Session.cosessiondb").path)
        try check(same, "the backed-up database doesn't match the original")
        return "\"Up to date\", growing database skipped, 3 settings files copied; next backup copied the database, identical"
    }

    // Stale: a settings file saved again with the same size, 1 s later (2.5 s on exFAT/FAT).
    static func stale(_ source: URL, _ target: URL, _ mode: String) async throws -> String {
        let fm = FileManager.default
        let file = source.appendingPathComponent("Settings.cos")
        let t0 = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
        try randomFile(file, bytes: 4096)
        try fm.setAttributes([.modificationDate: t0], ofItemAtPath: file.path)
        let first = await backUp(source, target, mode: mode)
        try check(first.errorCount == 0 && first.completedFiles == 1, "first backup: \"\(first.status)\"")
        let window = DigiFastBackupEngine.dateTolerance(forFilesystem: DigiStreamEngine.filesystemType(target))
        let later: Double = window < 1 ? 1.0 : window + 0.5
        try randomFile(file, bytes: 4096)
        try fm.setAttributes([.modificationDate: t0.addingTimeInterval(later)], ofItemAtPath: file.path)
        let second = await backUp(source, target, mode: mode)
        let same = fm.contentsEqual(atPath: file.path, andPath: target.appendingPathComponent("Settings.cos").path)
        try check(second.errorCount == 0 && second.completedFiles == 1 && same,
                  "same-size save \(later) s later: copied \(second.completedFiles), backup matches \(same) (1.46.6: \"Up to date\", old contents)")
        return String(format: "same-size save %.1f s later was copied; backup matches the new version", later)
    }
}
