import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Digi Stream copy engine (version 17).
//
// Written fresh for Digi Suite. It replaces how file contents are copied and
// scheduled. Planning, the manifest file and the archive layout are shared
// with the classic engine, so a destination can switch engines and stay
// incremental.
//
// How it copies:
// - Large files (8 MiB and up, mostly RAW) go one at a time. Each is read in
//   16 MiB chunks and written with the macOS write cache bypassed (F_NOCACHE),
//   into space reserved up front (F_PREALLOCATE). The goal is a steady stream
//   to the drive instead of the cache filling and then flushing in bursts.
// - Small files (Capture One settings, previews, databases) go four at a time
//   through macOS copyfile, alongside the large-file stream, so thousands of
//   tiny files never hold up the RAW copies.
// - Every file is written to a temporary name, checked, then moved into place,
//   exactly like the classic engine. Stop and Pause also work in the middle of
//   a large file.
// - Progress counts bytes as they are written, so the speed graph is accurate
//   even for very large files.
enum DigiStreamEngine {
    static let displayName = "Digi Stream"
    static let largeFileThreshold: Int64 = 8 * 1024 * 1024
    static let chunkSize = 16 * 1024 * 1024
    static let smallLaneWidth = 4

    // MARK: Small helpers

    final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var total: Int64 = 0
        func add(_ amount: Int64) { lock.lock(); total += amount; lock.unlock() }
        var value: Int64 { lock.lock(); defer { lock.unlock() }; return total }
    }

    enum Lane: Sendable { case large, small }

    struct Staged: Sendable {
        let entry: BackupEntry
        let temporary: URL
        let lane: Lane
        let seconds: Double
        /// v1.25: xxHash64 of the source, already compared with the copy read back.
        var checksum: UInt64? = nil
        /// v1.26: large files are read back in their own step while the next file copies.
        var needsReadBack = false
        var attempt = 0
    }

    /// v1.25: the copy read back from the drive didn't match the source.
    struct ChecksumMismatch: Error, LocalizedError {
        let relative: String
        var errorDescription: String? {
            "Checksum mismatch: the copy of " + relative + " didn't match the original, even after copying it again. The bad copy was discarded. Check the drive and cable, then run the backup again."
        }
    }

    enum LaneResult: Sendable {
        case staged(Staged)
        /// v1.26: a large file's read-back finished; true when it matched.
        case checked(Staged, Bool)
        case tick
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "DigiSuiteStream", code: 17, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func posixFailure(_ action: String, _ path: String) -> NSError {
        let code: Int32 = errno
        let reason = String(cString: strerror(code))
        return failure(action + " " + path + ": " + reason)
    }

    /// Runs blocking file work on a GCD thread so Swift's cooperative thread
    /// pool is never tied up by disk writes.
    static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value = try work()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocks while paused; throws when stopped. Safe to call off the main thread.
    static func waitIfPaused(_ control: BackupControl) throws {
        while control.isPaused && !control.isStopped {
            Thread.sleep(forTimeInterval: 0.15)
        }
        if control.isStopped { throw CancellationError() }
    }

    // MARK: Copy primitives

    /// Reserves the whole file's space before writing. Contiguous first; if the
    /// drive cannot give one piece, any space. Failure is harmless.
    static func preallocate(_ descriptor: Int32, size: Int64) {
        #if canImport(Darwin)
        let contiguous: UInt32 = UInt32(F_ALLOCATECONTIG) | UInt32(F_ALLOCATEALL)
        var store = fstore_t(fst_flags: contiguous, fst_posmode: F_PEOFPOSMODE,
                             fst_offset: 0, fst_length: off_t(size), fst_bytesalloc: 0)
        if fcntl(descriptor, F_PREALLOCATE, &store) == -1 {
            store.fst_flags = UInt32(F_ALLOCATEALL)
            _ = fcntl(descriptor, F_PREALLOCATE, &store)
        }
        #endif
    }

    /// Copies Finder info, extended attributes, ACLs, permissions, flags and
    /// dates from source to target, without touching the file contents.
    static func copyMetadata(source: URL, target: URL) throws {
        #if canImport(Darwin)
        let flags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR)
        if copyfile(source.path, target.path, nil, flags) != 0 {
            throw posixFailure("Could not copy file information to", target.path)
        }
        #endif
    }

    /// Large-file copy: 16 MiB chunks, write cache bypassed, space preallocated.
    /// Checks Pause and Stop between chunks.
    @discardableResult
    static func copyLarge(source: URL, target: URL, expectedSize: Int64,
                          control: BackupControl, written: ByteCounter, verify: Bool = false,
                          readBack: Bool = true) throws -> UInt64? {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw posixFailure("Could not open", source.path) }
        defer { close(input) }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard output >= 0 else { throw posixFailure("Could not create", target.path) }
        var outputOpen = true
        defer { if outputOpen { close(output) } }
        #if canImport(Darwin)
        _ = fcntl(input, F_RDAHEAD, 1)
        _ = fcntl(output, F_NOCACHE, 1)
        #endif
        if expectedSize > 0 { preallocate(output, size: expectedSize) }

        var allocated: UnsafeMutableRawPointer?
        guard posix_memalign(&allocated, 16_384, chunkSize) == 0, let buffer = allocated else {
            throw failure("Could not allocate a copy buffer")
        }
        defer { free(buffer) }

        var total: Int64 = 0
        var hasher = XXHash64()
        while true {
            try waitIfPaused(control)
            let count: Int = read(input, buffer, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixFailure("Could not read", source.path)
            }
            if count == 0 { break }
            // v1.25: the source is hashed from the same bytes that get written.
            if verify { hasher.update(UnsafeRawPointer(buffer), count: count) }
            var offset = 0
            while offset < count {
                let wrote: Int = write(output, buffer + offset, count - offset)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw posixFailure("Could not write", target.path)
                }
                offset += wrote
            }
            total += Int64(count)
            written.add(Int64(count))
        }
        guard total == expectedSize else {
            throw failure("Source size changed while copying: " + source.path)
        }
        outputOpen = false
        if close(output) != 0 { throw posixFailure("Could not finish writing", target.path) }
        try copyMetadata(source: source, target: target)
        guard verify else { return nil }
        let expected = hasher.finish()
        guard readBack else { return expected }
        // Read the new copy back from the drive and compare.
        let copied = try DigiChecksum.hashFile(target, uncached: true, control: control)
        guard copied == expected else { throw ChecksumMismatch(relative: source.lastPathComponent) }
        return expected
    }

    /// Small-file copy through macOS copyfile (contents and all file information).
    @discardableResult
    static func copySmall(source: URL, target: URL, verify: Bool = false, readBack: Bool = true,
                          control: BackupControl? = nil) throws -> UInt64? {
        #if canImport(Darwin)
        let flags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA | COPYFILE_EXCL)
        if copyfile(source.path, target.path, nil, flags) != 0 {
            throw posixFailure("Could not copy", source.path)
        }
        #else
        try FileManager().copyItem(at: source, to: target)
        #endif
        guard verify else { return nil }
        let expected = try DigiChecksum.hashFile(source, uncached: false, control: control)
        guard readBack else { return expected }
        let copied = try DigiChecksum.hashFile(target, uncached: true, control: control)
        guard copied == expected else { throw ChecksumMismatch(relative: source.lastPathComponent) }
        return expected
    }

    // MARK: Destination safety (same rules as the classic engine)

    static func deviceNumber(_ folder: URL) throws -> NSNumber {
        guard let number = try FileManager.default.attributesOfItem(atPath: folder.path)[.systemNumber] as? NSNumber else {
            throw failure("Cannot inspect destination filesystem: " + folder.path)
        }
        return number
    }

    static func checkDirectory(_ folder: URL, device expected: NSNumber) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
        let sameDevice = (attributes[.systemNumber] as? NSNumber) == expected
        guard isDirectory && sameDevice else {
            throw failure("Destination directory changed, is a symbolic link, or is Unavailable: " + folder.path)
        }
    }

    /// Creates each missing folder one level at a time and never recreates the
    /// destination root or a missing /Volumes mount.
    static func ensureDirectory(_ relative: String, under root: URL, device expected: NSNumber) throws {
        try DigiFastBackupEngine.validateRelative(relative)
        var parent = root
        for component in relative.split(separator: "/") {
            try checkDirectory(parent, device: expected)
            let next = parent.appendingPathComponent(String(component), isDirectory: true)
            if !FileManager.default.fileExists(atPath: next.path) {
                try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
            }
            try checkDirectory(next, device: expected)
            parent = next
        }
    }

    static func checkSourceUnchanged(_ entry: BackupEntry) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: entry.source.path)
        let isFile = attributes[.type] as? FileAttributeType == .typeRegular
        let sameSize = (attributes[.size] as? NSNumber)?.int64Value == entry.size
        let sameDate = attributes[.modificationDate] as? Date == entry.modified
        guard isFile && sameSize && sameDate else {
            throw failure("Source changed during backup: " + entry.relative + ". Run the next incremental backup after it finishes writing.")
        }
    }

    // MARK: Renamed files (v1.27)

    /// A file that left the session and one that arrived with the same size,
    /// date and file type, confirmed to have the same contents.
    struct RenameMatch: Sendable {
        let from: String
        let to: BackupEntry
        let checksum: UInt64
    }

    /// Contents are always compared: the original's xxHash64 against the backup
    /// copy's recorded checksum, or against the backup copy itself when none is on record.
    static func findRenames(changes: [BackupEntry], removed: [String], root: URL,
                            recorded: [String: String], control: BackupControl) throws -> [RenameMatch] {
        let fm = FileManager()
        var bySize: [Int64: [(relative: String, modified: Date)]] = [:]
        for relative in removed {
            let url = root.appendingPathComponent(relative)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  let modified = attributes[.modificationDate] as? Date else { continue }
            bySize[size, default: []].append((relative: relative, modified: modified))
        }
        guard !bySize.isEmpty else { return [] }
        var used = Set<String>()
        var matches: [RenameMatch] = []
        for entry in changes {
            try control.checkStopped()
            guard let candidates = bySize[entry.size], !fm.fileExists(atPath: entry.destination.path) else { continue }
            let kind = (entry.relative as NSString).pathExtension.lowercased()
            var original: UInt64?
            for candidate in candidates where !used.contains(candidate.relative) {
                guard abs(candidate.modified.timeIntervalSince(entry.modified)) < 2,
                      (candidate.relative as NSString).pathExtension.lowercased() == kind else { continue }
                let sourceHash: UInt64 = try original ?? DigiChecksum.hashFile(entry.source, uncached: false, control: control)
                original = sourceHash
                var backupHash: UInt64?
                if let text = recorded[candidate.relative] { backupHash = UInt64(text, radix: 16) }
                if backupHash == nil {
                    backupHash = try DigiChecksum.hashFile(root.appendingPathComponent(candidate.relative), uncached: true, control: control)
                }
                if backupHash == sourceHash {
                    used.insert(candidate.relative)
                    matches.append(RenameMatch(from: candidate.relative, to: entry, checksum: sourceHash))
                    break
                }
            }
        }
        return matches
    }

    // MARK: Backup

    static func sync(source: URL, destination: URL, archiveChanged: Bool, archiveRemoved: Bool,
                     filter: BackupFilter, snapshot supplied: DigiSyncSourceSnapshot? = nil,
                     control: BackupControl,
                     verify: Bool = false,
                     readBack: Bool = true,
                     gate: DigiCaptureGate? = nil,
                     availableSpace: @escaping @Sendable (URL) -> Int64? = { DigiFastBackupEngine.availableBytes($0) },
                     report: @escaping @Sendable (SyncProgress) async -> Void) async -> SyncProgress {
        let fm = FileManager.default
        let started = Date()
        var state = SyncProgress(destination: destination.path, status: "Checking new and changed files…")
        state.verifyOn = verify
        state.readBackOn = verify && readBack
        // v1.26 read large files back while the next one copied. Measured on the T7
        // that was no faster (14:30 vs 15:32), so 1.27 copies everything first and
        // reads it all back in one pass (postVerify). The overlap code stays, off.
        let pipelineReadBack: Bool = false
        let postVerify: Bool = verify && readBack
        var verifying = false
        let checkedBytes = ByteCounter()
        var copiedChecks: [(String, UInt64)] = []
        var archivedCount = 0
        var renamedPaths: Set<String> = []
        // v1.25: checksums of files verified this run, for the report.
        var verified: [(String, UInt64)] = []
        var removedThisRun: [String] = []
        var reportRoot: URL?
        var reportDevice: NSNumber?
        var reportKeys: Set<String> = []
        let inFlight = ByteCounter()
        var committedBytes: Int64 = 0
        var lastUpdate = Date.distantPast
        var liveStart = Date()
        var liveBytes: Int64 = 0
        var sampleStart = Date()
        var sampleBytes: Int64 = 0
        var copying = false
        // Version 18.3: time spent paused is left out of average speed and ETA.
        var pausedSeconds: Double = 0

        func publish(force: Bool = false) async {
            let now = Date()
            guard force || now.timeIntervalSince(lastUpdate) >= DigiFastBackupEngine.updateInterval else { return }
            let copiedNow: Int64 = committedBytes + (copying ? inFlight.value : 0)
            let checkedNow: Int64 = checkedBytes.value
            state.completedBytes = copiedNow
            state.verifiedBytes = checkedNow
            state.elapsedSeconds = now.timeIntervalSince(started)
            let activeSeconds: Double = state.elapsedSeconds - state.planSeconds - pausedSeconds
            let transferElapsed: Double = max(0.001, activeSeconds)
            // Copy speed stays the copy speed; the read-back pass doesn't change it.
            if !verifying { state.bytesPerSecond = Double(copiedNow) / transferElapsed }
            // v1.27: time left covers the read-back pass too (copy + read = the work).
            let workTotal: Int64 = postVerify ? state.totalBytes * 2 : state.totalBytes
            let workDone: Int64 = copiedNow + checkedNow
            let workRate: Double = Double(workDone) / transferElapsed
            if workRate > 0 {
                let remaining: Int64 = max(Int64(0), workTotal - workDone)
                state.eta = Double(remaining) / workRate
            } else {
                state.eta = nil
            }
            let transferred: Int64 = verifying ? checkedNow : copiedNow
            if copying || verifying {
                let liveSpan: Double = now.timeIntervalSince(liveStart)
                if liveSpan >= 3 {
                    state.liveMBps = Double(transferred - liveBytes) / liveSpan / 1_000_000
                    liveStart = now
                    liveBytes = transferred
                }
                let sampleSpan: Double = now.timeIntervalSince(sampleStart)
                if sampleSpan >= state.sampleSeconds {
                    let mbps: Double = Double(transferred - sampleBytes) / sampleSpan / 1_000_000
                    state.speedSamples.append(mbps)
                    state.peakMBps = max(state.peakMBps, mbps)
                    sampleStart = now
                    sampleBytes = transferred
                    if state.speedSamples.count >= DigiFastBackupEngine.maxSpeedSamples {
                        state.speedSamples = DigiFastBackupEngine.foldSamples(state.speedSamples)
                        state.sampleSeconds *= 2
                        if let start = state.readSampleStart { state.readSampleStart = start / 2 }
                    }
                }
            }
            let reportStarted = Date()
            await report(state)
            state.reportSeconds += Date().timeIntervalSince(reportStarted)
            lastUpdate = Date()
        }

        /// Waits while paused and keeps the screen honest: "Pausing…" while a
        /// copy is still writing, then "Paused" once nothing is being written.
        func pauseIfNeeded() async throws {
            guard control.isPaused && !control.isStopped else {
                try await control.checkpoint()
                return
            }
            let pauseStarted = Date()
            let resumeStatus: String = state.status
            var lastWritten: Int64 = inFlight.value
            state.status = "Pausing…"
            await publish(force: true)
            while control.isPaused && !control.isStopped {
                try await Task.sleep(nanoseconds: 250_000_000)
                let written: Int64 = inFlight.value
                state.liveMBps = 0
                if written == lastWritten && state.status != "Paused" {
                    state.status = "Paused"
                    await publish(force: true)
                } else {
                    await publish()
                }
                lastWritten = written
            }
            pausedSeconds += Date().timeIntervalSince(pauseStarted)
            state.status = resumeStatus
            try await control.checkpoint()
        }

        await publish(force: true)
        // Stops in-flight copies quickly if another file fails.
        let abort = BackupControl(parent: control)
        var temporaries = Set<URL>()
        var largeCount = 0, smallCount = 0
        var largeBytes: Int64 = 0, smallBytes: Int64 = 0
        var largeSeconds: Double = 0
        var copyStarted = Date()

        do {
            try await control.checkpoint()
            let planStarted = Date()
            let inventory = try supplied ?? DigiFastBackupEngine.snapshot(source, filter: filter, control: control)
            let plan = try DigiFastBackupEngine.plan(source: source, destination: destination, filter: filter,
                                                     snapshot: inventory, control: control)
            let root = destination.resolvingSymlinksInPath().standardizedFileURL
            let expectedDevice = try deviceNumber(root)
            reportRoot = root
            reportDevice = expectedDevice

            // v1.27: files renamed in the session are renamed on the backup instead of
            // copied again (only when removed files are archived; otherwise the old
            // name is meant to stay on the drive).
            var changes: [BackupEntry] = plan.changes
            var renames: [RenameMatch] = []
            if archiveRemoved && !plan.removed.isEmpty && !plan.changes.isEmpty {
                let listURL = root.appendingPathComponent(DigiFastBackupEngine.reportsName)
                    .appendingPathComponent(DigiBackupReport.checksumFileName)
                let recorded = DigiBackupReport.readChecksums(listURL)
                let pending = plan.changes
                let gone = plan.removed
                let renameControl = control
                state.status = "Looking for renamed files…"
                await publish(force: true)
                renames = try await runBlocking {
                    try findRenames(changes: pending, removed: gone, root: root, recorded: recorded, control: renameControl)
                }
                if !renames.isEmpty {
                    let moved = Set(renames.map { $0.to.relative })
                    changes = plan.changes.filter { !moved.contains($0.relative) }
                }
            }

            // Refuse to start if the planned copies cannot fit.
            var neededBytes: Int64 = 0
            var largestReplacement: Int64 = 0
            for change in changes {
                let existing = (try? fm.attributesOfItem(atPath: change.destination.path))?[.size] as? NSNumber
                if !archiveChanged, let existing {
                    neededBytes += max(Int64(0), change.size - existing.int64Value)
                    largestReplacement = max(largestReplacement, change.size)
                } else {
                    neededBytes += change.size
                }
            }
            neededBytes += largestReplacement
            if neededBytes > 0, let free = availableSpace(root), neededBytes > free {
                let needed = ByteCountFormatter.string(fromByteCount: neededBytes, countStyle: .file)
                let available = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                throw failure("Not enough space on this drive: this backup needs " + needed + " but only " + available + " is free. No files were copied.")
            }

            for directory in inventory.directories {
                try await control.checkpoint()
                try ensureDirectory(directory, under: root, device: expectedDevice)
            }
            // v1.27: carry out the renames (the folders exist now).
            for match in renames {
                try await control.checkpoint()
                let old = root.appendingPathComponent(match.from)
                try checkDirectory(old.deletingLastPathComponent(), device: expectedDevice)
                try checkDirectory(match.to.destination.deletingLastPathComponent(), device: expectedDevice)
                guard !fm.fileExists(atPath: match.to.destination.path) else {
                    throw failure("A file appeared where a renamed file was going: " + match.to.relative + ". Run the backup again.")
                }
                try fm.moveItem(at: old, to: match.to.destination)
                verified.append((match.to.relative, match.checksum))
                removedThisRun.append(match.from)
                renamedPaths.insert(match.to.relative)
                state.renamedFiles += 1
            }
            state.planSeconds = Date().timeIntervalSince(planStarted)
            state.totalFiles = changes.count
            state.totalBytes = changes.reduce(Int64(0)) { $0 + $1.size }
            state.unchangedFiles = plan.unchanged
            state.status = changes.isEmpty ? "No new or changed files" : "Copying new and changed files"
            await publish(force: true)

            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + String(UUID().uuidString.prefix(8))
            let archivePrefix = DigiFastBackupEngine.archiveName + "/" + stamp
            var current = plan.manifest
            let keys = Set(inventory.files.map(\.relative))
            reportKeys = keys
            current.files = current.files.filter { !filter.includes($0.key) || keys.contains($0.key) }
            for relative in keys { current.files[relative] = "size-date-match" }

            let large: [BackupEntry] = changes.filter { $0.size >= largeFileThreshold }
            let small: [BackupEntry] = changes.filter { $0.size < largeFileThreshold }

            func commit(_ staged: Staged) throws {
                let entry = staged.entry
                let temporary = staged.temporary
                try checkSourceUnchanged(entry)
                let copied = try fm.attributesOfItem(atPath: temporary.path)
                let copiedIsFile = copied[.type] as? FileAttributeType == .typeRegular
                let copiedSize = (copied[.size] as? NSNumber)?.int64Value
                guard copiedIsFile && copiedSize == entry.size else {
                    throw failure("Copied size differs from the source: " + entry.relative)
                }
                try checkDirectory(entry.destination.deletingLastPathComponent(), device: expectedDevice)
                let finalizeStarted = Date()
                try fm.setAttributes([.modificationDate: entry.modified], ofItemAtPath: temporary.path)
                if fm.fileExists(atPath: entry.destination.path) {
                    if archiveChanged {
                        let relative = archivePrefix + "/Replaced/" + entry.relative
                        let parent = (relative as NSString).deletingLastPathComponent
                        try ensureDirectory(parent, under: root, device: expectedDevice)
                        let archived = root.appendingPathComponent(relative)
                        try fm.moveItem(at: entry.destination, to: archived)
                        archivedCount += 1
                        do {
                            try fm.moveItem(at: temporary, to: entry.destination)
                        } catch {
                            do { try fm.moveItem(at: archived, to: entry.destination) }
                            catch { throw failure("Could not restore the previous file; it remains at " + archived.path) }
                            throw error
                        }
                    } else {
                        _ = try fm.replaceItemAt(entry.destination, withItemAt: temporary,
                                                 backupItemName: nil, options: .usingNewMetadataOnly)
                    }
                } else {
                    try fm.moveItem(at: temporary, to: entry.destination)
                }
                state.finalizeSeconds += Date().timeIntervalSince(finalizeStarted)
                temporaries.remove(temporary)
                current.files[entry.relative] = "copied-size-date"
                if let checksum = staged.checksum {
                    verified.append((entry.relative, checksum))
                    copiedChecks.append((entry.relative, checksum))
                    state.checksummedFiles += 1
                    // Copies checked as they were written (overlap path) count as verified.
                    if staged.needsReadBack || (readBack && !postVerify) { state.verifiedFiles += 1 }
                }
                state.completedFiles += 1
                committedBytes += entry.size
                // Bytes for this file move from "in flight" to "committed".
                inFlight.add(-entry.size)
                if staged.lane == .large {
                    largeCount += 1; largeBytes += entry.size; largeSeconds += staged.seconds
                } else {
                    smallCount += 1; smallBytes += entry.size
                }
            }

            copyStarted = Date()
            liveStart = copyStarted; liveBytes = 0
            sampleStart = copyStarted; sampleBytes = 0
            copying = !changes.isEmpty

            if copying {
                try await withThrowingTaskGroup(of: LaneResult.self) { group in
                    var nextLarge = 0, nextSmall = 0
                    var largeActive = 0, smallActive = 0
                    var tickActive = false

                    func admit(_ entry: BackupEntry, lane: Lane, attempt: Int = 0) {
                        let temporary = entry.destination.deletingLastPathComponent()
                            .appendingPathComponent(".shootwrap-" + UUID().uuidString + ".tmp")
                        temporaries.insert(temporary)
                        state.status = "Copying " + entry.relative
                        let laneControl = abort
                        let counter = inFlight
                        let device = expectedDevice
                        let laneGate = gate
                        group.addTask(priority: .userInitiated) {
                            try checkDirectory(entry.destination.deletingLastPathComponent(), device: device)
                            try checkSourceUnchanged(entry)
                            if let attributes = try? FileManager().attributesOfItem(atPath: entry.destination.path),
                               attributes[.type] as? FileAttributeType != .typeRegular {
                                throw failure("A directory or symbolic link blocks the destination: " + entry.relative)
                            }
                            let copyBegan = Date()
                            let checksum: UInt64? = try await runBlocking { () throws -> UInt64? in
                                try waitIfPaused(laneControl)
                                func copyOnce() throws -> UInt64? {
                                    if lane == .large {
                                        // With read-back on, large files are checked in their own step (below).
                                        return try copyLarge(source: entry.source, target: temporary, expectedSize: entry.size,
                                                             control: laneControl, written: counter, verify: verify,
                                                             readBack: false)
                                    }
                                    // v1.27: Full verify reads small files back in the pass after copying too.
                                    let value = try copySmall(source: entry.source, target: temporary, verify: verify,
                                                              readBack: false, control: laneControl)
                                    counter.add(entry.size)
                                    return value
                                }
                                // v1.25: a bad read-back gets one fresh copy before it counts as a failure.
                                var attempt = 0
                                while true {
                                    do {
                                        if let laneGate {
                                            return try laneGate.withPolicy { try copyOnce() }
                                        }
                                        return try copyOnce()
                                    } catch is ChecksumMismatch where attempt == 0 {
                                        attempt += 1
                                        try? FileManager().removeItem(at: temporary)
                                        if lane == .large { counter.add(-entry.size) }
                                    } catch is ChecksumMismatch {
                                        throw ChecksumMismatch(relative: entry.relative)
                                    }
                                }
                            }
                            let seconds = Date().timeIntervalSince(copyBegan)
                            var staged = Staged(entry: entry, temporary: temporary, lane: lane, seconds: seconds, checksum: checksum)
                            staged.needsReadBack = lane == .large && pipelineReadBack
                            staged.attempt = attempt
                            return .staged(staged)
                        }
                    }

                    /// v1.26: reads a finished large copy back from the drive while the
                    /// next large file is already copying.
                    var checkActive = 0
                    var waitingChecks: [Staged] = []
                    func startCheck(_ staged: Staged) {
                        checkActive += 1
                        let laneControl = abort
                        let laneGate = gate
                        group.addTask(priority: .userInitiated) {
                            let matched: Bool = try await runBlocking { () throws -> Bool in
                                func readOnce() throws -> Bool {
                                    let copied = try DigiChecksum.hashFile(staged.temporary, uncached: true, control: laneControl)
                                    return copied == staged.checksum
                                }
                                if let laneGate { return try laneGate.withPolicy { try readOnce() } }
                                return try readOnce()
                            }
                            return .checked(staged, matched)
                        }
                    }

                    func addTick() {
                        tickActive = true
                        group.addTask {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            return .tick
                        }
                    }

                    do {
                        while true {
                            try await pauseIfNeeded()
                            // Copies run at most two files ahead of the read-backs.
                            while largeActive < 1 && nextLarge < large.count && waitingChecks.count < 2 {
                                admit(large[nextLarge], lane: .large)
                                nextLarge += 1; largeActive += 1
                            }
                            if checkActive == 0, !waitingChecks.isEmpty {
                                startCheck(waitingChecks.removeFirst())
                            }
                            while smallActive < smallLaneWidth && nextSmall < small.count {
                                admit(small[nextSmall], lane: .small)
                                nextSmall += 1; smallActive += 1
                            }
                            if largeActive + smallActive + checkActive == 0 && waitingChecks.isEmpty { break }
                            if !tickActive { addTick() }
                            await publish()
                            let waitStarted = Date()
                            guard let result = try await group.next() else {
                                throw failure("The copy queue ended before completion")
                            }
                            state.copySeconds += Date().timeIntervalSince(waitStarted)
                            switch result {
                            case .tick:
                                tickActive = false
                            case .staged(let staged):
                                if staged.lane == .large { largeActive -= 1 } else { smallActive -= 1 }
                                if staged.needsReadBack {
                                    // Read back later; the next large copy can start now.
                                    if checkActive == 0 { startCheck(staged) } else { waitingChecks.append(staged) }
                                    continue
                                }
                                // Never commit a finished copy after Stop.
                                try await pauseIfNeeded()
                                try commit(staged)
                                await publish()
                            case .checked(let staged, let matched):
                                checkActive -= 1
                                if matched {
                                    try await pauseIfNeeded()
                                    try commit(staged)
                                    await publish()
                                } else if staged.attempt == 0 {
                                    // One fresh copy before it counts as a failure.
                                    try? fm.removeItem(at: staged.temporary)
                                    temporaries.remove(staged.temporary)
                                    inFlight.add(-staged.entry.size)
                                    admit(staged.entry, lane: .large, attempt: 1)
                                    largeActive += 1
                                } else {
                                    throw ChecksumMismatch(relative: staged.entry.relative)
                                }
                            }
                        }
                    } catch {
                        // Stop the other in-flight copies at their next chunk; the
                        // group waits for them before temporaries are removed.
                        abort.stop()
                        group.cancelAll()
                        throw error
                    }
                    group.cancelAll()
                }
            }
            copying = false

            // v1.27: Full verify. Everything is on the drive; now read every new copy
            // back and compare with the original's checksum. A copy that doesn't match
            // is copied again from the original (checked as it's written).
            func repair(_ entry: BackupEntry, expected: UInt64) async throws {
                try checkSourceUnchanged(entry)
                let temporary = entry.destination.deletingLastPathComponent()
                    .appendingPathComponent(".shootwrap-" + UUID().uuidString + ".tmp")
                temporaries.insert(temporary)
                let repairControl = abort
                let scratch = ByteCounter()
                let fresh: UInt64? = try await runBlocking { () throws -> UInt64? in
                    if entry.size >= largeFileThreshold {
                        return try copyLarge(source: entry.source, target: temporary, expectedSize: entry.size,
                                             control: repairControl, written: scratch, verify: true, readBack: true)
                    }
                    return try copySmall(source: entry.source, target: temporary, verify: true, readBack: true, control: repairControl)
                }
                guard fresh == expected else { throw ChecksumMismatch(relative: entry.relative) }
                try checkSourceUnchanged(entry)
                try checkDirectory(entry.destination.deletingLastPathComponent(), device: expectedDevice)
                try fm.setAttributes([.modificationDate: entry.modified], ofItemAtPath: temporary.path)
                _ = try fm.replaceItemAt(entry.destination, withItemAt: temporary,
                                         backupItemName: nil, options: .usingNewMetadataOnly)
                temporaries.remove(temporary)
                state.repairedFiles += 1
            }
            if postVerify && !copiedChecks.isEmpty {
                verifying = true
                state.verifyPhase = true
                state.readSampleStart = state.speedSamples.count
                let phaseStart = Date()
                liveStart = phaseStart; liveBytes = 0
                sampleStart = phaseStart; sampleBytes = 0
                var byRelative: [String: BackupEntry] = [:]
                for entry in changes { byRelative[entry.relative] = entry }
                let total: Int = copiedChecks.count
                for (index, item) in copiedChecks.enumerated() {
                    try await pauseIfNeeded()
                    let relative: String = item.0
                    let expected: UInt64 = item.1
                    let target = root.appendingPathComponent(relative)
                    state.status = "Verifying \(index + 1) of \(total): " + relative
                    await publish()
                    let readControl = abort
                    let readGate = gate
                    let counter = checkedBytes
                    var matched: Bool = try await runBlocking { () throws -> Bool in
                        func readOnce() throws -> Bool {
                            let copied = try DigiChecksum.hashFile(target, uncached: true, control: readControl, counted: counter)
                            return copied == expected
                        }
                        if let readGate { return try readGate.withPolicy { try readOnce() } }
                        return try readOnce()
                    }
                    if !matched, let entry = byRelative[relative] {
                        try await repair(entry, expected: expected)
                        matched = true
                    }
                    guard matched else { throw ChecksumMismatch(relative: relative) }
                    state.verifiedFiles += 1
                }
                verifying = false
                state.status = "Finishing…"
                await publish(force: true)
            }

            try await control.checkpoint()
            let finishStarted = Date()
            if archiveRemoved {
                for relative in plan.removed {
                    try await control.checkpoint()
                    let old = root.appendingPathComponent(relative)
                    if !fm.fileExists(atPath: old.path) { continue }
                    try checkDirectory(old.deletingLastPathComponent(), device: expectedDevice)
                    let attributes = try fm.attributesOfItem(atPath: old.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else {
                        throw failure("Cannot archive non-file: " + relative)
                    }
                    let target = archivePrefix + "/Removed from source/" + relative
                    try ensureDirectory((target as NSString).deletingLastPathComponent, under: root, device: expectedDevice)
                    try fm.moveItem(at: old, to: root.appendingPathComponent(target))
                    removedThisRun.append(relative)
                    archivedCount += 1
                }
            }
            try await control.checkpoint()
            try checkDirectory(root, device: expectedDevice)
            try JSONEncoder().encode(current).write(to: root.appendingPathComponent(DigiFastBackupEngine.manifestName), options: .atomic)
            state.finalizeSeconds += Date().timeIntervalSince(finishStarted)
            state.status = DigiFastBackupEngine.completeStatus
        } catch is CancellationError {
            state.status = "Stopped safely. Completed files retained."
        } catch {
            state.errorCount += 1
            state.status = "Error: " + error.localizedDescription
        }
        copying = false
        // The task group has drained, so no copy is still writing these.
        for temporary in temporaries { try? fm.removeItem(at: temporary) }

        // v1.25: checksum list and report on the drive, even after a stop or error,
        // so every file that was verified is on record.
        if verify, let root = reportRoot, let device = reportDevice {
            let input = DigiBackupReport.Input(
                source: source, destination: root, device: device, started: started, finished: Date(),
                status: state.status, verified: verified, removed: removedThisRun,
                unchangedFiles: state.unchangedFiles, sourceKeys: reportKeys,
                copiedBytes: committedBytes, readBack: readBack,
                readBackDone: postVerify ? state.verifiedFiles : 0, renamedPaths: renamedPaths,
                archived: archivedCount, repaired: state.repairedFiles)
            do {
                state.reportPath = try DigiBackupReport.write(input)
            } catch {
                state.engineNote = "Couldn't write the checksum report: " + error.localizedDescription
            }
        }

        if largeCount + smallCount > 0 {
            let copyWall: Double = max(0.001, Date().timeIntervalSince(copyStarted))
            let largeText: String = ByteCountFormatter.string(fromByteCount: largeBytes, countStyle: .file)
            var note: String = displayName + " · large files: \(largeCount), " + largeText
            if largeSeconds > 0 {
                let largeRate: Double = Double(largeBytes) / largeSeconds / 1_000_000
                note += String(format: " at %.0f MB/s", largeRate)
            }
            let smallText: String = ByteCountFormatter.string(fromByteCount: smallBytes, countStyle: .file)
            note += " · small files: \(smallCount), " + smallText
            note += String(format: " · copy time %.0fs", copyWall)
            if state.engineNote.isEmpty { state.engineNote = note } else { state.engineNote = note + " · " + state.engineNote }
        } else if state.engineNote.isEmpty {
            state.engineNote = displayName
        }
        await publish(force: true)
        state.completedBytes = committedBytes
        state.eta = nil
        state.elapsedSeconds = Date().timeIntervalSince(started)
        await report(state)
        return state
    }
}
