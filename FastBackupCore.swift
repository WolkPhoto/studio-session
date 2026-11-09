import Foundation

// Shared backup types and planning. Copying is done by DigiStreamEngine
// (version 18 removed the older v13 copy engine). Planning compares path, size
// and modification date; content hashing belongs to Folder Compare.
struct SyncProgress: Identifiable, Sendable {
    var id: String { destination }
    let destination: String
    var status = "Waiting"
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var completedFiles = 0
    var totalFiles = 0
    var unchangedFiles = 0
    var bytesPerSecond: Double = 0
    var eta: Double?
    var errorCount = 0
    var copySeconds: Double = 0
    var finalizeSeconds: Double = 0
    var planSeconds: Double = 0
    var validationSeconds: Double = 0
    var reportSeconds: Double = 0
    var elapsedSeconds: Double = 0
    var liveMBps: Double = 0
    // Version 16: speed history for the progress graph. Each sample is the
    // average MB/s over `sampleSeconds`; long runs are folded to stay small.
    var peakMBps: Double = 0
    var speedSamples: [Double] = []
    var sampleSeconds: Double = 1
    // Version 17: where the time went, written by the Digi Stream engine.
    var engineNote: String = ""
    // v1.25: checksums. Files copied and verified this run, and where the report went.
    var verifyOn = false
    /// v1.26: false in Quick mode (originals checksummed, copies not read back).
    var readBackOn = false
    /// v1.27: copies with a checksum of the original (counted while copying).
    var checksummedFiles = 0
    /// v1.27: Full verify reads copies back in a pass after copying.
    var verifyPhase = false
    var verifiedBytes: Int64 = 0
    /// Index in speedSamples where the read-back pass starts (drawn differently).
    var readSampleStart: Int?
    /// v1.27: renamed in the session, so renamed on the backup instead of copied.
    var renamedFiles = 0
    /// v1.27: copies that failed their check and were copied again successfully.
    var repairedFiles = 0
    /// v1.29: files still being written (size or date stamp moved mid-backup).
    /// Skipped this run, not an error; the next run catches them.
    var skippedFiles = 0
    /// v1.37: files that couldn't be backed up as they are (unreadable / lock), skipped and flagged.
    var problemFiles = 0
    /// v1.39: copies left unchecked by an earlier run (Stop, yanked drive, crash) that this
    /// run reads back first. Their bytes are extra read-back work on top of totalBytes x 2.
    var extraReadBytes: Int64 = 0
    var earlierVerified = 0
    /// v1.39: after the run, copies on this drive still waiting to be read back.
    var pendingReadBack = 0
    /// v1.39: the work the bar and time left cover (copy + read back with Full verify).
    var workBytes: Int64 { readBackOn ? totalBytes * 2 + extraReadBytes : totalBytes }
    var workDoneBytes: Int64 { readBackOn ? completedBytes + verifiedBytes : completedBytes }
    /// v1.28: how long copying took, and the read-back pass, separately.
    var copyPhaseSeconds: Double = 0
    var verifyPhaseSeconds: Double = 0
    var verifiedFiles = 0
    var reportPath = ""
    // v1.25: what the automatic archive clean-up did on this drive, if anything.
    var archiveNote = ""
}

struct BackupFilter: Codable, Sendable, Equatable {
    var excludedFolders: Set<String> = []
    var excludedExtensions: Set<String> = []
    var excludedNames: Set<String> = []
    var includeHidden = false
    init(excludedFolders: Set<String> = [], excludedExtensions: Set<String> = [], excludedNames: Set<String> = [], includeHidden: Bool = false) {
        self.excludedFolders = excludedFolders
        self.excludedExtensions = excludedExtensions
        self.excludedNames = excludedNames
        self.includeHidden = includeHidden
    }
    func includes(_ relative: String) -> Bool {
        let components = relative.split(separator: "/").map(String.init)
        if !includeHidden && components.contains(where: { $0.hasPrefix(".") }) { return false }
        if components.contains(where: { excludedNames.contains($0.lowercased()) }) { return false }
        if components.indices.contains(where: { excludedFolders.contains(components.prefix($0 + 1).joined(separator: "/")) }) { return false }
        return !excludedExtensions.contains(URL(fileURLWithPath: relative).pathExtension.lowercased())
    }
    var exclusionCount: Int { excludedFolders.count + excludedExtensions.count + excludedNames.count + (includeHidden ? 0 : 1) }
}

struct SyncRecord: Codable {
    // Same schema as older builds. Values describe copy/metadata state, not hashes.
    var files: [String: String] = [:]
    /// v1.40: the name of the folder this backup is of (older manifests don't have it;
    /// older builds ignore it).
    var sourceName: String?
}

