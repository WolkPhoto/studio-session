import Foundation

// v1.25: xxHash64, the checksum digital techs already use (Hedge, ShotPut Pro,
// Silverstack, `xxhsum`). Streaming, so a file is hashed chunk by chunk while
// it copies. Output matches `xxhsum -H1` (16 lowercase hex digits).

struct XXHash64 {
    private static let prime1: UInt64 = 0x9E3779B185EBCA87
    private static let prime2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let prime3: UInt64 = 0x165667B19E3779F9
    private static let prime4: UInt64 = 0x85EBCA77C2B2AE63
    private static let prime5: UInt64 = 0x27D4EB2F165667C5

    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64
    private let seed: UInt64
    private var totalLength: UInt64 = 0
    private var buffer = [UInt8](repeating: 0, count: 32)
    private var bufferCount = 0

    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.prime1 &+ Self.prime2
        v2 = seed &+ Self.prime2
        v3 = seed
        v4 = seed &- Self.prime1
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ input &* prime2
        a = rotl(a, 31)
        return a &* prime1
    }

    @inline(__always) private static func merge(_ acc: UInt64, _ value: UInt64) -> UInt64 {
        var a = acc ^ round(0, value)
        a = a &* prime1 &+ prime4
        return a
    }

    @inline(__always) private static func read64(_ p: UnsafeRawPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inline(__always) private static func read32(_ p: UnsafeRawPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    mutating func update(_ data: UnsafeRawPointer, count: Int) {
        guard count > 0 else { return }
        totalLength &+= UInt64(count)
        var offset = 0

        // Top up a partial 32-byte stripe from an earlier call.
        if bufferCount > 0 {
            let filled = bufferCount
            let take = min(32 - filled, count)
            var stripe = buffer
            stripe.withUnsafeMutableBytes { raw in
                raw.baseAddress!.advanced(by: filled).copyMemory(from: data, byteCount: take)
            }
            buffer = stripe
            bufferCount = filled + take
            offset += take
            if bufferCount < 32 { return }
            var lanes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
            stripe.withUnsafeBytes { raw in
                let p = raw.baseAddress!
                lanes = (Self.read64(p, 0), Self.read64(p, 8), Self.read64(p, 16), Self.read64(p, 24))
            }
            v1 = Self.round(v1, lanes.0)
            v2 = Self.round(v2, lanes.1)
            v3 = Self.round(v3, lanes.2)
            v4 = Self.round(v4, lanes.3)
            bufferCount = 0
        }

        // Whole stripes straight from the caller's memory.
        while count - offset >= 32 {
            v1 = Self.round(v1, Self.read64(data, offset))
            v2 = Self.round(v2, Self.read64(data, offset + 8))
            v3 = Self.round(v3, Self.read64(data, offset + 16))
            v4 = Self.round(v4, Self.read64(data, offset + 24))
            offset += 32
        }

        // Keep the tail for next time.
        let rest = count - offset
        if rest > 0 {
            let start = offset
            var tail = buffer
            tail.withUnsafeMutableBytes { raw in
                raw.baseAddress!.copyMemory(from: data.advanced(by: start), byteCount: rest)
            }
            buffer = tail
            bufferCount = rest
        }
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { update(base, count: raw.count) }
        }
    }

    func finish() -> UInt64 {
        var h: UInt64
        if totalLength >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.merge(h, v1)
            h = Self.merge(h, v2)
            h = Self.merge(h, v3)
            h = Self.merge(h, v4)
        } else {
            h = seed &+ Self.prime5
        }
        h &+= totalLength

        let filled = bufferCount
        buffer.withUnsafeBytes { raw in
            let p = raw.baseAddress!
            var i = 0
            while i + 8 <= filled {
                let k1 = Self.round(0, Self.read64(p, i))
                h ^= k1
                h = Self.rotl(h, 27) &* Self.prime1 &+ Self.prime4
                i += 8
            }
            if i + 4 <= filled {
                h ^= UInt64(Self.read32(p, i)) &* Self.prime1
                h = Self.rotl(h, 23) &* Self.prime2 &+ Self.prime3
                i += 4
            }
            while i < filled {
                h ^= UInt64(p.load(fromByteOffset: i, as: UInt8.self)) &* Self.prime5
                h = Self.rotl(h, 11) &* Self.prime1
                i += 1
            }
        }

        h ^= h >> 33
        h = h &* Self.prime2
        h ^= h >> 29
        h = h &* Self.prime3
        h ^= h >> 32
        return h
    }

    static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    static func hash(_ data: Data) -> UInt64 {
        var hasher = XXHash64()
        hasher.update(data)
        return hasher.finish()
    }
}

