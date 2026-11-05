import Foundation
import CryptoKit
import Dispatch

// The diagnostic engine deliberately has no connection to normal backup manifests,
// filters or archive policies. It writes only inside a freshly owned scratch folder.
enum DigiBenchmarkMode: String, CaseIterable, Sendable {
    case copyOnly = "Copy only"
    case verified = "Copy + SHA-256"
}

struct DigiBenchmarkFile: Equatable, Sendable {
    let relative: String
    let url: URL
    let size: Int64
    let modified: Date
}

struct DigiBenchmarkInventory: Sendable {
    let source: URL
    let files: [DigiBenchmarkFile]
    let directories: [String]
    let includeHidden: Bool
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    func matches(_ other: Self) -> Bool {
        source == other.source && files == other.files && directories == other.directories
    }
}

// Copy and detached hash workers share one small, lock-protected stop token.
final class DigiBenchmarkControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func checkpoint() throws {
        try Task.checkCancellation()
        lock.lock(); let shouldStop = stopped; lock.unlock()
        if shouldStop { throw CancellationError() }
    }
}

struct DigiBenchmarkProgress: Sendable {
    let destination: String
    var status = "Preparing"
    var copiedBytes: Int64 = 0
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var completedFiles = 0
    var totalFiles = 0
    var copySeconds: Double = 0
    var verifySeconds: Double = 0
    var finalizeSeconds: Double = 0
    var planningSeconds: Double = 0
    var elapsedSeconds: Double = 0
    var error: String?
    var stopped = false
    var succeeded: Bool {
        error == nil && !stopped && completedFiles == totalFiles && completedBytes == totalBytes
    }
}

struct DigiBenchmarkScratch: Sendable {
    let parent: URL
    let root: URL
    let token: String
    var data: URL { root.appendingPathComponent("Data", isDirectory: true) }

    static func create(parent: URL, source: URL, bytes: Int64) throws -> Self {
        let fm = FileManager.default
        let parent = parent.resolvingSymlinksInPath().standardizedFileURL
        try DigiBenchmarkEngine.validateLocations(source: source, targets: [parent])
        let capacity = try parent.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let available = capacity.volumeAvailableCapacity, Int64(available) < bytes + 64 * 1024 * 1024 {
            throw DigiBenchmarkEngine.failure("Not enough free space on " + parent.path + ". Choose a smaller test folder or free space on the drive.")
        }
        let token = UUID().uuidString
        let root = parent.appendingPathComponent("_DigiSuite_Benchmark_" + token, isDirectory: true)
        guard !fm.fileExists(atPath: root.path) else {
            throw DigiBenchmarkEngine.failure("Benchmark folder already exists. Run the test again.")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let scratch = Self(parent: parent, root: root, token: token)
        do {
            try Data(token.utf8).write(to: root.appendingPathComponent(".benchmark-owner"), options: .withoutOverwriting)
            try fm.createDirectory(at: scratch.data, withIntermediateDirectories: false)
        } catch {
            // An unmarked folder is never recursively deleted.
            if (try? Data(contentsOf: root.appendingPathComponent(".benchmark-owner"))) == Data(token.utf8) {
                try? scratch.cleanup()
            }
            throw error
        }
        return scratch
    }

    func cleanup() throws {
        let fm = FileManager.default
        try DigiBenchmarkEngine.requireAvailableDirectory(parent)
        let expected = parent.appendingPathComponent("_DigiSuite_Benchmark_" + token, isDirectory: true).standardizedFileURL
        guard root.standardizedFileURL.path == expected.path,
              root.deletingLastPathComponent().standardizedFileURL.path == parent.path,
              parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path else {
            throw DigiBenchmarkEngine.failure("Temporary folder ownership could not be confirmed: " + root.path)
        }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              root.resolvingSymlinksInPath().standardizedFileURL.path == expected.path,
              try Data(contentsOf: root.appendingPathComponent(".benchmark-owner")) == Data(token.utf8) else {
            throw DigiBenchmarkEngine.failure("Temporary folder ownership could not be confirmed: " + root.path)
        }
        try fm.removeItem(at: root)
    }
}

enum DigiBenchmarkEngine {
    static let copyBlockSize = 4 * 1024 * 1024
    static let verifyBlockSize = 1024 * 1024

