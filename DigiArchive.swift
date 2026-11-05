import Foundation

// v1.25: the archive on each backup drive. When a file changes or is removed
// from the session, the old copy is moved into _StudioSession_Archive/<date>/
// (older drives: _ShootWrap_Archive). This shows how big that is, clears it on
// request, and can trim the oldest backups' copies when the drive runs low.

enum DigiArchive {
    struct Info: Sendable, Equatable {
        var bytes: Int64 = 0
        var runs: Int = 0
        var oldest: Date?
        var isEmpty: Bool { runs == 0 && bytes == 0 }
    }

    /// The archive folders that exist on this backup (new name and old).
    static func roots(in destination: URL) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for name in [DigiFastBackupEngine.legacyArchiveName, DigiFastBackupEngine.archiveName] {
            let url = destination.appendingPathComponent(name, isDirectory: true)
            if isRealFolder(url) && fm.fileExists(atPath: url.path) { result.append(url) }
        }
        return result
    }

    /// One entry per backup that archived something, oldest first.
    static func runs(in destination: URL) -> [URL] {
        let fm = FileManager.default
        var all: [URL] = []
        for root in roots(in: destination) {
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
            for child in children where isRealFolder(child) { all.append(child) }
        }
        // Folder names start with an ISO date, so name order is time order.
        return all.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isRealFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let allocated: Int = values.totalFileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(allocated)
        }
        return total
    }

    static func measure(_ destination: URL) -> Info {
        var info = Info()
        let list = runs(in: destination)
        info.runs = list.count
        for root in roots(in: destination) { info.bytes += size(of: root) }
        if let first = list.first {
            info.oldest = (try? first.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        return info
    }

    /// Only ever deletes inside this backup's own archive folders.
    private static func safeToDelete(_ item: URL, destination: URL) -> Bool {
        let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
        let base = destination.resolvingSymlinksInPath().standardizedFileURL.path
        for name in DigiFastBackupEngine.archiveNames {
            let prefix = base + "/" + name
            if resolved == prefix || resolved.hasPrefix(prefix + "/") { return isRealFolder(item) }
        }
        return false
    }

    /// Deletes the whole archive (both names). Returns the space freed.
    @discardableResult
    static func clearAll(_ destination: URL) throws -> Int64 {
        var freed: Int64 = 0
        for root in roots(in: destination) {
            guard safeToDelete(root, destination: destination) else { continue }
            let bytes = size(of: root)
            try FileManager.default.removeItem(at: root)
            freed += bytes
        }
        return freed
    }

    /// Deletes the oldest backups' archived copies, one at a time, until the
    /// drive has `keepFree` bytes free or the archive is empty.
    static func trimOldest(_ destination: URL, keepFree: Int64,
                           free: (URL) -> Int64? = { DigiFastBackupEngine.availableBytes($0) }) throws -> (runs: Int, bytes: Int64) {
        var removed = 0
        var freed: Int64 = 0
        for run in runs(in: destination) {
            guard let available = free(destination), available < keepFree else { break }
            guard safeToDelete(run, destination: destination) else { continue }
            let bytes = size(of: run)
            try FileManager.default.removeItem(at: run)
            removed += 1
            freed += bytes
        }
        // Tidy up archive folders left empty.
        for root in roots(in: destination) {
            let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? ["?"]
            if left.isEmpty, safeToDelete(root, destination: destination) { try? FileManager.default.removeItem(at: root) }
        }
        return (removed, freed)
    }
}