enum DigiChecksum {
    static let chunkSize = 8 * 1024 * 1024

    /// Hashes a whole file. With `uncached`, asks macOS to read it from the
    /// drive instead of memory (used when reading a fresh copy back).
    static func hashFile(_ url: URL, uncached: Bool, control: BackupControl? = nil) throws -> UInt64 {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DigiStreamEngine.posixFailure("Could not open", url.path) }
        defer { close(descriptor) }
        #if canImport(Darwin)
        if uncached { _ = fcntl(descriptor, F_NOCACHE, 1) }
        _ = fcntl(descriptor, F_RDAHEAD, 1)
        #endif
        var allocated: UnsafeMutableRawPointer?
        guard posix_memalign(&allocated, 16_384, chunkSize) == 0, let buffer = allocated else {
            throw DigiStreamEngine.failure("Could not allocate a checksum buffer")
        }
        defer { free(buffer) }
        var hasher = XXHash64()
        while true {
            if let control { try DigiStreamEngine.waitIfPaused(control) }
            let count: Int = read(descriptor, buffer, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw DigiStreamEngine.posixFailure("Could not read", url.path)
            }
            if count == 0 { break }
            hasher.update(UnsafeRawPointer(buffer), count: count)
        }
        return hasher.finish()
    }
}

/// v1.25: one decision, shared by every copy thread: is Capture One running?
/// Checked at most every two seconds, so thousands of small files don't each
/// ask macOS for the list of running apps.
final class DigiCaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCheck = Date.distantPast
    private var cached = false
    private let probe: @Sendable () -> Bool

    init(probe: @escaping @Sendable () -> Bool) { self.probe = probe }

    var captureOneBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(lastCheck) >= 2 {
            cached = probe()
            lastCheck = now
        }
        return cached
    }

    /// While Capture One is open, this thread's disk reads and writes step
    /// aside for other apps (macOS "utility" I/O priority). Back to normal after.
    func withPolicy<T>(_ work: () throws -> T) rethrows -> T {
        #if os(macOS)
        let gentle = captureOneBusy
        if gentle { _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_UTILITY) }
        defer { if gentle { _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_DEFAULT) } }
        #endif
        return try work()
    }
}

/// v1.25: what a backup leaves on the drive in _StudioSession_Reports:
/// - Checksums.xxh64: every verified file in this backup, `xxhsum -c` compatible,
///   kept up to date across incremental backups.
/// - "<date> Backup Report.txt": a plain summary of this run for producers and clients.
enum DigiBackupReport {
    struct Input: Sendable {
        let source: URL
        let destination: URL
        let device: NSNumber
        let started: Date
        let finished: Date
        let status: String
        let verified: [(String, UInt64)]
        let removed: [String]
        let unchangedFiles: Int
        let sourceKeys: Set<String>
        let copiedBytes: Int64
        /// v1.26: false in Quick mode (copies weren't read back).
        var readBack: Bool = true
    }

    /// v1.26: "Capture/LG" for "Capture/LG/Scene_1/a.ARW"; files at the top level group as one.
    static func group(for relative: String) -> String {
        let parts = relative.split(separator: "/")
        if parts.count <= 1 { return "(top level of the session)" }
        if parts.count == 2 { return String(parts[0]) }
        return String(parts[0]) + "/" + String(parts[1])
    }

    static let checksumFileName = "Checksums.xxh64"