    static func clock() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "DigiSuiteBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func requireAvailableDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw failure("Folder or drive is unavailable: " + url.path)
        }
        #if os(macOS)
        let parts = url.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            let expected = URL(fileURLWithPath: "/Volumes").appendingPathComponent(parts[2]).standardizedFileURL
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
            guard volumes.contains(where: { $0.standardizedFileURL == expected }) else {
                throw failure("Drive is disconnected: " + expected.path)
            }
        }
        #endif
    }

    static func validateLocations(source: URL, targets: [URL]) throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        try requireAvailableDirectory(source)
        var resolved: [URL] = []
        for target in targets {
            let target = target.resolvingSymlinksInPath().standardizedFileURL
            try requireAvailableDirectory(target)
            guard !contains(source, target), !contains(target, source) else {
                throw failure("The test source and destination folders must not contain one another.")
            }
            guard !resolved.contains(where: {
                contains($0, target) || contains(target, $0)
            }) else {
                throw failure("Choose two separate destination folders.")
            }
            resolved.append(target)
        }
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return parent.path == child.path || child.path.hasPrefix(prefix)
    }

    static func inventory(_ folder: URL, includeHidden: Bool) throws -> DigiBenchmarkInventory {
        let source = folder.resolvingSymlinksInPath().standardizedFileURL
        try requireAvailableDirectory(source)
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var pending: [(URL, String)] = [(source, "")]
        var files: [DigiBenchmarkFile] = []
        var directories: [String] = []
        while let (directory, prefix) = pending.popLast() {
            try Task.checkCancellation()
            // Errors propagate. An incomplete enumeration cannot become a successful test.
            let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [])
            for child in children {
                if DigiFastBackupEngine.toolFolderNames.contains(child.lastPathComponent) { continue }
                if !includeHidden && child.lastPathComponent.hasPrefix(".") { continue }
                let values = try child.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }
                let relative = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                if values.isDirectory == true {
                    directories.append(relative)
                    pending.append((child, relative))
                } else if values.isRegularFile == true {
                    guard let size = values.fileSize, let modified = values.contentModificationDate else {
                        throw failure("Could not inspect source file: " + child.path)
                    }
                    files.append(DigiBenchmarkFile(relative: relative, url: child, size: Int64(size), modified: modified))
                } else {
                    throw failure("Unsupported source file: " + child.path)
                }
            }
        }
        files.sort { $0.relative < $1.relative }
        directories.sort {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a == b ? $0 < $1 : a < b
        }
        return DigiBenchmarkInventory(source: source, files: files, directories: directories, includeHidden: includeHidden)
    }

    static func validateFile(_ file: DigiBenchmarkFile) throws {
        var freshURL = file.url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == file.size, values.contentModificationDate == file.modified else {
            throw failure("Source changed during the benchmark: " + file.relative + ". Use a folder that is not being edited.")
        }
    }

    static func hash(_ file: URL, control: DigiBenchmarkControl? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            try control?.checkpoint()
            let block = try handle.read(upToCount: verifyBlockSize) ?? Data()
            if block.isEmpty { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ file: URL, expected: String, control: DigiBenchmarkControl? = nil) throws -> Double {
        let started = clock()
        guard try hash(file, control: control) == expected else { throw failure("SHA-256 mismatch: " + file.lastPathComponent) }
        return clock() - started
    }

    // Mirrors version 09: 4 MiB streaming copy, source hashing inline, 1 MiB
    // destination hash reads, and at most two staged files per destination.
    // Copy-only uses the same copy/finalize path but never calculates a checksum.
    static func transfer(inventory: DigiBenchmarkInventory, scratch: DigiBenchmarkScratch,
                         mode: DigiBenchmarkMode, control: DigiBenchmarkControl,
                         report: @escaping @Sendable (DigiBenchmarkProgress) async -> Void) async -> DigiBenchmarkProgress {
        let fm = FileManager.default
        let started = clock()
        var state = DigiBenchmarkProgress(destination: scratch.parent.path)
        state.totalFiles = inventory.files.count
        state.totalBytes = inventory.bytes
        struct Pending {
            let file: DigiBenchmarkFile
            let temporary: URL
            let destination: URL
            let verification: Task<Double, Error>?
        }
        var pending: [Pending] = []
        var workers: [String: Task<Double, Error>] = [:]
        var lastUpdate = clock()
        func finishOldest() async throws {
            guard !pending.isEmpty else { return }
            let item = pending.removeFirst()
            defer { try? fm.removeItem(at: item.temporary) }
            try control.checkpoint()
            if let verification = item.verification {
                state.status = "Verifying " + item.file.relative
                state.elapsedSeconds = clock() - started
                await report(state)
                state.verifySeconds += try await verification.value
                workers.removeValue(forKey: item.temporary.path)
            }
            try control.checkpoint()
            try validateFile(item.file)
            let finalizeStarted = clock()
            try fm.setAttributes([.modificationDate: item.file.modified], ofItemAtPath: item.temporary.path)
            // The entire destination is owned scratch; existing files are an error.
            try fm.moveItem(at: item.temporary, to: item.destination)
            state.finalizeSeconds += clock() - finalizeStarted
            state.completedBytes += item.file.size
            state.completedFiles += 1
            state.status = mode == .verified ? "Copying and verifying" : "Copying (unverified test)"
            state.elapsedSeconds = clock() - started
            await report(state)
        }
        do {
            try control.checkpoint()
            try requireAvailableDirectory(scratch.parent)
            for directory in inventory.directories {
                try control.checkpoint()
                try fm.createDirectory(at: scratch.data.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
            }
            state.planningSeconds = clock() - started
            await report(state)
            for file in inventory.files {
                try control.checkpoint()
                try requireAvailableDirectory(scratch.parent)
                try validateFile(file)
                let destination = scratch.data.appendingPathComponent(file.relative)
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".benchmark-" + UUID().uuidString + ".tmp")
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: temporary.path, contents: nil) else { throw failure("Could not create test file: " + temporary.path) }
                var queued = false
                defer { if !queued { try? fm.removeItem(at: temporary) } }
                let copyStarted = clock()
                let reader = try FileHandle(forReadingFrom: file.url)
                let writer: FileHandle
                do { writer = try FileHandle(forWritingTo: temporary) }
                catch { try? reader.close(); throw error }
                var sourceHash: SHA256? = mode == .verified ? SHA256() : nil
                var copied: Int64 = 0
                do {
                    while true {
                        try control.checkpoint()
                        let block = try reader.read(upToCount: copyBlockSize) ?? Data()
                        if block.isEmpty { break }
                        sourceHash?.update(data: block)
                        try writer.write(contentsOf: block)
                        copied += Int64(block.count)
                        state.copiedBytes += Int64(block.count)
                        if clock() - lastUpdate >= 0.3 {
                            state.status = "Copying " + file.relative
                            state.elapsedSeconds = clock() - started
                            await report(state)
                            lastUpdate = clock()
                        }
                    }
                    try reader.close()
                    try writer.close()
                } catch { try? reader.close(); try? writer.close(); throw error }
                state.copySeconds += clock() - copyStarted
                guard copied == file.size else { throw failure("Source size changed during copy: " + file.relative) }
                try validateFile(file)
                let verification: Task<Double, Error>?
                if let hasher = sourceHash {
                    let expected = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    verification = Task.detached(priority: .utility) { try verify(temporary, expected: expected, control: control) }
                    workers[temporary.path] = verification
                } else { verification = nil }
                pending.append(Pending(file: file, temporary: temporary, destination: destination, verification: verification))
                queued = true
                if pending.count >= 2 { try await finishOldest() }
            }
            while !pending.isEmpty { try await finishOldest() }
            try control.checkpoint()
            state.status = mode == .verified ? "Verified" : "Copied (not verified)"
        } catch is CancellationError {
            state.stopped = true
            state.status = "Stopped"
        } catch {
            state.error = error.localizedDescription
            state.status = "Failed"
        }
        // Detached hashing workers must finish before cleanup or the next trial.
        // Cancellation is checked for every verification block.
        for worker in workers.values { worker.cancel() }
        for worker in workers.values { _ = try? await worker.value }
        for item in pending { try? fm.removeItem(at: item.temporary) }
        state.elapsedSeconds = clock() - started
        await report(state)
        return state
    }

    static func csvCell(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
