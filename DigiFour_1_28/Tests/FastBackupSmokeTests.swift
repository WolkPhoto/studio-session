import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "FastBackupSmokeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct FastBackupSmokeTests {
    static func main() async throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("DigiSuite-FastBackup-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        // v21: a second app cannot back up into a folder that is already in use.
        do {
            let lockDir = fixture.appendingPathComponent("Locks", isDirectory: true)
            let lockedTarget = fixture.appendingPathComponent("LockedTarget", isDirectory: true)
            let firstLock = DigiDestinationLock.acquire(lockedTarget, folder: lockDir)
            guard case .acquired(let held) = firstLock else { throw NSError(domain: "FastBackupSmokeTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Destination lock was not acquired"]) }
            guard case .busy = DigiDestinationLock.acquire(lockedTarget, folder: lockDir) else { throw NSError(domain: "FastBackupSmokeTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Second backup into the same folder was not blocked"]) }
            withExtendedLifetime(held) {}
        }
        do {
            let lockDir = fixture.appendingPathComponent("Locks", isDirectory: true)
            let lockedTarget = fixture.appendingPathComponent("LockedTarget", isDirectory: true)
            guard case .acquired = DigiDestinationLock.acquire(lockedTarget, folder: lockDir) else { throw NSError(domain: "FastBackupSmokeTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Destination lock was not released"]) }
        }
        print("PASS (v21): one app at a time per backup folder")
        let source = fixture.appendingPathComponent("Source", isDirectory: true)
        let first = fixture.appendingPathComponent("First", isDirectory: true)
        let second = fixture.appendingPathComponent("Second", isDirectory: true)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for folder in [source, first, second] { try fm.createDirectory(at: folder, withIntermediateDirectories: false) }
        func put(_ relative: String, _ text: String, modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws {
            let url = source.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        func contents(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
        func run(_ target: URL, filter: BackupFilter = BackupFilter(), snapshot: DigiSyncSourceSnapshot? = nil, control: BackupControl = BackupControl()) async -> SyncProgress {
            await DigiStreamEngine.sync(source: source, destination: target, archiveChanged: true,
                archiveRemoved: true, filter: filter, snapshot: snapshot, control: control, report: { _ in })
        }
        func archiveContains(_ text: String, category: String) throws -> Bool {
            let root = first.appendingPathComponent(DigiFastBackupEngine.archiveName)
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
            for case let item as URL in iterator {
                if item.path.contains("/" + category + "/"),
                   (try item.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                   try contents(item) == text { return true }
            }
            return false
        }

        try put("Capture/A.iiq", "original A")
        try put("Capture/B.iiq", "original B")
        try put(".hidden", "hidden")
        try put("_ShootWrap_Archive/old.txt", "not source data")
        try fm.createDirectory(at: source.appendingPathComponent("Selects/Empty"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: source.appendingPathComponent("linked"), withDestinationURL: fixture)
        let inventory = try DigiFastBackupEngine.snapshot(source, filter: BackupFilter())
        try require(inventory.files.count == 2, "Source exclusions or symlink handling failed")
        let initial = await run(first, snapshot: inventory)
        try require(initial.status == DigiFastBackupEngine.completeStatus && initial.completedFiles == 2 && initial.errorCount == 0, "First backup failed: " + initial.status)
        let copiedA = try contents(first.appendingPathComponent("Capture/A.iiq"))
        try require(copiedA == "original A", "Native copy changed file bytes")
        try require(fm.fileExists(atPath: first.appendingPathComponent("Selects/Empty").path), "Empty directories were lost")
        try require(!fm.fileExists(atPath: first.appendingPathComponent(".hidden").path), "Hidden file copied by default")
        try require(!fm.fileExists(atPath: first.appendingPathComponent("linked").path), "Source symlink copied")
        let unchanged = await run(first)
        try require(unchanged.totalFiles == 0 && unchanged.completedFiles == 0 && unchanged.unchangedFiles == 2, "Unchanged incremental run recopied files")
        // Reconcile empty directories even when there are no changed files.
        try fm.removeItem(at: first.appendingPathComponent("Selects/Empty"))
        let emptyRepair = await run(first)
        try require(emptyRepair.totalFiles == 0 && fm.fileExists(atPath: first.appendingPathComponent("Selects/Empty").path), "Empty directory repair failed")

        // An existing drag-and-drop backup is adopted without recopying its data.
        try fm.createDirectory(at: second.appendingPathComponent("Capture"), withIntermediateDirectories: true)
        try fm.copyItem(at: source.appendingPathComponent("Capture/A.iiq"), to: second.appendingPathComponent("Capture/A.iiq"))
        let adoption = await run(second)
        try require(adoption.completedFiles == 1 && adoption.unchangedFiles == 1, "Existing backup was not adopted incrementally")
        // Same-sized content with a changed date must be copied on the next run.
        try put("Capture/A.iiq", "modified A", modified: stamp.addingTimeInterval(10))
        try put("Output/New.jpg", "new data", modified: stamp.addingTimeInterval(10))
        try fm.removeItem(at: source.appendingPathComponent("Capture/B.iiq"))
        let update = await run(first)
        try require(update.completedFiles == 2 && update.errorCount == 0, "New/modified files were not copied")
        let updatedA = try contents(first.appendingPathComponent("Capture/A.iiq"))
        try require(updatedA == "modified A", "Changed file not replaced")
        let oldArchived = try archiveContains("original A", category: "Replaced")
        let removedArchived = try archiveContains("original B", category: "Removed from source")
        try require(oldArchived && removedArchived, "Archive policy lost previous data")
        try require(!fm.fileExists(atPath: first.appendingPathComponent("Capture/B.iiq").path), "Removed tracked file not archived")

        // Copy-only deliberately does not rehash same-size, same-date contents.
        let targetA = first.appendingPathComponent("Capture/A.iiq")
        try Data("different!".utf8).write(to: targetA)
        try fm.setAttributes([.modificationDate: stamp.addingTimeInterval(10)], ofItemAtPath: targetA.path)
        let metadataOnly = await run(first)
        try require(metadataOnly.completedFiles == 0, "Fast mode unexpectedly reread/replaced matching metadata")
        let manifestURL = first.appendingPathComponent(DigiFastBackupEngine.manifestName)
        var legacy = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: manifestURL))
        legacy.files["Capture/A.iiq"] = String(repeating: "a", count: 64)
        try JSONEncoder().encode(legacy).write(to: manifestURL)
        let migrated = await run(first)
        try require(migrated.errorCount == 0 && migrated.completedFiles == 0, "Legacy manifest migration recopied files")
        let current = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: manifestURL))
        try require(current.files["Capture/A.iiq"] == "size-date-match", "Fast backup incorrectly claimed a checksum")

        let noArchive = fixture.appendingPathComponent("NoArchive")
        try fm.createDirectory(at: noArchive, withIntermediateDirectories: false)
        let noArchiveFirst = await DigiStreamEngine.sync(source: source, destination: noArchive,
            archiveChanged: false, archiveRemoved: false, filter: BackupFilter(), control: BackupControl(), report: { _ in })
        try require(noArchiveFirst.errorCount == 0, "Non-archiving first copy failed")
        try put("Capture/A.iiq", "replacement without archive", modified: stamp.addingTimeInterval(50))
        let noArchiveUpdate = await DigiStreamEngine.sync(source: source, destination: noArchive,
            archiveChanged: false, archiveRemoved: false, filter: BackupFilter(), control: BackupControl(), report: { _ in })
        let replacedWithoutArchive = try contents(noArchive.appendingPathComponent("Capture/A.iiq"))
        try require(noArchiveUpdate.errorCount == 0 && replacedWithoutArchive == "replacement without archive", "Non-archiving replacement failed")
        try require(!fm.fileExists(atPath: noArchive.appendingPathComponent(DigiFastBackupEngine.archiveName).path), "Disabled archive policy created an archive")
        let noArchiveUnchanged = await DigiStreamEngine.sync(source: source, destination: noArchive,
            archiveChanged: false, archiveRemoved: false, filter: BackupFilter(), control: BackupControl(), report: { _ in })
        try require(noArchiveUnchanged.errorCount == 0 && noArchiveUnchanged.completedFiles == 0, "Replacement did not preserve the new modification date")

        // An excluded previously tracked file must not be archived as a removal.
        let preserved = second.appendingPathComponent("Capture/B.iiq")
        var excluded = BackupFilter()
        excluded.excludedNames = ["b.iiq"]
        let filtered = await run(second, filter: excluded)
        try require(filtered.errorCount == 0 && fm.fileExists(atPath: preserved.path), "Excluded destination file was archived")
        let hidden = await run(second, filter: BackupFilter(includeHidden: true))
        try require(hidden.errorCount == 0 && fm.fileExists(atPath: second.appendingPathComponent(".hidden").path), "Include-hidden option failed")

        // A stale planned change must never replace the old destination file.
        try put("Capture/A.iiq", "planned version", modified: stamp.addingTimeInterval(20))
        let stale = try DigiFastBackupEngine.snapshot(source, filter: BackupFilter())
        let beforeStale = try Data(contentsOf: targetA)
        try put("Capture/A.iiq", "newer source after planning", modified: stamp.addingTimeInterval(30))
        let staleResult = await run(first, snapshot: stale)
        try require(staleResult.errorCount == 1, "Source mutation was not detected")
        let afterStale = try Data(contentsOf: targetA)
        try require(beforeStale == afterStale, "Source mutation overwrote the old destination")

        let stopped = BackupControl(); stopped.stop()
        let stopResult = await run(first, control: stopped)
        try require(stopResult.status.hasPrefix("Stopped"), "Stop was ignored")
        let paused = BackupControl(); paused.pause()
        let pausedRun = Task { await run(first, control: paused) }
        try await Task.sleep(nanoseconds: 60_000_000)
        paused.stop()
        let pauseResult = await pausedRun.value
        try require(pauseResult.status.hasPrefix("Stopped"), "Stop could not release a paused backup")
        let stopBeforeCopy = BackupControl()
        let beforeStop = try Data(contentsOf: targetA)
        let stopAtPlan = await DigiStreamEngine.sync(source: source, destination: first,
            archiveChanged: true, archiveRemoved: true, filter: BackupFilter(), control: stopBeforeCopy, report: { state in
                if state.totalFiles > 0 { stopBeforeCopy.stop() }
            })
        try require(stopAtPlan.status.hasPrefix("Stopped"), "Stop before a native copy was ignored")
        let afterStop = try Data(contentsOf: targetA)
        try require(beforeStop == afterStop, "Stopped backup overwrote a destination")

        let blocked = fixture.appendingPathComponent("Blocked")
        let outside = fixture.appendingPathComponent("Outside")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: false)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: blocked.appendingPathComponent("Capture"), withDestinationURL: outside)
        let blockedResult = await run(blocked)
        try require(blockedResult.errorCount == 1, "Destination directory symlink was followed")
        let outsideItems = try fm.contentsOfDirectory(atPath: outside.path)
        try require(outsideItems.isEmpty, "Copy escaped through a destination symlink")
        let missing = fixture.appendingPathComponent("Missing")
        let missingResult = await run(missing)
        try require(missingResult.errorCount == 1 && !fm.fileExists(atPath: missing.path), "Unavailable destination was recreated")
        var overlapRejected = false
        do { _ = try DigiFastBackupEngine.plan(source: source, destination: source.appendingPathComponent("Capture")) }
        catch { overlapRejected = true }
        try require(overlapRejected, "Source/target containment was accepted")

        // Both destination workers can share one immutable source snapshot.
        let shared = try DigiFastBackupEngine.snapshot(source, filter: BackupFilter())
        async let one = run(first, snapshot: shared)
        async let two = run(second, snapshot: shared)
        let pair = await (one, two)
        try require(pair.0.errorCount == 0 && pair.1.errorCount == 0, "Concurrent destination copies failed")
        for number in 0..<100 { try put("Many/\(number).txt", "small file \(number)") }
        let reports = Reports()
        let coalesced = await DigiStreamEngine.sync(source: source, destination: first,
            archiveChanged: true, archiveRemoved: true, filter: BackupFilter(), control: BackupControl(), report: { _ in reports.add() })
        try require(coalesced.errorCount == 0 && coalesced.completedFiles == 100, "Many-file copy failed")
        for number in 0..<100 {
            let actual = try contents(first.appendingPathComponent("Many/\(number).txt"))
            try require(actual == "small file \(number)", "Parallel copy mixed up file contents")
        }
        try require(reports.value < coalesced.completedFiles, "UI updates were still sent for every small file")
        // Odd final batch, zero-byte file and larger data. Read actual bytes,
        // not merely the copy counters.
        try put("Batch/Empty", "")
        try put("Batch/Large", String(repeating: "0123456789abcdef", count: 131_072))
        try put("Batch/Tail", "odd batch tail")
        let batchTarget = fixture.appendingPathComponent("BatchReference")
        try fm.createDirectory(at: batchTarget, withIntermediateDirectories: false)
        let batch = await run(batchTarget)
        try require(batch.errorCount == 0, "Batch copy failed: " + batch.status)
        let comparison = try DigiFastBackupEngine.snapshot(source, filter: BackupFilter())
        for file in comparison.files {
            let expected = try Data(contentsOf: file.source)
            let copiedBytes = try Data(contentsOf: batchTarget.appendingPathComponent(file.relative))
            try require(expected == copiedBytes, "Copy content mismatch: " + file.relative)
        }
        let repeatBatch = await run(batchTarget)
        try require(repeatBatch.completedFiles == 0 && repeatBatch.unchangedFiles == comparison.files.count, "Copies were not adopted on repeat")
        let batchPaths = try fm.subpathsOfDirectory(atPath: batchTarget.path)
        try require(!batchPaths.contains(where: { $0.hasSuffix(".tmp") && $0.contains(".shootwrap-") }), "Batch temporary leaked")
        let remaining = try fm.subpathsOfDirectory(atPath: first.path)
        try require(!remaining.contains(where: { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".shootwrap-") && $0.hasSuffix(".tmp") }), "A temporary copy leaked")
        // Version 16: per-destination controls. Stopping one destination must
        // not stop the other; stopping the parent stops every destination.
        let parent = BackupControl()
        let stopOnlyThis = BackupControl(parent: parent)
        let keepGoing = BackupControl(parent: parent)
        stopOnlyThis.stop()
        try require(!parent.isStopped && !keepGoing.isStopped && stopOnlyThis.isStopped, "A destination stop leaked to other destinations")
        let childStopTarget = fixture.appendingPathComponent("ChildStop")
        let childGoTarget = fixture.appendingPathComponent("ChildGo")
        for target in [childStopTarget, childGoTarget] { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
        async let childStopped = run(childStopTarget, control: stopOnlyThis)
        async let childContinued = run(childGoTarget, control: keepGoing)
        let childPair = await (childStopped, childContinued)
        try require(childPair.0.status.hasPrefix("Stopped") && childPair.0.completedFiles == 0, "Stopped destination still copied")
        try require(childPair.1.status == DigiFastBackupEngine.completeStatus && childPair.1.errorCount == 0, "Other destination did not finish: " + childPair.1.status)
        let pausedParent = BackupControl()
        let pausedChild = BackupControl(parent: pausedParent)
        pausedParent.pause()
        let inheritedPause = Task { await run(fixture.appendingPathComponent("ChildGo"), control: pausedChild) }
        try await Task.sleep(nanoseconds: 60_000_000)
        pausedParent.stop()
        let inheritedResult = await inheritedPause.value
        try require(inheritedResult.status.hasPrefix("Stopped") && pausedChild.isStopped, "Parent pause/stop did not reach a destination")

        // Version 16: a backup that cannot fit stops before copying anything.
        let fullTarget = fixture.appendingPathComponent("FullDrive")
        try fm.createDirectory(at: fullTarget, withIntermediateDirectories: false)
        let tooBig = await DigiStreamEngine.sync(source: source, destination: fullTarget,
            archiveChanged: true, archiveRemoved: true, filter: BackupFilter(), control: BackupControl(),
            availableSpace: { _ in 1 }, report: { _ in })
        let fullItems = try fm.contentsOfDirectory(atPath: fullTarget.path)
        try require(tooBig.errorCount == 1 && tooBig.status.contains("Not enough space") && fullItems.isEmpty, "Space check did not stop a backup that cannot fit: " + tooBig.status)
        let unknownSpace = await DigiStreamEngine.sync(source: source, destination: fullTarget,
            archiveChanged: true, archiveRemoved: true, filter: BackupFilter(), control: BackupControl(),
            availableSpace: { _ in nil }, report: { _ in })
        try require(unknownSpace.errorCount == 0, "Unknown free space blocked a backup: " + unknownSpace.status)
        let incrementalOnFull = await DigiStreamEngine.sync(source: source, destination: fullTarget,
            archiveChanged: true, archiveRemoved: true, filter: BackupFilter(), control: BackupControl(),
            availableSpace: { _ in 0 }, report: { _ in })
        try require(incrementalOnFull.errorCount == 0 && incrementalOnFull.completedFiles == 0, "An up-to-date backup was refused on a full drive")

        // Version 16: speed history folding keeps long runs small.
        let folded: [Double] = DigiFastBackupEngine.foldSamples([1, 3, 5, 7, 9])
        try require(folded == [2, 6, 9], "Speed sample folding is wrong")

        // Version 16: drive connection parsing, using Jeff's exact output from
        // 2026-11-01, plus a fuller tree with a hub and a USB 2 fallback.
        let jeffReport = """
                PSSD T7:
                  Speed: Up to 10 Gb/s
                    PSSD T7:
                          Mount Point: /Volumes/WolkPhoto2TB
                CT4000X9PROSSD9:
                  Speed: Up to 10 Gb/s
                    CT4000X9PROSSD9:
                          Mount Point: /Volumes/wolkphoto4TB
        """
        let jeffLinks = DigiDriveCheck.parseUSBReport(jeffReport)
        let t7Link = jeffLinks["/Volumes/WolkPhoto2TB"]
        let x9Link = jeffLinks["/Volumes/wolkphoto4TB"]
        try require(t7Link?.speed == "Up to 10 Gb/s", "T7 link speed not parsed")
        try require(t7Link?.device == "PSSD T7", "T7 device name not parsed")
        try require(x9Link?.speed == "Up to 10 Gb/s", "X9 Pro link speed not parsed")
        try require(x9Link?.device == "CT4000X9PROSSD9", "X9 Pro device name not parsed")
        let fullReport = """
        USB:

            USB 3.1 Bus:

              Host Controller Driver: AppleT8122USBXHCI

                USB3 Gen2 Hub:

                  Product ID: 0x0626
                  Speed: Up to 10 Gb/s
                  Manufacturer: Example

                    PSSD T7:

                      Product ID: 0x4001
                      Serial Number: S5TEST
                      Speed: Up to 480 Mb/s
                      Manufacturer: Samsung
                      Media:

                        PSSD T7:

                          Capacity: 2 TB (2,000,398,934,016 bytes)
                          S.M.A.R.T. status: Verified
                          Volumes:

                            EFI:

                              File System: MS-DOS FAT32
                              BSD Name: disk6s1

                            WolkPhoto2TB:

                              BSD Name: disk6s2
                              Free: 1.4 TB (1,400,000,000,000 bytes)
                              File System: Journaled HFS+
                              Mount Point: /Volumes/WolkPhoto2TB

                  Dock Volume:

                      Mount Point: /Volumes/Dock Card
        """
        let fullLinks = DigiDriveCheck.parseUSBReport(fullReport)
        try require(fullLinks["/Volumes/WolkPhoto2TB"]?.speed == "Up to 480 Mb/s", "Device speed under a hub was not used")
        try require(fullLinks["/Volumes/Dock Card"]?.speed == "Up to 10 Gb/s", "Hub speed fallback failed")
        try require(fullLinks.count == 2, "Unexpected mount points parsed")
        let byDisk = DigiDriveCheck.parseUSBBSDNames(fullReport)
        try require(byDisk["disk6s2"]?.speed == "Up to 480 Mb/s", "APFS physical store lookup failed")
        try require(DigiDriveCheck.wholeDisk("disk6s2") == "disk6", "Whole-disk name is wrong")
        try require(DigiDriveCheck.wholeDisk("disk12") == "disk12", "Whole-disk name changed a whole disk")
        let tenGig: Double? = DigiDriveCheck.megabits("Up to 10 Gb/s")
        let usb2Speed: Double? = DigiDriveCheck.megabits("Up to 480 Mb/s")
        let fiveGig: Double? = DigiDriveCheck.megabits("Up to 5 Gb/s")
        try require(tenGig == 10_000, "10 Gb/s conversion failed")
        try require(usb2Speed == 480, "480 Mb/s conversion failed")
        try require(fiveGig == 5_000, "5 Gb/s conversion failed")
        try require(DigiDriveCheck.megabits("Unknown") == nil, "Unknown link speed was guessed")
        var fast = DigiDriveStatus(destinationPath: "/Volumes/WolkPhoto2TB/Session")
        fast.linkMbps = 10_000; fast.availableBytes = 1_400; fast.totalBytes = 2_000
        try require(fast.warnings.isEmpty, "Healthy drive produced a warning")
        try require(!fast.isSlowLink, "Healthy drive flagged as slow")
        try require(fast.linkLabel == "10 Gb/s", "10 Gb/s label is wrong")
        var degraded = fast
        degraded.linkMbps = 5_000; degraded.availableBytes = 100
        let degradedWarning: String = degraded.linkWarning ?? ""
        try require(degraded.isSlowLink, "5 Gb/s link not flagged as slow")
        try require(degradedWarning.contains("5 Gb/s"), "5 Gb/s warning text is wrong")
        try require(degraded.spaceWarning != nil, "Low space was not flagged")
        var usb2 = fast
        usb2.linkMbps = 480
        let usb2Warning: String = usb2.linkWarning ?? ""
        try require(usb2Warning.contains("USB 2"), "USB 2 fallback was not flagged")
        try require(usb2.linkLabel == "480 Mb/s", "480 Mb/s label is wrong")
        let unreported = DigiDriveStatus(destinationPath: "/Volumes/Thunder")
        try require(!unreported.isSlowLink && unreported.warnings.isEmpty, "A drive without a reported link was flagged")
        let localStatus = DigiDriveCheck.inspect(fixture, usbReport: nil)
        try require(localStatus.availableBytes != nil && localStatus.linkMbps == nil, "Local drive inspection failed")

        print("PASS (Digi Stream): copies, metadata incrementals, archives, exclusions, source changes, stop/pause, path safety and coalesced progress")
        print("PASS (v16): per-destination stop/pause, free-space preflight, speed history, drive link parsing and warnings")
        try await StreamEngineSmokeTests.run()
        try FolderPlanSmokeTests.run()
    }
}
