import Foundation

// v1.46.7: backups onto real APFS, Mac OS Extended, exFAT and FAT volumes (small disk images
// made by RUN_DRIVE_FORMAT_TESTS.command). Arguments: one mounted volume path per format.
// Checks what depends on the drive's format: date windows, cached exFAT/FAT writes, the
// final flush, the checksum list and Drive Check. Exits 1 on the first failure.

private struct TestFailure: Error, CustomStringConvertible { let description: String }

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(description: message) }
}

@main
struct DriveFormatTests {
    static func main() async {
        let volumes = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !volumes.isEmpty else {
            print("Usage: DriveFormatTests <mounted volume>...")
            exit(2)
        }
        var failed = false
        for volume in volumes {
            let type = DigiStreamEngine.filesystemType(volume)
            do {
                let note = try await test(volume, type: type)
                print("PASS (\(type)): " + note)
            } catch {
                print("FAIL (\(type)): \(error)")
                failed = true
            }
        }
        exit(failed ? 1 : 0)
    }

    static func test(_ volume: URL, type: String) async throws -> String {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("DriveFormat-" + type + "-" + UUID().uuidString, isDirectory: true)
        let target = volume.appendingPathComponent("Backup", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: source) }

        func put(_ relative: String, _ data: Data, _ modified: Date) throws {
            let url = source.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        func sync(verify: Bool) async -> SyncProgress {
            await DigiStreamEngine.sync(source: source, destination: target, archiveChanged: true, archiveRemoved: true,
                                        filter: BackupFilter(), control: BackupControl(),
                                        verify: verify, readBack: verify, report: { _ in })
        }
        func same(_ relative: String) -> Bool {
            (try? Data(contentsOf: source.appendingPathComponent(relative))) ==
                (try? Data(contentsOf: target.appendingPathComponent(relative)))
        }

        // Fractional-second dates, so a drive that rounds them is exercised.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.123456)
        var big = Data(count: 24 * 1_048_576)
        big.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<bytes.count { bytes[index] = UInt8(truncatingIfNeeded: index &* 2654435761 >> 13) }
        }
        try put("Capture/A001.MOV", big, t0.addingTimeInterval(0.777))
        for number in 0..<30 {
            try put("Capture/IMG_\(number).CR3", Data(repeating: UInt8(number), count: 40_000 + number), t0.addingTimeInterval(Double(number) * 0.37))
        }
        try put("Session.cosessiondb", Data(repeating: 0xAA, count: 8192), t0)

        // 1. Flush works on this format (no false failure).
        try check(DigiStreamEngine.flushToDrive(target) == nil, "flush reported a failure on a healthy drive")

        // 2. First backup, Full checking: everything copied, read back, byte for byte.
        let first = await sync(verify: true)
        try check(first.status == DigiFastBackupEngine.completeStatus && first.errorCount == 0,
                  "first backup: \(first.status)")
        try check(first.completedFiles == 32, "first backup copied \(first.completedFiles) of 32")
        try check(same("Capture/A001.MOV") && same("Session.cosessiondb") && same("Capture/IMG_29.CR3"),
                  "a copy doesn't match its original")

        // How precisely this drive keeps file dates (for the record).
        let stored = (try fm.attributesOfItem(atPath: target.appendingPathComponent("Capture/A001.MOV").path)[.modificationDate] as? Date) ?? .distantPast
        let drift = abs(stored.timeIntervalSince(t0.addingTimeInterval(0.777)))

        // 3. Nothing changed: nothing copied again (the date window fits this drive).
        let quiet = await sync(verify: true)
        try check(quiet.completedFiles == 0 && quiet.unchangedFiles == 32,
                  "unchanged files were copied again (\(quiet.completedFiles)); date drift \(drift) s")

        // 4. Same size, new contents, saved later than this drive's date window: copied.
        let window = DigiFastBackupEngine.dateTolerance(forFilesystem: type)
        try put("Session.cosessiondb", Data(repeating: 0xBB, count: 8192), t0.addingTimeInterval(window + 1.5))
        let changed = await sync(verify: true)
        try check(changed.completedFiles == 1 && same("Session.cosessiondb"),
                  "same-size change \(window + 1.5) s later wasn't copied")

        // 5. Drive Check against the checksum list.
        let check1 = try DigiChecksumListCheck.run(target, control: BackupControl()) { _, _, _ in }
        try check(check1.passed && check1.listed == 32, "Drive Check: listed \(check1.listed), different \(check1.different), missing \(check1.missing)")

        // 6. Checking Off replaces a file: the list drops it and Drive Check stays clean.
        try put("Capture/IMG_3.CR3", Data(repeating: 0x77, count: 50_000), t0.addingTimeInterval(100))
        let off = await sync(verify: false)
        try check(off.errorCount == 0 && off.completedFiles == 1, "Checking Off run: \(off.status)")
        let check2 = try DigiChecksumListCheck.run(target, control: BackupControl()) { _, _, _ in }
        try check(check2.passed && check2.different.isEmpty && check2.listed == 31,
                  "Drive Check after Checking Off: listed \(check2.listed), different \(check2.different)")

        // 7. A file removed from the source goes to the archive, not deleted.
        try fm.removeItem(at: source.appendingPathComponent("Capture/IMG_5.CR3"))
        let removed = await sync(verify: true)
        let archive = target.appendingPathComponent(DigiFastBackupEngine.archiveName)
        let archived = (fm.enumerator(atPath: archive.path)?.allObjects as? [String] ?? []).contains { $0.hasSuffix("Removed from source/Capture/IMG_5.CR3") }
        try check(removed.errorCount == 0 && archived && !fm.fileExists(atPath: target.appendingPathComponent("Capture/IMG_5.CR3").path),
                  "removed file wasn't archived: \(removed.status)")

        // 8. No temp files left behind.
        let leftovers = (fm.enumerator(atPath: target.path)?.allObjects as? [String] ?? []).filter { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".shootwrap-") && $0.hasSuffix(".tmp") }
        try check(leftovers.isEmpty, "temp files left: \(leftovers)")

        let cached = DigiStreamEngine.prefersCachedWrites(filesystem: type) ? "cached" : "uncached"
        return String(format: "copy, re-run, %.3f s window, Drive Check, Checking Off, archive (%@ large writes; dates kept to %.4f s)",
                      window, cached, drift)
    }
}