final class BackupControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var stopped = false
    // Version 16: a destination's control can have the whole backup's control
    // as its parent. Pausing or stopping the parent affects every destination;
    // pausing or stopping a child affects only that destination.
    private let parent: BackupControl?
    init(parent: BackupControl? = nil) { self.parent = parent }
    func pause() { lock.lock(); paused = true; lock.unlock() }
    func resume() { lock.lock(); paused = false; lock.unlock() }
    func stop() { lock.lock(); stopped = true; paused = false; lock.unlock() }
    private func flags() -> (Bool, Bool) {
        lock.lock()
        let own = (paused, stopped)
        lock.unlock()
        guard let parent else { return own }
        let inherited = parent.flags()
        return (own.0 || inherited.0, own.1 || inherited.1)
    }
    var isStopped: Bool { flags().1 }
    var isPaused: Bool { flags().0 }
    func checkStopped() throws {
        try Task.checkCancellation()
        if flags().1 { throw CancellationError() }
    }
    func checkpoint() async throws {
        while true {
            try Task.checkCancellation()
            let (paused, stopped) = flags()
            if stopped { throw CancellationError() }
            if !paused { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }
}

struct DigiBackupSourceFile: Sendable {
    let relative: String
    let source: URL
    let size: Int64
    let modified: Date
}

struct BackupEntry: Sendable {
    let relative: String
    let source: URL
    let destination: URL
    let size: Int64
    let modified: Date
}

struct DigiSyncSourceSnapshot: Sendable {
    let source: URL
    let filter: BackupFilter
    let files: [DigiBackupSourceFile]
    let directories: [String]
}


enum DigiFastBackupEngine {
    static let completeStatus = "Up to date"
    static let manifestName = ".shootwrap-sync-manifest.json"

    /// v1.40: before a manual backup, does this backup folder already hold a backup of a
    /// DIFFERENT folder? Returns nil when it's fine (new or empty folder, same source),
    /// the other folder's name when it's on record, or "" when it's clearly a different
    /// folder but the name isn't known (backups made before 1.40).
    static func otherSourceName(source: URL, destination: URL) -> String? {
        let manifestURL = destination.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let record = try? JSONDecoder().decode(SyncRecord.self, from: data) else { return nil }
        let sourceName: String = source.lastPathComponent
        if let recorded = record.sourceName {
            return recorded == sourceName ? nil : recorded
        }
        let fm = FileManager.default
        let sourceTop: [String] = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
        // A Capture One session's database is named after the session.
        var backedDatabase: String?
        for key in record.files.keys where !key.contains("/") && key.hasSuffix(".cosessiondb") {
            backedDatabase = key
            break
        }
        let sourceDatabase: String? = sourceTop.first { $0.hasSuffix(".cosessiondb") }
        if let backedDatabase, let sourceDatabase {
            if backedDatabase == sourceDatabase { return nil }
            return (backedDatabase as NSString).deletingPathExtension
        }
        // Nothing in common at the top level: clearly a different folder.
        var backedTop = Set<String>()
        for key in record.files.keys {
            if let first = key.split(separator: "/").first { backedTop.insert(String(first)) }
        }
        if !backedTop.isEmpty && backedTop.isDisjoint(with: Set(sourceTop)) { return "" }
        return nil
    }
    /// v1.25: new archives go in _StudioSession_Archive. Older drives may still
    /// hold _ShootWrap_Archive; both are left out of scans and shown in the archive tools.
    static let archiveName = "_StudioSession_Archive"
    static let legacyArchiveName = "_ShootWrap_Archive"
    static let archiveNames: Set<String> = [archiveName, legacyArchiveName]
    /// v1.25: checksum lists and backup reports, on each backup drive.
    static let reportsName = "_StudioSession_Reports"
    /// Folders Studio Session keeps on a backup drive, never copied or compared.
    static let toolFolderNames: Set<String> = [archiveName, legacyArchiveName, reportsName]
    static let updateInterval: TimeInterval = 0.35

    /// Halves the resolution of a long speed history by averaging pairs.
    static func foldSamples(_ samples: [Double]) -> [Double] {
        var folded: [Double] = []
        folded.reserveCapacity(samples.count / 2 + 1)
        var index = 0
        while index < samples.count {
            if index + 1 < samples.count {
                let pair: Double = samples[index] + samples[index + 1]
                folded.append(pair / 2)
            } else {
                folded.append(samples[index])
            }
            index += 2
        }
        return folded
    }
    static let maxSpeedSamples = 600
    static func availableBytes(_ url: URL) -> Int64? {
        var best: Int64?
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity {
            best = Int64(available)
        }
        #if os(macOS)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage {
            best = max(best ?? 0, important)
        }
        #endif
        return best
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "DigiSuiteBackup", code: 11, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func availableDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return false }
        #if os(macOS)
        let parts = url.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            let mount = URL(fileURLWithPath: "/Volumes").appendingPathComponent(parts[2]).standardizedFileURL
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
            guard mounted.contains(where: { $0.standardizedFileURL == mount }) else { return false }
        }
        #endif
        return true
    }
    static func validateRelative(_ relative: String) throws {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw failure("Invalid relative backup path: " + relative)
        }
    }
    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return parent.path == child.path || child.path.hasPrefix(prefix)
    }
    static func validateLocations(source: URL, destination: URL) throws {
        guard availableDirectory(source), availableDirectory(destination) else { throw failure("Source or destination Unavailable") }
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !contains(source, destination), !contains(destination, source) else {
            throw failure("Source and destination must not contain one another")
        }
    }
    static func snapshot(_ folder: URL, filter: BackupFilter, control: BackupControl? = nil) throws -> DigiSyncSourceSnapshot {
        let source = folder.resolvingSymlinksInPath().standardizedFileURL
        guard availableDirectory(source) else { throw failure("Source Unavailable") }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var pending: [(URL, String)] = [(source, "")]
        var files: [DigiBackupSourceFile] = []
        var directories: [String] = []
        while let (directory, prefix) = pending.popLast() {
            try Task.checkCancellation()
            try control?.checkStopped()
            // Propagate traversal errors; a partial source scan is never a removal plan.
            for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: []) {
                try control?.checkStopped()
                let relative = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                if toolFolderNames.contains(child.lastPathComponent) || !filter.includes(relative) { continue }
                let values = try child.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    directories.append(relative)
                    pending.append((child, relative))
                } else if values.isRegularFile == true {
                    guard let size = values.fileSize, let modified = values.contentModificationDate else { throw failure("Could not inspect " + relative) }
                    files.append(DigiBackupSourceFile(relative: relative, source: child, size: Int64(size), modified: modified))
                } else { throw failure("Unsupported source item: " + relative) }
            }
        }
        files.sort { $0.relative < $1.relative }
        directories.sort {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a == b ? $0 < $1 : a < b
        }
        return DigiSyncSourceSnapshot(source: source, filter: filter, files: files, directories: directories)
    }
    static func plan(source: URL, destination: URL, filter: BackupFilter = BackupFilter(), snapshot supplied: DigiSyncSourceSnapshot? = nil, control: BackupControl? = nil) throws -> (changes: [BackupEntry], unchanged: Int, removed: [String], manifest: SyncRecord) {
        try validateLocations(source: source, destination: destination)
        let inventory = try supplied ?? snapshot(source, filter: filter, control: control)
        guard inventory.source == source.resolvingSymlinksInPath().standardizedFileURL, inventory.filter == filter else {
            throw failure("The source or backup filter changed. Start the backup again.")
        }
        let fm = FileManager.default
        let manifestURL = destination.appendingPathComponent(manifestName)
        let prior: SyncRecord
        if fm.fileExists(atPath: manifestURL.path) {
            prior = try JSONDecoder().decode(SyncRecord.self, from: Data(contentsOf: manifestURL))
        } else { prior = SyncRecord() }
        var changes: [BackupEntry] = []
        var unchanged = 0
        let keys = Set(inventory.files.map(\.relative))
        for file in inventory.files {
            try control?.checkStopped()
            let target = destination.appendingPathComponent(file.relative)
            // attributesOfItem is a fresh stat, not metadata cached on a reused URL.
            let attributes = try? fm.attributesOfItem(atPath: target.path)
            if attributes?[.type] as? FileAttributeType == .typeRegular,
               (attributes?[.size] as? NSNumber)?.int64Value == file.size,
               let modified = attributes?[.modificationDate] as? Date,
               abs(file.modified.timeIntervalSince(modified)) < 2 {
                unchanged += 1
            } else {
                changes.append(BackupEntry(relative: file.relative, source: file.source, destination: target, size: file.size, modified: file.modified))
            }
        }
        let removed = prior.files.keys.filter { filter.includes($0) && !keys.contains($0) }.sorted()
        for relative in removed { try validateRelative(relative) }
        return (changes, unchanged, removed, prior)
    }

}

