import Foundation
import ImageIO
import CoreGraphics
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
        try check(quick.errorCount == 0 && quick.checksummedFiles == quick.completedFiles, "Quick backup failed: " + quick.status)
        let quickList = DigiBackupReport.readChecksums(quickTarget.appendingPathComponent(DigiFastBackupEngine.reportsName)
            .appendingPathComponent(DigiBackupReport.checksumFileName))
        try check(quickList == list, "Quick and full checksums differ")
        let quickReport = try String(contentsOfFile: quick.reportPath, encoding: .utf8)
        try check(quickReport.contains("Quick"), "Quick report doesn't say Quick")
        try check(DigiBackupReport.group(for: "Capture/LG/Scene/a.ARW") == "Capture/LG", "Report folder grouping is wrong")

        // v1.27: a file renamed in the session is renamed on the backup, not copied again.
        let oldName = source.appendingPathComponent("Capture/Boundary.ARW")
        let newName = source.appendingPathComponent("Capture/Boundary_renamed.ARW")
        try fm.moveItem(at: oldName, to: newName)
        let renamedRun = await DigiStreamEngine.sync(source: source, destination: quickTarget, archiveChanged: true, archiveRemoved: true,
            filter: BackupFilter(), control: BackupControl(), verify: true, readBack: false, report: { _ in })
        try check(renamedRun.errorCount == 0, "Rename backup failed: " + renamedRun.status)
        try check(renamedRun.renamedFiles == 1 && renamedRun.completedFiles == 0, "Rename was copied instead of renamed (renamed \(renamedRun.renamedFiles), copied \(renamedRun.completedFiles))")
        try check(fm.fileExists(atPath: quickTarget.appendingPathComponent("Capture/Boundary_renamed.ARW").path), "Renamed file missing on the backup")
        try check(!fm.fileExists(atPath: quickTarget.appendingPathComponent("Capture/Boundary.ARW").path), "Old name still on the backup")
        let renamedList = DigiBackupReport.readChecksums(quickTarget.appendingPathComponent(DigiFastBackupEngine.reportsName)
            .appendingPathComponent(DigiBackupReport.checksumFileName))
        try check(renamedList["Capture/Boundary_renamed.ARW"] == list["Capture/Boundary.ARW"] && renamedList["Capture/Boundary.ARW"] == nil, "Checksum list didn't follow the rename")
        try fm.moveItem(at: newName, to: oldName)
        // v1.28: a drive check against its own checksum list finds changed and missing files.
        let cleanCheck = try DigiChecksumListCheck.run(verifyTarget, control: BackupControl(), progress: { _, _, _ in })
        try check(cleanCheck.passed && cleanCheck.matched == cleanCheck.listed, "Drive check failed on a good backup")
        let tampered = verifyTarget.appendingPathComponent("Settings/Big1.ARW.cos")
        try Data("<changed/>".utf8).write(to: tampered)
        let badCheck = try DigiChecksumListCheck.run(verifyTarget, control: BackupControl(), progress: { _, _, _ in })
        try check(!badCheck.passed && badCheck.different == ["Settings/Big1.ARW.cos"], "Drive check missed a changed file")
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

        // v1.29: a file whose size/date stamp moved since the scan (still being
        // written) is skipped, the rest of the backup finishes, and it's reported.
        let skipTarget = fixture.appendingPathComponent("SkipTarget", isDirectory: true)
        try fm.createDirectory(at: skipTarget, withIntermediateDirectories: false)
        let skipSnapshot = try DigiFastBackupEngine.snapshot(source, filter: BackupFilter())
        let busy = source.appendingPathComponent("Settings/Big1.ARW.cos")
        try Data("<settings/ this is much longer than it was at scan time>".utf8).write(to: busy)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_900_000)], ofItemAtPath: busy.path)
        let skipRun = await DigiStreamEngine.sync(source: source, destination: skipTarget, archiveChanged: true, archiveRemoved: true,
            filter: BackupFilter(), snapshot: skipSnapshot, control: BackupControl(), verify: true, readBack: false, report: { _ in })
        try check(skipRun.status == DigiFastBackupEngine.completeStatus, "Skip run did not finish: " + skipRun.status)
        try check(skipRun.errorCount == 0, "Skip run reported an error")
        try check(skipRun.skippedFiles == 1, "Expected 1 skipped file, got \(skipRun.skippedFiles)")
        try check(!fm.fileExists(atPath: skipTarget.appendingPathComponent("Settings/Big1.ARW.cos").path), "A file still being written should have been skipped, not copied")
        try check(fm.fileExists(atPath: skipTarget.appendingPathComponent("Capture/Big1.ARW").path), "Other files should still copy around a skipped file")
        try check((try? leakedTemporaries(skipTarget)) != true, "A skipped file left a temp behind")
        let skipReport = try String(contentsOfFile: skipRun.reportPath, encoding: .utf8)
        try check(skipReport.contains("STILL BEING WRITTEN, SKIPPED THIS RUN"), "Report doesn't list the skipped file")
        // v1.30: near-exact. Any real change is a skip; only sub-millisecond
        // timestamp-API noise is tolerated.
        try check(DigiStreamEngine.sourceMoved(size: 100, recordedSize: 100, drift: 0.0) == false, "An identical file should not be skipped")
        try check(DigiStreamEngine.sourceMoved(size: 100, recordedSize: 100, drift: 0.0005) == false, "Sub-millisecond timestamp noise should be tolerated")
        try check(DigiStreamEngine.sourceMoved(size: 100, recordedSize: 100, drift: 0.2) == true, "A real sub-second change should be skipped")
        try check(DigiStreamEngine.sourceMoved(size: 100, recordedSize: 100, drift: 3.0) == true, "A multi-second change should be skipped")
        try check(DigiStreamEngine.sourceMoved(size: 101, recordedSize: 100, drift: 0.0) == true, "A size change should be skipped")
        print("PASS (v1.30): busy file skipped, rest copied, skip reported, near-exact change detection")

        // v1.33: a hard-interrupted run leaves orphaned .shootwrap-*.tmp files; the
        // next backup sweeps them. Real files and the archive folder are untouched.
        let orphan = skipTarget.appendingPathComponent("Capture/.shootwrap-DEADBEEF-TEST.tmp")
        try Data(count: 4096).write(to: orphan)
        try check(fm.fileExists(atPath: orphan.path), "test could not create the orphan temp")
        let sweptTemps = DigiStreamEngine.removeOrphanTemps(in: skipTarget)
        try check(sweptTemps == 1, "expected to sweep 1 orphan temp, swept \(sweptTemps)")
        try check(!fm.fileExists(atPath: orphan.path), "orphan temp was not swept")
        try check(fm.fileExists(atPath: skipTarget.appendingPathComponent("Capture/Big1.ARW").path), "sweep removed a real file")
        print("PASS (v1.33): orphan temp sweep")

        // v1.36: exFAT/FAT destinations get cached large-file writes; APFS/HFS+ keep the uncached stream.
        try check(DigiStreamEngine.prefersCachedWrites(filesystem: "exfat"), "exFAT should use cached writes")
        try check(DigiStreamEngine.prefersCachedWrites(filesystem: "msdos"), "FAT should use cached writes")
        try check(!DigiStreamEngine.prefersCachedWrites(filesystem: "apfs"), "APFS keeps the uncached stream")
        try check(!DigiStreamEngine.prefersCachedWrites(filesystem: "hfs"), "HFS+ keeps the uncached stream")
        let fixtureFS = DigiStreamEngine.filesystemType(skipTarget)
        try check(!fixtureFS.isEmpty, "Could not read the test folder's filesystem type")
        // The cached path must produce an identical copy too (run here on the test volume).
        let cachedSource = skipTarget.appendingPathComponent("Capture/Big1.ARW")
        let cachedCopy = skipTarget.appendingPathComponent("Capture/.cached-write-test.bin")
        try? fm.removeItem(at: cachedCopy)
        let cachedSize = (try fm.attributesOfItem(atPath: cachedSource.path)[.size] as? NSNumber)?.int64Value ?? -1
        let cachedHash = try DigiStreamEngine.copyLarge(source: cachedSource, target: cachedCopy, expectedSize: cachedSize,
            control: BackupControl(), written: DigiStreamEngine.ByteCounter(), verify: true, readBack: true, uncached: false)
        try check(cachedHash != nil, "Cached-write copy returned no checksum")
        let cachedCopyData = try Data(contentsOf: cachedCopy)
        let cachedSourceData = try Data(contentsOf: cachedSource)
        try check(cachedCopyData == cachedSourceData, "Cached-write copy differs from the source")
        try? fm.removeItem(at: cachedCopy)
        print("PASS (v1.36): exFAT/FAT use cached large-file writes (this volume: \(fixtureFS)); cached path copies byte for byte")

        // v1.37: one unreadable or Finder-locked file must not block the whole backup (Nov 9, D6).
        // Unreadable: skipped and flagged. Locked: backed up, and the backup copy is locked too.
        let problemSource = fixture.appendingPathComponent("ProblemSource", isDirectory: true)
        let problemTarget = fixture.appendingPathComponent("ProblemTarget", isDirectory: true)
        for folder in [problemSource, problemTarget] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let fineURL = problemSource.appendingPathComponent("fine.txt")
        let lockedURL = problemSource.appendingPathComponent("locked.txt")
        let lockedBigURL = problemSource.appendingPathComponent("locked_big.bin")
        let unreadableURL = problemSource.appendingPathComponent("no_read.txt")
        try Data("fine".utf8).write(to: fineURL)
        try Data("locked v1".utf8).write(to: lockedURL)
        try Data(repeating: 7, count: 9 * 1024 * 1024).write(to: lockedBigURL)   // large lane
        try Data("secret".utf8).write(to: unreadableURL)
        for url in [fineURL, lockedURL, lockedBigURL, unreadableURL] {
            try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        func unlockTree(_ folder: URL) {
            _ = chflags(folder.path, 0)
            guard let walker = fm.enumerator(atPath: folder.path) else { return }
            for case let relative as String in walker { _ = chflags(folder.appendingPathComponent(relative).path, 0) }
        }
        defer {
            _ = chmod(unreadableURL.path, 0o644)
            unlockTree(problemSource)
            unlockTree(problemTarget)
        }
        _ = chmod(unreadableURL.path, 0)
        _ = chflags(lockedURL.path, UInt32(UF_IMMUTABLE))
        _ = chflags(lockedBigURL.path, UInt32(UF_IMMUTABLE))
        func isLocked(_ url: URL) -> Bool {
            guard let flags = DigiStreamEngine.fileFlags(url) else { return false }
            return flags & UInt32(UF_IMMUTABLE) != 0
        }
        func problemRun() async -> SyncProgress {
            await DigiStreamEngine.sync(source: problemSource, destination: problemTarget, archiveChanged: true, archiveRemoved: true,
                                        filter: BackupFilter(), control: BackupControl(), verify: true, readBack: true, report: { _ in })
        }
        let problemFirst = await problemRun()
        try check(problemFirst.status == DigiFastBackupEngine.completeStatus, "A problem file blocked the backup: " + problemFirst.status)
        try check(problemFirst.errorCount == 0, "A problem file was counted as an error")
        try check(problemFirst.problemFiles == 1, "Expected 1 file flagged as not backed up, got \(problemFirst.problemFiles)")
        try check(fm.fileExists(atPath: problemTarget.appendingPathComponent("fine.txt").path), "fine.txt should be backed up around the problem file")
        try check(!fm.fileExists(atPath: problemTarget.appendingPathComponent("no_read.txt").path), "The unreadable file should not be on the backup")
        let lockedCopy = problemTarget.appendingPathComponent("locked.txt")
        let lockedBigCopy = problemTarget.appendingPathComponent("locked_big.bin")
        let lockedCopyData = try Data(contentsOf: lockedCopy)
        try check(lockedCopyData == Data("locked v1".utf8), "Locked small file was not backed up correctly")
        let lockedBigCopyData = try Data(contentsOf: lockedBigCopy)
        let lockedBigSourceData = try Data(contentsOf: lockedBigURL)
        try check(lockedBigCopyData == lockedBigSourceData, "Locked large file was not backed up correctly")
        try check(isLocked(lockedCopy) && isLocked(lockedBigCopy), "Backup copies of locked files should be locked too")
        try check((try? leakedTemporaries(problemTarget)) != true, "A problem file left a temp behind")
        let problemReport = try String(contentsOfFile: problemFirst.reportPath, encoding: .utf8)
        try check(problemReport.contains("COULDN'T BE BACKED UP") && problemReport.contains("no_read.txt"), "Report doesn't list the file that couldn't be backed up")
        try check(!problemReport.contains("copied before checksums"), "Report wrongly says a skipped file was copied before checksums")
        // Change a locked original: the locked backup copy is archived and replaced, and stays locked.
        _ = chflags(lockedURL.path, 0)
        try Data("locked v2".utf8).write(to: lockedURL)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_500)], ofItemAtPath: lockedURL.path)
        _ = chflags(lockedURL.path, UInt32(UF_IMMUTABLE))
        let problemSecond = await problemRun()
        try check(problemSecond.status == DigiFastBackupEngine.completeStatus, "Replacing a locked backup copy failed: " + problemSecond.status)
        let replacedData = try Data(contentsOf: lockedCopy)
        try check(replacedData == Data("locked v2".utf8), "Locked file's new version was not backed up")
        try check(isLocked(lockedCopy), "Replaced copy of a locked file should still be locked")
        let archivedLocked = try archivedCopy(in: problemTarget, category: "Replaced", name: "locked.txt")
        try check(archivedLocked == Data("locked v1".utf8), "Older version of a locked file was not archived")
        // A temp that inherited a lock (left by an older build) is still swept.
        let lockedOrphan = problemTarget.appendingPathComponent(".shootwrap-LOCKED-TEST.tmp")
        try Data("x".utf8).write(to: lockedOrphan)
        _ = chflags(lockedOrphan.path, UInt32(UF_IMMUTABLE))
        let sweptLocked = DigiStreamEngine.removeOrphanTemps(in: problemTarget)
        try check(sweptLocked == 1 && !fm.fileExists(atPath: lockedOrphan.path), "A locked orphan temp was not swept")
        print("PASS (v1.37): unreadable file flagged + skipped, locked files backed up and kept locked, locked temps swept")

        // v1.39: a backup that stops (or loses its drive) before reading copies back leaves a
        // record, and the next backup reads those copies back first (Nov 9, C1-C3).
        let earlySource = fixture.appendingPathComponent("EarlySource", isDirectory: true)
        let earlyTarget = fixture.appendingPathComponent("EarlyTarget", isDirectory: true)
        for folder in [earlySource, earlyTarget] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let earlyFiles: [String: Data] = [
            "a.txt": Data("alpha".utf8),
            "b.txt": Data("bravo".utf8),
            "sub/d.txt": Data("delta".utf8),
            "c.bin": Data(repeating: 3, count: 9 * 1024 * 1024)   // large lane
        ]
        for (relative, data) in earlyFiles {
            let url = earlySource.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        let earlyReports = earlyTarget.appendingPathComponent(DigiFastBackupEngine.reportsName)
        let pendingList = earlyReports.appendingPathComponent(DigiBackupReport.pendingFileName)
        let runMarker = earlyReports.appendingPathComponent(DigiBackupReport.runMarkerName)
        func earlyRun(readBack: Bool = true, stopAtVerify: Bool = false) async -> SyncProgress {
            let control = BackupControl()
            return await DigiStreamEngine.sync(source: earlySource, destination: earlyTarget, archiveChanged: true, archiveRemoved: true,
                filter: BackupFilter(), control: control, verify: true, readBack: readBack,
                report: { state in if stopAtVerify && state.verifyPhase { control.stop() } })
        }
        func damage(_ relative: String) throws {
            // Same size and date stamp, different bytes: only a read-back can tell.
            let url = earlyTarget.appendingPathComponent(relative)
            let size: Int = try Data(contentsOf: url).count
            try Data(repeating: 0x58, count: size).write(to: url)
            try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        func sourceHash(_ relative: String) throws -> UInt64 {
            try DigiChecksum.hashFile(earlySource.appendingPathComponent(relative), uncached: false)
        }
        func sameAsSource(_ relative: String) throws -> Bool {
            let copy = try Data(contentsOf: earlyTarget.appendingPathComponent(relative))
            let original = try Data(contentsOf: earlySource.appendingPathComponent(relative))
            return copy == original
        }
        // The pending list is appended line by line and reads back as a normal list.
        let journalURL = fixture.appendingPathComponent("journal.xxh64")
        let journalTest = DigiBackupReport.PendingJournal(url: journalURL)
        journalTest.append("x/one.txt", 1)
        journalTest.append("two.txt", 0xABCDEF)
        journalTest.close()
        let journalRead = DigiBackupReport.readChecksums(journalURL)
        try check(journalRead["x/one.txt"] == XXHash64.hex(1) && journalRead["two.txt"] == XXHash64.hex(0xABCDEF), "Pending list lines didn't read back")
        // 1. Stopped at the start of the read-back pass: copies are on the drive, on record, unverified.
        let stopRun = await earlyRun(stopAtVerify: true)
        try check(stopRun.status.hasPrefix("Stopped"), "Stop at read-back was ignored: " + stopRun.status)
        try check(stopRun.completedFiles == 4 && stopRun.verifiedFiles == 0, "Expected 4 copied, 0 verified before the stop")
        try check(stopRun.pendingReadBack == 4, "Expected 4 copies waiting to be read back, got \(stopRun.pendingReadBack)")
        let pendingAfterStop = DigiBackupReport.readChecksums(pendingList)
        try check(pendingAfterStop.count == 4, "Pending list should hold the 4 unverified copies")
        for relative in earlyFiles.keys {
            let expectedHex: String = try XXHash64.hex(sourceHash(relative))
            try check(pendingAfterStop[relative] == expectedHex, "Pending checksum is wrong: " + relative)
        }
        try check(!fm.fileExists(atPath: runMarker.path), "Run marker left after a clean stop")
        // 2. The next run copies nothing new but reads those 4 back, and says so.
        let caughtUp = await earlyRun()
        try check(caughtUp.status == DigiFastBackupEngine.completeStatus, "Catch-up run failed: " + caughtUp.status)
        try check(caughtUp.completedFiles == 0 && caughtUp.earlierVerified == 4, "Expected 4 earlier copies read back, got \(caughtUp.earlierVerified)")
        try check(caughtUp.pendingReadBack == 0 && !fm.fileExists(atPath: pendingList.path), "Pending list should be gone once everything is read back")
        try check(!caughtUp.reportPath.isEmpty, "Catch-up run wrote no report")
        let caughtUpReport = try String(contentsOfFile: caughtUp.reportPath, encoding: .utf8)
        try check(caughtUpReport.contains("read back and verified this run"), "Report doesn't mention the earlier copies it verified")
        let quiet = await earlyRun()
        try check(quiet.earlierVerified == 0 && quiet.reportPath.isEmpty, "A run with nothing to do read back again or wrote a report")
        // 3. A pending copy that went bad on the drive is copied again and checked.
        try DigiBackupReport.writePending(["b.txt": try sourceHash("b.txt")], to: pendingList)
        try damage("b.txt")
        let repairedRun = await earlyRun()
        try check(repairedRun.status == DigiFastBackupEngine.completeStatus, "Repairing an earlier copy failed: " + repairedRun.status)
        try check(repairedRun.repairedFiles == 1 && repairedRun.earlierVerified == 1, "Bad earlier copy wasn't re-copied")
        let bFixed: Bool = try sameAsSource("b.txt")
        try check(bFixed, "Re-copied earlier file differs from the source")
        // 4. A yanked drive can lose the last pending lines; the run marker catches what the
        //    unfinished run placed (APFS / HFS+ only, by status-change time).
        let fixtureType: String = DigiStreamEngine.filesystemType(earlyTarget)
        if fixtureType == "apfs" || fixtureType == "hfs" {
            try DigiBackupReport.writeRunMarker(runMarker, started: Date().addingTimeInterval(-5))
            try damage("a.txt")
            let adopted = await earlyRun()
            try check(adopted.status == DigiFastBackupEngine.completeStatus, "Run after an unfinished run failed: " + adopted.status)
            try check(adopted.repairedFiles >= 1 && adopted.earlierVerified >= 1, "Files placed by the unfinished run weren't checked")
            let aFixed: Bool = try sameAsSource("a.txt")
            try check(aFixed, "File placed by the unfinished run wasn't fixed")
            try check(!fm.fileExists(atPath: runMarker.path), "Run marker should be cleared once everything is checked")
        }
        // 5. Quick never reads back, so earlier copies stay pending until a Full run.
        try DigiBackupReport.writePending(["c.bin": try sourceHash("c.bin")], to: pendingList)
        let quickKeeps = await earlyRun(readBack: false)
        try check(quickKeeps.pendingReadBack == 1 && fm.fileExists(atPath: pendingList.path), "Quick run dropped a copy that still needs reading back")
        let fullAfterQuick = await earlyRun()
        try check(fullAfterQuick.earlierVerified == 1 && !fm.fileExists(atPath: pendingList.path), "Full run didn't read back what Quick left")
        // 6. A pending record for a file that changed since is dropped; the new copy is checked as usual.
        try DigiBackupReport.writePending(["sub/d.txt": 0], to: pendingList)
        let changedURL = earlySource.appendingPathComponent("sub/d.txt")
        try Data("delta v2".utf8).write(to: changedURL)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_900)], ofItemAtPath: changedURL.path)
        let superseded = await earlyRun()
        try check(superseded.status == DigiFastBackupEngine.completeStatus, "Stale pending record broke the backup: " + superseded.status)
        try check(superseded.completedFiles == 1 && superseded.verifiedFiles == 1 && superseded.earlierVerified == 0, "Changed file wasn't copied and verified normally")
        try check(!fm.fileExists(atPath: pendingList.path), "Stale pending record wasn't dropped")
        let earlyList = DigiBackupReport.readChecksums(earlyReports.appendingPathComponent(DigiBackupReport.checksumFileName))
        for relative in earlyFiles.keys {
            let expectedHex: String = try XXHash64.hex(sourceHash(relative))
            try check(earlyList[relative] == expectedHex, "Checksum list is wrong after catch-up runs: " + relative)
        }
        print("PASS (v1.39): stopped read-back is recorded and finished next run; bad earlier copies re-copied; unfinished-run marker (\(fixtureType)); Quick keeps pending; stale records dropped")

        // v1.40: a backup folder that already holds a backup of a different folder is caught
        // before a manual backup (Nov 9: Tricky backed up into Big_C1 by mistake).
        try check(DigiFastBackupEngine.otherSourceName(source: earlySource, destination: earlyTarget) == nil, "Same source flagged as a different folder")
        let otherForProblem: String? = DigiFastBackupEngine.otherSourceName(source: problemSource, destination: earlyTarget)
        try check(otherForProblem == "EarlySource", "Different source not caught by name: \(otherForProblem ?? "nil")")
        let emptyFolder = fixture.appendingPathComponent("EmptyBackupFolder", isDirectory: true)
        try fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        try check(DigiFastBackupEngine.otherSourceName(source: earlySource, destination: emptyFolder) == nil, "A new, empty folder was flagged")
        // Backups made before 1.40 have no name on record: the session database name decides,
        // or nothing in common at the top level.
        let oldBackup = fixture.appendingPathComponent("OldBackup", isDirectory: true)
        try fm.createDirectory(at: oldBackup, withIntermediateDirectories: true)
        var oldRecord = SyncRecord()
        oldRecord.files = ["Capture/a.IIQ": "copied-size-date", "Shoot_A.cosessiondb": "copied-size-date"]
        try JSONEncoder().encode(oldRecord).write(to: oldBackup.appendingPathComponent(DigiFastBackupEngine.manifestName))
        let sessionB = fixture.appendingPathComponent("Shoot_B", isDirectory: true)
        try fm.createDirectory(at: sessionB.appendingPathComponent("Capture"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: sessionB.appendingPathComponent("Shoot_B.cosessiondb"))
        let otherSession: String? = DigiFastBackupEngine.otherSourceName(source: sessionB, destination: oldBackup)
        try check(otherSession == "Shoot_A", "Older backup of another session not caught: \(otherSession ?? "nil")")
        let sessionA = fixture.appendingPathComponent("Shoot_A_renamed", isDirectory: true)
        try fm.createDirectory(at: sessionA.appendingPathComponent("Capture"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: sessionA.appendingPathComponent("Shoot_A.cosessiondb"))
        try check(DigiFastBackupEngine.otherSourceName(source: sessionA, destination: oldBackup) == nil, "Same session (database name) in a renamed folder was flagged")
        let unrelated: String? = DigiFastBackupEngine.otherSourceName(source: problemSource, destination: oldBackup)
        try check(unrelated == "", "Older backup with nothing in common not caught")
        print("PASS (v1.40): wrong-folder check (name on record, older backups by session database or nothing in common)")

        // v1.46: removal safety guard. Many tracked files leaving the source (or an empty
        // source) holds the drive with nothing changed, until the person OKs it.
        try check(!DigiFastBackupEngine.removalNeedsOK(removed: 50, tracked: 100, sourceFiles: 50), "50 removed (the minimum) held")
        try check(DigiFastBackupEngine.removalNeedsOK(removed: 51, tracked: 100, sourceFiles: 49), "51 of 100 removed not held")
        try check(!DigiFastBackupEngine.removalNeedsOK(removed: 60, tracked: 1000, sourceFiles: 940), "6% removed held")
        try check(DigiFastBackupEngine.removalNeedsOK(removed: 3, tracked: 3, sourceFiles: 0), "Empty source not held")
        let guardSource = fixture.appendingPathComponent("GuardSource", isDirectory: true)
        let guardTarget = fixture.appendingPathComponent("GuardTarget", isDirectory: true)
        try fm.createDirectory(at: guardSource.appendingPathComponent("Capture"), withIntermediateDirectories: true)
        try fm.createDirectory(at: guardTarget, withIntermediateDirectories: true)
        for number in 0..<80 {
            let url = guardSource.appendingPathComponent(String(format: "Capture/frame_%03d.raw", number))
            try Data(repeating: UInt8(number), count: 1000 + number).write(to: url)
            try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        func guardRun(_ allow: Bool) async -> SyncProgress {
            await DigiStreamEngine.sync(source: guardSource, destination: guardTarget, archiveChanged: true, archiveRemoved: true,
                                        filter: BackupFilter(), control: BackupControl(), verify: true, readBack: true,
                                        allowLargeRemoval: allow, report: { _ in })
        }
        let guardFirst = await guardRun(false)
        try check(guardFirst.status == DigiFastBackupEngine.completeStatus && guardFirst.completedFiles == 80, "Guard fixture didn't back up: " + guardFirst.status)
        let guardList = guardTarget.appendingPathComponent(DigiFastBackupEngine.reportsName).appendingPathComponent(DigiBackupReport.checksumFileName)
        let listBefore: Data? = try? Data(contentsOf: guardList)
        for number in 0..<60 {
            try fm.removeItem(at: guardSource.appendingPathComponent(String(format: "Capture/frame_%03d.raw", number)))
        }
        let held = await guardRun(false)
        try check(held.status.hasPrefix(DigiFastBackupEngine.removalHoldPrefix) && held.heldRemovals == 60 && held.heldOf == 80, "60 of 80 removed wasn't held: " + held.status)
        try check(fm.fileExists(atPath: guardTarget.appendingPathComponent("Capture/frame_000.raw").path), "A held drive's file was moved")
        try check(!fm.fileExists(atPath: guardTarget.appendingPathComponent(DigiFastBackupEngine.archiveName).path), "A held drive got an archive")
        try check((try? Data(contentsOf: guardList)) == listBefore, "A held drive's checksum list changed")
        let approved = await guardRun(true)
        try check(approved.status == DigiFastBackupEngine.completeStatus, "OK'd removal didn't finish: " + approved.status)
        try check(!fm.fileExists(atPath: guardTarget.appendingPathComponent("Capture/frame_000.raw").path), "OK'd removal left the file in place")
        let archived: [String] = (try? fm.subpathsOfDirectory(atPath: guardTarget.appendingPathComponent(DigiFastBackupEngine.archiveName).path)) ?? []
        try check(archived.filter { $0.hasSuffix(".raw") }.count == 60, "OK'd removal didn't archive 60 files: \(archived.filter { $0.hasSuffix(".raw") }.count)")
        for number in 60..<80 {
            try fm.removeItem(at: guardSource.appendingPathComponent(String(format: "Capture/frame_%03d.raw", number)))
        }
        let emptyHeld = await guardRun(false)
        try check(emptyHeld.status.hasPrefix(DigiFastBackupEngine.removalHoldPrefix) && emptyHeld.status.contains("empty") && emptyHeld.heldRemovals == 20, "Empty source wasn't held: " + emptyHeld.status)
        try check(fm.fileExists(atPath: guardTarget.appendingPathComponent("Capture/frame_079.raw").path), "Empty source moved files")
        DigiStreamEngine.flushToDrive(guardTarget, file: guardList)
        print("PASS (v1.46): removal safety guard (holds with nothing changed, OK moves to archive, empty source held); flush")

        // v1.42: Metadata sidecars. Pure rules always; real ExifTool writes when it's installed.
        let metaNow = Date(timeIntervalSince1970: 1_793_000_000)
        try check(MetadataSidecar.fillIns("© {year} Jeff", session: "S1", now: metaNow).hasSuffix(" Jeff") && MetadataSidecar.fillIns("{session}", session: "S1", now: metaNow) == "S1", "Fill-ins wrong")
        try check(MetadataSidecar.normalizedList(" a, b;c ,, ") == "a, b, c", "Keyword list not normalized")
        try check(MetadataSidecar.sidecarURL(for: URL(fileURLWithPath: "/x/RAW_1.NEF")).path == "/x/RAW_1.xmp", "Sidecar name wrong")
        try check(MetadataSidecar.sessionName(for: URL(fileURLWithPath: "/x/Shoot_A/Capture")) == "Shoot_A", "Session name from Capture folder wrong")
        let resolvedMeta = MetadataSidecar.resolvedValues(["XMP-dc:Rights": "  ", "XMP-photoshop:TransmissionReference": "{session}"], session: "S1", now: metaNow)
        try check(resolvedMeta.count == 1 && resolvedMeta["XMP-photoshop:TransmissionReference"] == "S1", "Empty fields should be left out")
        let parsedMeta = MetadataSidecar.jsonValues("[{\"SourceFile\":\"a.xmp\",\"XMP-dc:Creator\":\"Jeff\",\"XMP-dc:Subject\":[\"a\",\"b\"],\"XMP-xmpRights:Marked\":true}]")
        try check(parsedMeta["xmp-dc:creator"] == "Jeff" && parsedMeta["xmp-dc:subject"] == "a, b" && parsedMeta["sourcefile"] == nil, "ExifTool JSON not read right")
        try check(MetadataFields.canonicalTag("xmp-getty:originalfilename") == "XMP-getty:OriginalFileName", "Tag case not matched")
        try check(MetadataSidecar.fillIns("{filename}", session: "S", filename: "A_1.NEF", now: metaNow) == "A_1.NEF", "{filename} fill-in wrong")
        try check(MetadataFields.sections.map(\.title) == ["IPTC - Contact", "IPTC - Content", "IPTC - Image", "IPTC - Status", "IPTC - Getty Images", "Keywords"], "Sections don't match Capture One")
        let clientMeta = MetadataSidecar.clientFields(parsedMeta)
        try check(clientMeta.values.count == 2 && clientMeta.otherFields == 1 && clientMeta.error == nil, "Client .xmp fields not mapped")
        let metaFolder = fixture.appendingPathComponent("MetaSession/Capture", isDirectory: true)
        try fm.createDirectory(at: metaFolder.appendingPathComponent("CaptureOne/Cache", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: metaFolder.appendingPathComponent("Sub", isDirectory: true), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: metaFolder.appendingPathComponent("A_0001.NEF"))
        try Data("raw".utf8).write(to: metaFolder.appendingPathComponent("Sub/A_0002.iiq"))
        try Data("raw".utf8).write(to: metaFolder.appendingPathComponent("CaptureOne/Cache/A_0003.NEF"))
        try Data("jpg".utf8).write(to: metaFolder.appendingPathComponent("A_0001.jpg"))
        let metaRaws = MetadataSidecar.listRaws(in: metaFolder, recursive: true).map(\.lastPathComponent).sorted()
        try check(metaRaws == ["A_0001.NEF", "A_0002.iiq"], "Raw listing wrong: \(metaRaws)")
        try check(MetadataSidecar.listRaws(in: metaFolder, recursive: false).count == 1, "Top-level raw listing wrong")
        if let exiftool = MetadataSidecar.exiftoolPath() {
            let rawA = metaFolder.appendingPathComponent("A_0001.NEF")
            let rawBefore = try Data(contentsOf: rawA)
            let metaFirst = MetadataSidecar.stamp(raw: rawA, tool: exiftool, values: ["XMP-dc:Creator": "Jeff Wolk", "XMP-dc:Rights": "© {year} Jeff Wolk", "XMP-dc:Subject": "campaign, studio", "XMP-getty:OriginalFileName": "{filename}", "XMP-getty:Personality": "Ann, Bo"], keepExisting: true, session: "MetaSession", now: metaNow)
            try check(metaFirst.ok && metaFirst.wrote == 5, "Sidecar not written: " + metaFirst.message)
            let sidecarA = MetadataSidecar.sidecarURL(for: rawA)
            let readA = MetadataSidecar.readTags(tool: exiftool, file: sidecarA, tags: ["XMP-dc:Creator", "XMP-dc:Subject", "XMP-getty:OriginalFileName"])
            try check(readA["xmp-dc:creator"] == "Jeff Wolk" && readA["xmp-dc:subject"] == "campaign, studio" && readA["xmp-getty:originalfilename"] == "A_0001.NEF", "Sidecar read-back wrong: \(readA)")
            let rawAfter = try Data(contentsOf: rawA)
            try check(rawBefore == rawAfter, "The raw itself was changed")
            let numberLike = MetadataSidecar.stamp(raw: metaFolder.appendingPathComponent("Sub/A_0002.iiq"), tool: exiftool, values: ["XMP-photoshop:TransmissionReference": "2026.10", "XMP-dc:Title": "007"], keepExisting: true, session: "MetaSession", now: metaNow)
            try check(numberLike.ok, "Number-like text didn't read back as written: " + numberLike.message)
            try check(MetadataSidecar.isScriptCopy(exiftool), "Tests didn't use the bundled ExifTool: " + exiftool)
            let metaSecond = MetadataSidecar.stamp(raw: rawA, tool: exiftool, values: ["XMP-dc:Creator": "Someone Else", "XMP-photoshop:Credit": "Credit"], keepExisting: true, session: "MetaSession", now: metaNow)
            try check(metaSecond.ok && metaSecond.wrote == 1 && metaSecond.kept == 1, "Keep-existing didn't keep: " + metaSecond.message)
            let readAgain = MetadataSidecar.readTags(tool: exiftool, file: sidecarA, tags: ["XMP-dc:Creator", "XMP-photoshop:Credit"])
            try check(readAgain["xmp-dc:creator"] == "Jeff Wolk" && readAgain["xmp-photoshop:credit"] == "Credit", "Existing value overwritten or new one missing")
            let metaLeftovers = try fm.contentsOfDirectory(atPath: metaFolder.path).filter { $0.hasSuffix("_original") }
            try check(metaLeftovers.isEmpty, "ExifTool left *_original files: \(metaLeftovers)")
            let presetURL = fixture.appendingPathComponent("Presets/Client A.xmp")
            let presetError = MetadataSidecar.writePreset(["XMP-dc:Creator": "Jeff Wolk", "XMP-dc:Rights": "© {year} Jeff", "XMP-dc:Subject": "a, b"], to: presetURL, tool: exiftool)
            try check(presetError == nil, "Preset not saved: \(presetError ?? "")")
            let presetBack = MetadataSidecar.loadClient(presetURL, tool: exiftool)
            try check(presetBack.values["XMP-dc:Rights"] == "© {year} Jeff" && presetBack.values["XMP-dc:Subject"] == "a, b", "Preset didn't read back: \(presetBack.values)")
            let presetAgain = MetadataSidecar.writePreset(["XMP-dc:Creator": "Jeff Wolk"], to: presetURL, tool: exiftool)
            try check(presetAgain == nil && MetadataSidecar.loadClient(presetURL, tool: exiftool).values.count == 1, "Re-saving a preset kept a cleared field")
            // v1.44: embedding into a real JPEG (opt-in), and skipping it when off.
            let jpegURL = metaFolder.appendingPathComponent("Export_0001.jpg")
            let jpegContext = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            jpegContext?.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1))
            jpegContext?.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            if let image = jpegContext?.makeImage(), let destination = CGImageDestinationCreateWithURL(jpegURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                _ = CGImageDestinationFinalize(destination)
            }
            try check(MetadataSidecar.imageOpens(jpegURL), "Test JPEG wasn't made")
            let skipped = MetadataSidecar.process(file: jpegURL, tool: exiftool, values: ["XMP-dc:Creator": "Jeff Wolk"], keepExisting: true, session: "S", embed: false, now: metaNow)
            try check(!skipped.ok && MetadataSidecar.readTags(tool: exiftool, file: jpegURL, tags: ["XMP-dc:Creator"]).isEmpty, "JPEG was written with embedding off")
            let embedded = MetadataSidecar.process(file: jpegURL, tool: exiftool, values: ["XMP-dc:Creator": "Jeff Wolk", "XMP-dc:Rights": "© {year} Jeff Wolk", "XMP-dc:Subject": "a, b"], keepExisting: true, session: "S", embed: true, now: metaNow)
            try check(embedded.ok && embedded.wrote == 3, "JPEG not embedded: " + embedded.message)
            try check(MetadataSidecar.imageOpens(jpegURL), "JPEG doesn't open after embedding")
            let jpegRead = MetadataSidecar.readTags(tool: exiftool, file: jpegURL, tags: ["XMP-dc:Creator", "XMP-dc:Subject"])
            try check(jpegRead["xmp-dc:creator"] == "Jeff Wolk" && jpegRead["xmp-dc:subject"] == "a, b", "Embedded values wrong: \(jpegRead)")
            let embeddedAgain = MetadataSidecar.process(file: jpegURL, tool: exiftool, values: ["XMP-dc:Creator": "Someone Else"], keepExisting: true, session: "S", embed: true, now: metaNow)
            try check(embeddedAgain.ok && embeddedAgain.wrote == 0 && embeddedAgain.kept == 1, "Keep-existing didn't protect the JPEG's Creator")
            try check(!fm.fileExists(atPath: metaFolder.appendingPathComponent("Export_0001.jpg_original").path) && !fm.fileExists(atPath: MetadataSidecar.sidecarURL(for: jpegURL).path), "Embedding left an _original or a sidecar")
            print("PASS (v1.45): bundled ExifTool (" + exiftool + "), number-like text kept as text")
            print("PASS (v1.44): JPEG embedding (opt-in, still opens, values read back, keeps existing, no _original or sidecar)")
            print("PASS (v1.43): Capture One sections, Getty fields, {filename}, presets as .xmp")
            print("PASS (v1.42): metadata sidecars (fill-ins, lists, client .xmp, raw listing; ExifTool write, keep existing, raw untouched, no _original)")
        } else {
            print("PASS (v1.42): metadata sidecar rules (ExifTool not installed here, so real writes were skipped)")
        }

        print("PASS (v17): Digi Stream bytes, dates, permissions, extended attributes, empty folders, incrementals, archives, space check, mid-file and paused stop")
    }
}