    /// Reads an xxhsum list: "<16 hex>  <path>" per line.
    static func readChecksums(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 18 else { continue }
            let hash = String(line.prefix(16))
            let rest = line.dropFirst(16)
            guard rest.hasPrefix("  ") else { continue }
            result[String(rest.dropFirst(2))] = hash
        }
        return result
    }

    /// Writes the checksum list and the run report. Returns the report's path.
    static func write(_ input: Input) throws -> String {
        // Nothing new (a scheduled backup that found no changes): no new report.
        if input.verified.isEmpty && input.removed.isEmpty && input.status == DigiFastBackupEngine.completeStatus { return "" }
        let fm = FileManager.default
        try DigiStreamEngine.ensureDirectory(DigiFastBackupEngine.reportsName, under: input.destination, device: input.device)
        let folder = input.destination.appendingPathComponent(DigiFastBackupEngine.reportsName, isDirectory: true)

        // Cumulative list: update copied files, drop files archived as removed
        // and anything no longer in the session.
        let listURL = folder.appendingPathComponent(checksumFileName)
        var list = readChecksums(listURL)
        for (relative, hash) in input.verified { list[relative] = XXHash64.hex(hash) }
        for relative in input.removed { list[relative] = nil }
        if !input.sourceKeys.isEmpty {
            list = list.filter { input.sourceKeys.contains($0.key) }
        }
        var lines: [String] = []
        for key in list.keys.sorted() {
            if let hash = list[key] { lines.append(hash + "  " + key) }
        }
        let listText = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try Data(listText.utf8).write(to: listURL, options: .atomic)

        // This run's report.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmmss"
        let readable = DateFormatter()
        readable.dateStyle = .medium
        readable.timeStyle = .medium
        let volumeValues = try? input.destination.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey])
        let volumeName = volumeValues?.volumeName ?? input.destination.lastPathComponent
        let missing = input.sourceKeys.filter { list[$0] == nil }.count
        let complete = input.status == DigiFastBackupEngine.completeStatus
        let byteText = ByteCountFormatter.string(fromByteCount: input.copiedBytes, countStyle: .file)

        var text = "STUDIO SESSION BACKUP REPORT\n"
        text += "============================\n\n"
        let doneLine: String = input.readBack ? "COMPLETE, every copied file verified" : "COMPLETE, originals checksummed (Quick: copies not read back)"
        text += "Result:    " + (complete ? doneLine : "NOT COMPLETE: " + input.status) + "\n\n"
        text += "Session:   " + input.source.lastPathComponent + "\n"
        text += "From:      " + input.source.path + "\n"
        text += "To:        " + input.destination.path + "\n"
        text += "Drive:     " + volumeName
        if let uuid = volumeValues?.volumeUUIDString { text += "  (volume ID " + uuid + ")" }
        text += "\n"
        if let total = volumeValues?.volumeTotalCapacity {
            text += "Capacity:  " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file) + "\n"
        }
        text += "Started:   " + readable.string(from: input.started) + "\n"
        text += "Finished:  " + readable.string(from: input.finished) + "\n\n"
        text += "Copied and verified this run:  \(input.verified.count) files, " + byteText + "\n"
        text += "Already on the drive, unchanged:  \(input.unchangedFiles) files\n"
        text += "Files in this backup with a checksum on record:  \(input.sourceKeys.count - missing) of \(input.sourceKeys.count)\n"
        if missing > 0 {
            text += "  \(missing) files were copied before checksums were turned on. Check them with Compare > Deep Verify.\n"
        }
        if input.readBack {
            text += "\nHow files were checked: xxHash64. The original was hashed while it was read,\n"
            text += "the copy was read back from this drive and hashed again, and the two had to match\n"
            text += "before the copy was kept. The full list is in " + checksumFileName + " in this folder\n"
        } else {
            text += "\nHow files were checked (Quick): xxHash64 of each original, taken while it was copied.\n"
            text += "The copies were not read back; check them against " + checksumFileName + " in this folder\n"
        }
        text += "(check it any time with: cd \"" + input.destination.path + "\" && xxhsum -c \"" + DigiFastBackupEngine.reportsName + "/" + checksumFileName + "\").\n"
        // v1.26: totals per folder; every file and its checksum is in Checksums.xxh64.
        if !input.verified.isEmpty {
            var groups: [String: (files: Int, bytes: Int64)] = [:]
            for (relative, _) in input.verified {
                let key = group(for: relative)
                let size = (try? fm.attributesOfItem(atPath: input.destination.appendingPathComponent(relative).path))?[.size] as? NSNumber
                var entry: (files: Int, bytes: Int64) = groups[key] ?? (files: 0, bytes: 0)
                entry.files += 1
                entry.bytes += size?.int64Value ?? 0
                groups[key] = entry
            }
            text += "\nCOPIED THIS RUN, BY FOLDER\n"
            let ordered = groups.keys.sorted()
            for key in ordered.prefix(80) {
                if let entry = groups[key] {
                    let size = ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)
                    text += "  " + key + ":  \(entry.files) files, " + size + "\n"
                }
            }
            if ordered.count > 80 { text += "  …and \(ordered.count - 80) more folders\n" }
            text += "Every file and its checksum: " + checksumFileName + "\n"
        }
        text += "\nSigned: ______________________________    Date: ______________\n"

        var reportURL = folder.appendingPathComponent(stamp.string(from: input.finished) + " Backup Report.txt")
        var counter = 2
        while fm.fileExists(atPath: reportURL.path) {
            reportURL = folder.appendingPathComponent(stamp.string(from: input.finished) + " Backup Report \(counter).txt")
            counter += 1
        }
        try Data(text.utf8).write(to: reportURL, options: .atomic)
        return reportURL.path
    }
}