// MARK: One backup per drive folder, across apps (v21)

/// Grip, Wrap, Proof, Tech Cart, Tally and Digi Suite can all be open at once.
/// This lock makes sure only one of them copies into a given backup folder at a
/// time, so two apps never write the same manifest or temp files together.
/// The lock file lives in ~/Library/Application Support/DigiTools/Locks, never
/// on the backup drive, and macOS releases it if an app quits or crashes.
final class DigiDestinationLock: @unchecked Sendable {
    enum Result {
        case acquired(DigiDestinationLock)
        case busy
        case unavailable
    }

    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit {
        // Closing the file releases the lock.
        close(descriptor)
    }

    static func key(for destination: URL) -> String {
        // FNV-1a over the standardized path: short, stable, filename-safe.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in destination.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    static func lockFolder() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("DigiTools/Locks", isDirectory: true)
    }

    static func acquire(_ destination: URL, folder: URL? = nil) -> Result {
        guard let base = folder ?? lockFolder() else { return .unavailable }
        do { try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) }
        catch { return .unavailable }
        let path = base.appendingPathComponent(key(for: destination) + ".lock").path
        // O_EXLOCK takes an exclusive lock as the file opens; O_NONBLOCK makes
        // a second app get EWOULDBLOCK right away instead of waiting.
        let fd = open(path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK, 0o644)
        if fd >= 0 { return .acquired(DigiDestinationLock(descriptor: fd)) }
        if errno == EWOULDBLOCK || errno == EAGAIN { return .busy }
        return .unavailable
    }

    static let busyStatus = "Skipped: another app is backing up to this folder"
}
