import Foundation
import CryptoKit

@main struct BenchmarkSmokeTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw DigiBenchmarkEngine.failure("Benchmark check failed: " + message) }
    }
    static func expectFailure(_ action: () throws -> Void, _ message: String) throws {
        var failed = false
        do { try action() } catch { failed = true }
        try require(failed, message)
    }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DigiSuite_Benchmark_Check_" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let targetA = root.appendingPathComponent("TargetA", isDirectory: true)
        let targetB = root.appendingPathComponent("TargetB", isDirectory: true)
        for directory in [source, targetA, targetB, source.appendingPathComponent("RAW"), source.appendingPathComponent("Selects/Empty") ] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let payload = Data(repeating: 0xa7, count: 9 * 1024 * 1024 + 37)
        let raw = source.appendingPathComponent("RAW/test.iiq")
        try payload.write(to: raw)
        try Data("note".utf8).write(to: source.appendingPathComponent("note.txt"))
        try Data().write(to: source.appendingPathComponent("empty.dat"))
        try Data("hidden".utf8).write(to: source.appendingPathComponent(".hidden"))
        let sentinel = targetA.appendingPathComponent("existing-backup.txt")
        let sentinelBytes = Data("Existing backup must survive".utf8)
        try sentinelBytes.write(to: sentinel)
        try fm.createSymbolicLink(at: source.appendingPathComponent("linked-backup"), withDestinationURL: sentinel)
        let inventory = try DigiBenchmarkEngine.inventory(source, includeHidden: false)
        try require(inventory.files.count == 3, "hidden files and symlinks are excluded")
        try require(inventory.directories.contains("Selects/Empty"), "empty directories are included")
        try require(try DigiBenchmarkEngine.inventory(source, includeHidden: true).files.count == 4, "hidden-file option works")
        try expectFailure({ try DigiBenchmarkEngine.validateLocations(source: source, targets: [source]) }, "equal paths rejected")
        try expectFailure({ try DigiBenchmarkEngine.validateLocations(source: source, targets: [root]) }, "ancestor target rejected")
        try expectFailure({ try DigiBenchmarkEngine.validateLocations(source: source, targets: [source.appendingPathComponent("RAW")]) }, "descendant target rejected")
        try expectFailure({ try DigiBenchmarkEngine.validateLocations(source: source, targets: [URL(fileURLWithPath: "/")]) }, "filesystem root rejected")

        for mode in DigiBenchmarkMode.allCases {
            let scratch = try DigiBenchmarkScratch.create(parent: targetA, source: source, bytes: inventory.bytes)
            let progress = await DigiBenchmarkEngine.transfer(inventory: inventory, scratch: scratch, mode: mode, control: DigiBenchmarkControl()) { _ in }
            try require(progress.succeeded, mode.rawValue + " completes")
            try require(progress.completedFiles == 3 && progress.completedBytes == inventory.bytes, "all bytes/files complete")
            try require(try Data(contentsOf: scratch.data.appendingPathComponent("RAW/test.iiq")) == payload, "copied bytes match source")
            try require(fm.fileExists(atPath: scratch.data.appendingPathComponent("Selects/Empty").path), "empty directory copied")
            if mode == .copyOnly { try require(progress.verifySeconds == 0, "copy-only has no verification work") }
            else { try require(progress.verifySeconds > 0, "verified mode records hashing work") }
            try scratch.cleanup()
            try require(!fm.fileExists(atPath: scratch.root.path), "owned temporary data removed")
            try require(try Data(contentsOf: sentinel) == sentinelBytes, "existing backup untouched")
        }

        let emptyHash = try DigiBenchmarkEngine.hash(source.appendingPathComponent("empty.dat"))
        try require(emptyHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "known SHA-256 vector")
        try expectFailure({ _ = try DigiBenchmarkEngine.verify(raw, expected: "incorrect") }, "checksum mismatch rejected")

        let stoppedScratch = try DigiBenchmarkScratch.create(parent: targetA, source: source, bytes: inventory.bytes)
        let stoppedControl = DigiBenchmarkControl()
        stoppedControl.stop()
        let stopped = await DigiBenchmarkEngine.transfer(inventory: inventory, scratch: stoppedScratch, mode: .verified, control: stoppedControl) { _ in }
        try require(stopped.stopped && !stopped.succeeded && stopped.copiedBytes == 0, "pre-stopped test does not copy")
        try stoppedScratch.cleanup()

        let interruptedScratch = try DigiBenchmarkScratch.create(parent: targetA, source: source, bytes: inventory.bytes)
        let interruptedControl = DigiBenchmarkControl()
        let interrupted = await DigiBenchmarkEngine.transfer(inventory: inventory, scratch: interruptedScratch, mode: .verified, control: interruptedControl) { progress in
            if progress.status.hasPrefix("Verifying ") { interruptedControl.stop() }
        }
        try require(interrupted.stopped && !interrupted.succeeded, "stop during verification drains hashing workers")
        try interruptedScratch.cleanup()

        let owned = try DigiBenchmarkScratch.create(parent: targetA, source: source, bytes: inventory.bytes)
        try Data("wrong owner".utf8).write(to: owned.root.appendingPathComponent(".benchmark-owner"))
        try expectFailure({ try owned.cleanup() }, "unowned folder is never recursively removed")
        try require(fm.fileExists(atPath: owned.root.path), "unowned directory preserved")
        try Data(owned.token.utf8).write(to: owned.root.appendingPathComponent(".benchmark-owner"))
        try owned.cleanup()

        let a = try DigiBenchmarkScratch.create(parent: targetA, source: source, bytes: inventory.bytes)
        let b = try DigiBenchmarkScratch.create(parent: targetB, source: source, bytes: inventory.bytes)
        let parallelControl = DigiBenchmarkControl()
        let parallel = await withTaskGroup(of: DigiBenchmarkProgress.self, returning: [DigiBenchmarkProgress].self) { group in
            for scratch in [a, b] {
                group.addTask {
                    await DigiBenchmarkEngine.transfer(inventory: inventory, scratch: scratch, mode: .verified, control: parallelControl) { _ in }
                }
            }
            var values: [DigiBenchmarkProgress] = []
            for await value in group { values.append(value) }
            return values
        }
        try require(parallel.count == 2 && parallel.allSatisfy(\.succeeded), "two destinations complete concurrently")
        try a.cleanup(); try b.cleanup()
        try require(try Data(contentsOf: raw) == payload, "source was not modified")
        try require(try Data(contentsOf: sentinel) == sentinelBytes, "existing backup still unchanged")
        try require(DigiBenchmarkEngine.csvCell("a,\"b\"\n") == "\"a,\"\"b\"\"\n\"", "CSV quoting")
        let changed = inventory.files.first(where: { $0.relative == "note.txt" })!
        try Data("changed".utf8).write(to: changed.url)
        try expectFailure({ try DigiBenchmarkEngine.validateFile(changed) }, "source changes invalidate the test")
        print("Benchmark safety checks passed: both modes, checksum mismatch, parallel copies, cancellation, source checks and owned-folder cleanup.")
    }
}
