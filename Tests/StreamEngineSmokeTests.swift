import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Version 17: checks for the Digi Stream engine. Run from FastBackupSmokeTests.
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "StreamEngineSmokeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum StreamEngineSmokeTests {
    static let xattrName = "com.digisuite.streamtest"

    static func writeXattr(_ path: String, _ text: String) {
        let bytes: [UInt8] = Array(text.utf8)
        _ = bytes.withUnsafeBytes { buffer in
            setxattr(path, xattrName, buffer.baseAddress, bytes.count, 0, 0)
        }
    }

    static func readXattr(_ path: String) -> String? {
        let size: Int = getxattr(path, xattrName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read: Int = getxattr(path, xattrName, &bytes, size, 0, 0)
        guard read == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func run() async throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("DigiSuite-Stream-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("Source", isDirectory: true)
        let streamTarget = fixture.appendingPathComponent("StreamTarget", isDirectory: true)
        for folder in [source, streamTarget] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        func put(_ relative: String, _ data: Data, modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws {
            let url = source.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        func stream(_ target: URL, control: BackupControl = BackupControl(),
                    space: @escaping @Sendable (URL) -> Int64? = { DigiFastBackupEngine.availableBytes($0) }) async -> SyncProgress {
            await DigiStreamEngine.sync(source: source, destination: target, archiveChanged: true, archiveRemoved: true,
                                        filter: BackupFilter(), control: control, availableSpace: space, report: { _ in })
        }
        func leakedTemporaries(_ target: URL) throws -> Bool {
            let paths = try fm.subpathsOfDirectory(atPath: target.path)
            return paths.contains { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".shootwrap-") && $0.hasSuffix(".tmp") }
        }
        func archivedCopy(in target: URL, category: String, name: String) throws -> Data? {
            let root = target.appendingPathComponent(DigiFastBackupEngine.archiveName)
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
            for case let item as URL in walker where item.path.contains("/" + category + "/") && item.lastPathComponent == name {
                return try Data(contentsOf: item)
            }
            return nil
        }

        // Fixture: large files (one exactly at the threshold), a file one byte
        // under it, an empty file, settings files, many small files, an empty folder.
        let bigPattern = String(repeating: "0123456789abcdef", count: 1_310_720)      // 20 MiB
        let boundaryPattern = String(repeating: "ABCDEFGHIJKLMNOP", count: 524_288)    // exactly 8 MiB
        try put("Capture/Big1.ARW", Data(bigPattern.utf8))
        try put("Capture/Boundary.ARW", Data(boundaryPattern.utf8))
        try put("Capture/Under.ARW", Data(repeating: 0x41, count: 8_388_607))
        try put("Capture/Empty.txt", Data())
        try put("Settings/Big1.ARW.cos", Data("<settings/>".utf8))
        for number in 0..<120 { try put("Cache/Proxies/\(number).cop", Data("proxy \(number)".utf8)) }
        try fm.createDirectory(at: source.appendingPathComponent("Selects"), withIntermediateDirectories: true)
        let bigSource = source.appendingPathComponent("Capture/Big1.ARW")
        writeXattr(bigSource.path, "large-lane")
        writeXattr(source.appendingPathComponent("Settings/Big1.ARW.cos").path, "small-lane")
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: bigSource.path)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: bigSource.path)
        let inventory = try DigiFastBackupEngine.snapshot(source, filter: BackupFilter())
        let fileCount = inventory.files.count
        let totalBytes: Int64 = inventory.files.reduce(Int64(0)) { $0 + $1.size }

        // 1. First copy: every byte, date, permission and extended attribute.
        let first = await stream(streamTarget)
        try check(first.status == DigiFastBackupEngine.completeStatus, "Stream first copy failed: " + first.status)
        try check(first.completedFiles == fileCount, "Stream copied the wrong number of files")
        try check(first.completedBytes == totalBytes, "Stream byte count is wrong")
        for file in inventory.files {
            let copiedURL = streamTarget.appendingPathComponent(file.relative)
            let expected = try Data(contentsOf: file.source)
            let actual = try Data(contentsOf: copiedURL)
            try check(expected == actual, "Stream content mismatch: " + file.relative)
            let copiedDate = try fm.attributesOfItem(atPath: copiedURL.path)[.modificationDate] as? Date
            let drift: Double = abs((copiedDate ?? .distantPast).timeIntervalSince(file.modified))
            try check(drift < 2, "Stream did not keep the modification date: " + file.relative)
        }
        let bigCopy = streamTarget.appendingPathComponent("Capture/Big1.ARW")
        try check(readXattr(bigCopy.path) == "large-lane", "Large-file extended attribute was lost")
        try check(readXattr(streamTarget.appendingPathComponent("Settings/Big1.ARW.cos").path) == "small-lane", "Small-file extended attribute was lost")
        let permissions = (try fm.attributesOfItem(atPath: bigCopy.path)[.posixPermissions] as? NSNumber)?.intValue
        try check(permissions == 0o640, "Large-file permissions were not kept")
        try check(fm.fileExists(atPath: streamTarget.appendingPathComponent("Selects").path), "Empty folder was not created")
        let leaked1 = try leakedTemporaries(streamTarget)
        try check(!leaked1, "Stream left a temporary file")
        try check(first.engineNote.contains("large files: 2"), "Large/small split is wrong: " + first.engineNote)

        // 2. An unchanged rerun copies nothing.
        let again = await stream(streamTarget)
        try check(again.completedFiles == 0 && again.unchangedFiles == fileCount, "Stream recopied unchanged files")

        // 3. A changed large file replaces the old one, which is archived.
        let changedPattern = String(repeating: "fedcba9876543210", count: 1_310_720)
        try put("Capture/Big1.ARW", Data(changedPattern.utf8), modified: stamp.addingTimeInterval(60))
        try fm.removeItem(at: source.appendingPathComponent("Capture/Under.ARW"))
        let update = await stream(streamTarget)
        try check(update.errorCount == 0 && update.completedFiles == 1, "Changed file not copied: " + update.status)
        let replaced = try Data(contentsOf: bigCopy)
        try check(replaced == Data(changedPattern.utf8), "Changed file content is wrong")
        let oldBig = try archivedCopy(in: streamTarget, category: "Replaced", name: "Big1.ARW")
        try check(oldBig == Data(bigPattern.utf8), "Previous version was not archived")
        let removedUnder = try archivedCopy(in: streamTarget, category: "Removed from source", name: "Under.ARW")
        try check(removedUnder?.count == 8_388_607, "Removed file was not archived")

        // 4. A backup that cannot fit stops before copying anything.
        let fullTarget = fixture.appendingPathComponent("Full", isDirectory: true)
        try fm.createDirectory(at: fullTarget, withIntermediateDirectories: false)
        let full = await stream(fullTarget, space: { _ in 1 })
        let fullItems = try fm.contentsOfDirectory(atPath: fullTarget.path)
        try check(full.errorCount == 1 && full.status.contains("Not enough space") && fullItems.isEmpty, "Space check failed: " + full.status)

        // 5. Stop works in the middle of a large file.
        let partial = fixture.appendingPathComponent("partial.tmp")
        let stopped = BackupControl(); stopped.stop()
        var stoppedMidFile = false
        do {
            try DigiStreamEngine.copyLarge(source: bigSource, target: partial, expectedSize: Int64(changedPattern.utf8.count),
                                           control: stopped, written: DigiStreamEngine.ByteCounter())
        } catch is CancellationError {
            stoppedMidFile = true
        }
        try check(stoppedMidFile, "Stop did not interrupt a large-file copy")

        // 6. Stop releases a paused backup and leaves nothing half-written.
        let pausedTarget = fixture.appendingPathComponent("Paused", isDirectory: true)
        try fm.createDirectory(at: pausedTarget, withIntermediateDirectories: false)
        let paused = BackupControl(); paused.pause()
        let pausedRun = Task { await stream(pausedTarget, control: paused) }
        try await Task.sleep(nanoseconds: 80_000_000)
        paused.stop()
        let pausedResult = await pausedRun.value
        try check(pausedResult.status.hasPrefix("Stopped"), "Stop did not release a paused Stream backup")
        let leaked2 = try leakedTemporaries(pausedTarget)
        try check(!leaked2, "Stopped Stream backup left a temporary file")

        // 7. Stop right after planning: nothing is copied or left behind, and
        // the next run copies everything.
        let midTarget = fixture.appendingPathComponent("MidStop", isDirectory: true)
        try fm.createDirectory(at: midTarget, withIntermediateDirectories: false)
        let midControl = BackupControl()
        let midResult = await DigiStreamEngine.sync(source: source, destination: midTarget, archiveChanged: true, archiveRemoved: true,
            filter: BackupFilter(), control: midControl, report: { state in
                if state.totalFiles > 0 { midControl.stop() }
            })
        try check(midResult.status.hasPrefix("Stopped"), "Mid-copy stop was ignored: " + midResult.status)
        let leaked3 = try leakedTemporaries(midTarget)
        try check(!leaked3, "Mid-copy stop left a temporary file")
        let resumed = await stream(midTarget)
        let resumedTotal: Int = resumed.completedFiles + resumed.unchangedFiles
        try check(resumed.errorCount == 0, "Backup did not resume after a stop: " + resumed.status)
        try check(resumedTotal == fileCount - 1, "Resumed backup missed files")

        // 8. v1.25: checksums. xxHash's own published test values, chunked hashing,
        // a verified backup with its report, and a quiet incremental after it.
        try check(XXHash64.hex(XXHash64.hash(Data())) == "ef46db3751d8e999", "xxHash64 of nothing is wrong")
        var sanity = Data()
        var generator: UInt64 = 2654435761
        for _ in 0..<222 {
            sanity.append(UInt8(truncatingIfNeeded: generator >> 56))
            generator = generator &* 11400714785074694797
        }
        try check(XXHash64.hash(Data(sanity.prefix(1))) == 0xE934A84ADB052768, "xxHash64 1-byte test value is wrong")
        try check(XXHash64.hash(Data(sanity.prefix(14))) == 0x8282DCC4994E35C8, "xxHash64 14-byte test value is wrong")
        try check(XXHash64.hash(sanity) == 0xB641AE8CB691C174, "xxHash64 222-byte test value is wrong")
        var pieces = XXHash64()
        var position = 0
        while position < sanity.count {
            let end = min(sanity.count, position + 7)
            pieces.update(Data(sanity[position..<end]))
            position = end
        }
        try check(pieces.finish() == XXHash64.hash(sanity), "Hashing in pieces gave a different checksum")

        let verifyTarget = fixture.appendingPathComponent("VerifyTarget", isDirectory: true)
        try fm.createDirectory(at: verifyTarget, withIntermediateDirectories: false)
        let checked = await DigiStreamEngine.sync(source: source, destination: verifyTarget, archiveChanged: true, archiveRemoved: true,
            filter: BackupFilter(), control: BackupControl(), verify: true, report: { _ in })
        try check(checked.errorCount == 0 && checked.status == DigiFastBackupEngine.completeStatus, "Verified backup failed: " + checked.status)
        try check(checked.verifiedFiles == checked.completedFiles && checked.verifiedFiles > 0, "Not every copied file was verified")
        try check(!checked.reportPath.isEmpty && fm.fileExists(atPath: checked.reportPath), "Verified backup wrote no report")
        let listURL = verifyTarget.appendingPathComponent(DigiFastBackupEngine.reportsName).appendingPathComponent(DigiBackupReport.checksumFileName)
        let list = DigiBackupReport.readChecksums(listURL)
        try check(list.count == checked.verifiedFiles, "Checksum list doesn't match the verified files")
        for (relative, hash) in list {
            let original = try DigiChecksum.hashFile(source.appendingPathComponent(relative), uncached: false)
            try check(XXHash64.hex(original) == hash, "Listed checksum doesn't match the original: " + relative)
        }
        let verifiedAgain = await DigiStreamEngine.sync(source: source, destination: verifyTarget, archiveChanged: true, archiveRemoved: true,
            filter: BackupFilter(), control: BackupControl(), verify: true, report: { _ in })
        try check(verifiedAgain.status == DigiFastBackupEngine.completeStatus && verifiedAgain.completedFiles == 0, "Verified incremental copied again")
        try check(verifiedAgain.reportPath.isEmpty, "An incremental with nothing new wrote another report")
        let backupScan = try DigiFastBackupEngine.snapshot(verifyTarget, filter: BackupFilter())
        try check(!backupScan.files.contains { $0.relative.hasPrefix(DigiFastBackupEngine.reportsName) }, "Report folder was treated as shoot files")
        // v1.26: Quick mode checksums originals without reading copies back.
        let quickTarget = fixture.appendingPathComponent("QuickTarget", isDirectory: true)
        try fm.createDirectory(at: quickTarget, withIntermediateDirectories: false)
        let quick = await DigiStreamEngine.sync(source: source, destination: quickTarget, archiveChanged: true, archiveRemoved: true,
            filter: BackupFilter(), control: BackupControl(), verify: true, readBack: false, report: { _ in })
        try check(quick.errorCount == 0 && quick.verifiedFiles == quick.completedFiles, "Quick backup failed: " + quick.status)
        let quickList = DigiBackupReport.readChecksums(quickTarget.appendingPathComponent(DigiFastBackupEngine.reportsName)
            .appendingPathComponent(DigiBackupReport.checksumFileName))
        try check(quickList == list, "Quick and full checksums differ")
        let quickReport = try String(contentsOfFile: quick.reportPath, encoding: .utf8)
        try check(quickReport.contains("Quick"), "Quick report doesn't say Quick")
        try check(DigiBackupReport.group(for: "Capture/LG/Scene/a.ARW") == "Capture/LG", "Report folder grouping is wrong")
        print("PASS (v1.25): xxHash64 test values, verified copies, checksum list and report")

        // 9. v1.25: archive trim and clear touch only the archive folders, oldest first.
        let archiveTarget = fixture.appendingPathComponent("ArchiveTarget", isDirectory: true)
        let keepFile = archiveTarget.appendingPathComponent("Capture/keep.iiq")
        try fm.createDirectory(at: keepFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current".utf8).write(to: keepFile)
        let runNames = ["2026-01-01T10-00-00Z-aaaa", "2026-02-01T10-00-00Z-bbbb", "2026-03-01T10-00-00Z-cccc"]
        for (index, name) in runNames.enumerated() {
            let archiveFolder = index == 0 ? DigiFastBackupEngine.legacyArchiveName : DigiFastBackupEngine.archiveName
            let file = archiveTarget.appendingPathComponent(archiveFolder + "/" + name + "/Replaced/Capture/old.iiq")
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: file)
        }
        try check(DigiArchive.runs(in: archiveTarget).map(\.lastPathComponent) == runNames, "Archive runs are not oldest first")
        try check(DigiArchive.measure(archiveTarget).bytes > 0, "Archive size came back empty")
        // Pretend the drive gets enough room after two runs are gone.
        let trimmed = try DigiArchive.trimOldest(archiveTarget, keepFree: 100, free: { _ in
            DigiArchive.runs(in: archiveTarget).count <= 1 ? 1000 : 10
        })
        try check(trimmed.runs == 2, "Trim removed \(trimmed.runs) archive runs, expected 2")
        try check(DigiArchive.runs(in: archiveTarget).map(\.lastPathComponent) == [runNames[2]], "Trim didn't keep the newest run")
        try check(!fm.fileExists(atPath: archiveTarget.appendingPathComponent(DigiFastBackupEngine.legacyArchiveName).path), "Empty old archive folder was left behind")
        try DigiArchive.clearAll(archiveTarget)
        try check(DigiArchive.measure(archiveTarget).isEmpty, "Clear left archive files")
        try check(fm.fileExists(atPath: keepFile.path), "Clearing the archive touched the backup itself")
        print("PASS (v1.25): archive size, trim oldest, clear all")

        print("PASS (v17): Digi Stream bytes, dates, permissions, extended attributes, empty folders, incrementals, archives, space check, mid-file and paused stop")
    }
}
