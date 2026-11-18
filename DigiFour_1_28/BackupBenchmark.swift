import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

struct DigiBenchmarkResult: Identifiable, Sendable {
    let id = UUID()
    let trial: Int
    let configuration: String
    let mode: DigiBenchmarkMode
    let target: String
    let source: String
    let targetPath: String
    let temporaryPath: String
    var progress: DigiBenchmarkProgress
    let trialSeconds: Double
    let cleanupSeconds: Double
    let cleanup: String
    let inventorySeconds: Double
    let modeOrder: String
    let includeHidden: Bool
    let recordedAt: String
    var passed: Bool { progress.succeeded && cleanup == "Removed" }
}

private struct DigiBenchmarkTarget: Sendable {
    let label: String
    let folder: URL
}

struct DigiBenchmarkComparison: Identifiable {
    let configuration: String
    let copySeconds: Double
    let verifiedSeconds: Double
    var id: String { configuration }
}

@MainActor final class DigiBackupBenchmark: ObservableObject {
    static let shared = DigiBackupBenchmark()
    @Published var source: URL?
    @Published var firstTarget: URL?
    @Published var secondTarget: URL?
    @Published var verifiedFirst = false
    @Published var includeHidden = false
    @Published private(set) var isRunning = false
    @Published private(set) var stopping = false
    @Published private(set) var status = "Choose a test source and one or two destination folders."
    @Published private(set) var sourceDescription = ""
    @Published private(set) var live: [DigiBenchmarkProgress] = []
    @Published private(set) var results: [DigiBenchmarkResult] = []
    @Published private(set) var completedTests = 0
    @Published private(set) var totalTests = 0
    @Published private(set) var trialStarted: Date?
    @Published private(set) var activeTitle = ""
    private var control: DigiBenchmarkControl?
    private var task: Task<Void, Never>?

    func useWorkspace(_ workspace: WrapModel, onlyIfEmpty: Bool = false) {
        guard !isRunning, !onlyIfEmpty || source == nil else { return }
        source = workspace.syncSource ?? workspace.root
        firstTarget = workspace.backups.first
        secondTarget = workspace.backups.dropFirst().first
    }

    func chooseFolder(_ kind: Int) {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = kind == 0 ? "Choose the same representative source for every test." : "Test copies will use a new temporary subfolder here."
        if panel.runModal() == .OK, let folder = panel.url {
            switch kind {
            case 0: source = folder
            case 1: firstTarget = folder
            default: secondTarget = folder
            }
        }
    }

    func stop() {
        guard isRunning, !stopping else { return }
        stopping = true
        status = "Stopping and removing temporary test data…"
        control?.stop()
        task?.cancel()
    }

    func start() {
        guard !isRunning else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.digitools.app"
        let otherInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard otherInstances.isEmpty else {
            status = "Another \(DigiBrand.name) instance is running. Let its backups finish and quit that instance before starting the benchmark."
            return
        }
        guard !DigiBackupQuitRegistry.shared.hasActiveDiskOperations else {
            status = "Wait for \(DigiBrand.name)'s active backup or scan to finish, then start the benchmark."
            return
        }
        guard let source, let firstTarget else {
            status = "Choose a source folder and the first destination."
            return
        }
        let targetFolders = [firstTarget, secondTarget].compactMap { $0 }
        do { try DigiBenchmarkEngine.validateLocations(source: source, targets: targetFolders) }
        catch { status = error.localizedDescription; return }
        let targets = targetFolders.enumerated().map { index, folder in
            DigiBenchmarkTarget(label: Self.targetName(folder, index: index), folder: folder)
        }
        let groups: [(String, [DigiBenchmarkTarget])] = targets.count == 2
            ? [("Target A alone", [targets[0]]), ("Target B alone", [targets[1]]), ("Both together", targets)]
            : [("Target A alone", targets)]
        let modes: [DigiBenchmarkMode] = verifiedFirst ? [.verified, .copyOnly] : [.copyOnly, .verified]
        let modeOrder = verifiedFirst ? "Verified first" : "Copy only first"
        let includeHidden = self.includeHidden
        let control = DigiBenchmarkControl()
        self.control = control
        isRunning = true
        stopping = false
        results = []
        live = []
        completedTests = 0
        totalTests = groups.count * modes.count
        trialStarted = nil
        sourceDescription = ""
        status = "Inspecting the source folder…"
        task = Task.detached(priority: .utility) {
            var ending = "Benchmark complete. Export the CSV to compare the results."
            do {
                let inventoryStarted = DigiBenchmarkEngine.clock()
                let inventory = try DigiBenchmarkEngine.inventory(source, includeHidden: includeHidden)
                let inventorySeconds = DigiBenchmarkEngine.clock() - inventoryStarted
                guard !inventory.files.isEmpty, inventory.bytes > 0 else {
                    throw DigiBenchmarkEngine.failure("Choose a source with nonempty files to measure transfer speed.")
                }
                try control.checkpoint()
                await MainActor.run {
                    self.sourceDescription = "\(inventory.files.count.formatted()) files · " + ByteCountFormatter.string(fromByteCount: inventory.bytes, countStyle: .file) + " per destination"
                }
                var trial = 0
                for (configuration, groupTargets) in groups {
                    for mode in modes {
                        try control.checkpoint()
                        let current = try DigiBenchmarkEngine.inventory(source, includeHidden: includeHidden)
                        guard inventory.matches(current) else {
                            throw DigiBenchmarkEngine.failure("The source changed between tests. Use a folder that is not being edited, then run again.")
                        }
                        trial += 1
                        let trialNumber = trial
                        await MainActor.run {
                            self.live = []
                            self.activeTitle = "Test \(trialNumber) of \(self.totalTests) · \(configuration) · \(mode.rawValue)"
                            self.status = self.activeTitle
                            self.trialStarted = Date()
                        }
                        let rows = try await Self.runTrial(inventory: inventory, targets: groupTargets,
                            trial: trialNumber, configuration: configuration, mode: mode, control: control,
                            inventorySeconds: inventorySeconds, modeOrder: modeOrder, report: { progress in
                                await MainActor.run {
                                    if let index = self.live.firstIndex(where: { $0.destination == progress.destination }) {
                                        self.live[index] = progress
                                    } else { self.live.append(progress) }
                                }
                            }, afterTransfer: {
                                await MainActor.run {
                                    self.trialStarted = nil
                                    self.status = "Checking the source and removing temporary test data…"
                                }
                            })
                        await MainActor.run {
                            self.results.append(contentsOf: rows)
                            self.completedTests = trialNumber
                            self.trialStarted = nil
                        }
                        try control.checkpoint()
                        guard rows.allSatisfy(\.passed) else {
                            throw DigiBenchmarkEngine.failure("Benchmark stopped after a failed test. See the result details and export the CSV.")
                        }
                    }
                }
            } catch is CancellationError {
                ending = "Benchmark stopped. Completed results are available below."
            } catch { ending = error.localizedDescription }
            let finalStatus = ending
            await MainActor.run {
                self.isRunning = false
                self.stopping = false
                self.status = finalStatus
                self.trialStarted = nil
                self.control = nil
                self.task = nil
            }
        }
    }

    nonisolated private static func runTrial(inventory: DigiBenchmarkInventory, targets: [DigiBenchmarkTarget],
        trial: Int, configuration: String, mode: DigiBenchmarkMode, control: DigiBenchmarkControl,
        inventorySeconds: Double, modeOrder: String,
        report: @escaping @Sendable (DigiBenchmarkProgress) async -> Void,
        afterTransfer: @escaping @Sendable () async -> Void) async throws -> [DigiBenchmarkResult] {
        var scratches: [(DigiBenchmarkTarget, DigiBenchmarkScratch)] = []
        do {
            try validateCapacity(bytes: inventory.bytes, targets: targets)
            for target in targets {
                try control.checkpoint()
                scratches.append((target, try DigiBenchmarkScratch.create(parent: target.folder, source: inventory.source, bytes: inventory.bytes)))
            }
        } catch {
            var cleanupErrors: [String] = []
            for (_, scratch) in scratches {
                do { try scratch.cleanup() }
                catch { cleanupErrors.append(scratch.root.path + ": " + error.localizedDescription) }
            }
            if !cleanupErrors.isEmpty {
                throw DigiBenchmarkEngine.failure(error.localizedDescription + " Temporary folders need attention: " + cleanupErrors.joined(separator: "; "))
            }
            throw error
        }
        let prepared = scratches
        let started = DigiBenchmarkEngine.clock()
        let transfers = await withTaskGroup(of: (Int, DigiBenchmarkProgress).self, returning: [(Int, DigiBenchmarkProgress)].self) { group in
            for (index, pair) in prepared.enumerated() {
                let scratch = pair.1
                group.addTask {
                    let progress = await DigiBenchmarkEngine.transfer(inventory: inventory, scratch: scratch,
                        mode: mode, control: control, report: report)
                    return (index, progress)
                }
            }
            var values: [(Int, DigiBenchmarkProgress)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }
        }
        let trialSeconds = DigiBenchmarkEngine.clock() - started
        await afterTransfer()
        // Validation and cleanup are deliberately outside the transfer timer.
        // On Stop, skip re-enumeration and proceed directly to owned-folder cleanup.
        var sourceIssue: String?
        if !Task.isCancelled && !transfers.contains(where: { $0.1.stopped }) {
            do {
                let after = try DigiBenchmarkEngine.inventory(inventory.source, includeHidden: inventory.includeHidden)
                if !inventory.matches(after) { sourceIssue = "Source changed during the test; timing comparison is invalid." }
            } catch is CancellationError {
                // A user stop is not evidence that the source changed.
            } catch { sourceIssue = "Source validation failed: " + error.localizedDescription }
        }
        var rows: [DigiBenchmarkResult] = []
        for (index, transfer) in transfers {
            let (target, scratch) = prepared[index]
            let cleanupStarted = DigiBenchmarkEngine.clock()
            let cleanup: String
            do { try scratch.cleanup(); cleanup = "Removed" }
            catch { cleanup = "Could not remove " + scratch.root.path + ": " + error.localizedDescription }
            let cleanupSeconds = DigiBenchmarkEngine.clock() - cleanupStarted
            var progress = transfer
            if let sourceIssue {
                progress.error = progress.error ?? sourceIssue
                progress.status = "Invalid: source changed or unavailable"
            }
            rows.append(DigiBenchmarkResult(trial: trial, configuration: configuration, mode: mode,
                target: target.label, source: inventory.source.path, targetPath: scratch.parent.path,
                temporaryPath: scratch.root.path, progress: progress, trialSeconds: trialSeconds,
                cleanupSeconds: cleanupSeconds, cleanup: cleanup, inventorySeconds: inventorySeconds,
                modeOrder: modeOrder, includeHidden: inventory.includeHidden,
                recordedAt: ISO8601DateFormatter().string(from: Date())))
        }
        return rows
    }

    nonisolated private static func validateCapacity(bytes: Int64, targets: [DigiBenchmarkTarget]) throws {
        var volumes: [String: (Int64, Int64)] = [:]
        for target in targets {
            try DigiBenchmarkEngine.requireAvailableDirectory(target.folder)
            let values = try target.folder.resourceValues(forKeys: [.volumeURLKey, .volumeAvailableCapacityKey])
            let key = values.volume?.path ?? target.folder.path
            let available = Int64(values.volumeAvailableCapacity ?? Int.max)
            let prior = volumes[key] ?? (0, available)
            volumes[key] = (prior.0 + bytes, min(prior.1, available))
        }
        for (_, capacity) in volumes where capacity.0 + 64 * 1024 * 1024 > capacity.1 {
            throw DigiBenchmarkEngine.failure("The destinations need enough free space for one test copy per active target. Choose a smaller source folder.")
        }
    }

    private static func targetName(_ folder: URL, index: Int) -> String {
        let volume = (try? folder.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? folder.lastPathComponent
        return (index == 0 ? "A: " : "B: ") + volume
    }

    var sameVolume: Bool {
        guard let firstTarget, let secondTarget,
              let first = try? firstTarget.resourceValues(forKeys: [.volumeURLKey]).volume,
              let second = try? secondTarget.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return first == second
    }

    var comparisons: [DigiBenchmarkComparison] {
        let names = ["Target A alone", "Target B alone", "Both together"]
        return names.compactMap { name in
            let copy = results.filter { $0.configuration == name && $0.mode == .copyOnly }
            let verified = results.filter { $0.configuration == name && $0.mode == .verified }
            guard !copy.isEmpty, copy.count == verified.count,
                  copy.allSatisfy(\.passed), verified.allSatisfy(\.passed),
                  copy.reduce(Int64(0), { $0 + $1.progress.totalBytes }) == verified.reduce(Int64(0), { $0 + $1.progress.totalBytes }),
                  let first = copy.first, let second = verified.first else { return nil }
            return DigiBenchmarkComparison(configuration: name, copySeconds: first.trialSeconds, verifiedSeconds: second.trialSeconds)
        }
    }

    func exportCSV() {
        guard !results.isEmpty, !isRunning else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd_HHmmss"
        panel.nameFieldStringValue = "DigiSuite_Backup_Benchmark_" + formatter.string(from: Date()) + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let header = ["build", "recorded_at", "configuration", "trial", "mode", "mode_order", "target", "source", "target_folder", "test_folder", "include_hidden", "files", "bytes", "copied_bytes", "completed_files", "completed_bytes", "copy_seconds_including_source_hash_if_enabled", "verify_seconds", "finalize_seconds", "planning_seconds", "target_elapsed_seconds", "trial_elapsed_seconds", "effective_MBps", "cleanup_seconds", "cleanup", "status", "error", "inventory_seconds", "cache_policy", "os_version"]
        var lines = [header.map(DigiBenchmarkEngine.csvCell).joined(separator: ",")]
        for row in results {
            let p = row.progress
            let fields = ["DigiSuite_Backup_Benchmark_10", row.recordedAt, row.configuration, String(row.trial), row.mode.rawValue, row.modeOrder, row.target, row.source, row.targetPath, row.temporaryPath, String(row.includeHidden), String(p.totalFiles), String(p.totalBytes), String(p.copiedBytes), String(p.completedFiles), String(p.completedBytes),
                Self.decimal(p.copySeconds), Self.decimal(p.verifySeconds), Self.decimal(p.finalizeSeconds), Self.decimal(p.planningSeconds), Self.decimal(p.elapsedSeconds), Self.decimal(row.trialSeconds), Self.decimal(Double(p.completedBytes) / max(0.001, p.elapsedSeconds) / 1_000_000), Self.decimal(row.cleanupSeconds), row.cleanup, p.status, p.error ?? "", Self.decimal(row.inventorySeconds), "Normal macOS caching; not cleared", ProcessInfo.processInfo.operatingSystemVersionString]
            lines.append(fields.map(DigiBenchmarkEngine.csvCell).joined(separator: ","))
        }
        do { try (lines.joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { status = "Could not export CSV: " + error.localizedDescription }
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

@MainActor struct BackupBenchmarkView: View {
    @ObservedObject var workspace: WrapModel
    @ObservedObject private var benchmark = DigiBackupBenchmark.shared
    @Environment(\.dismiss) private var dismiss

    private func duration(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func folderRow(_ label: String, folder: URL?, kind: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: kind == 0 ? "folder.fill" : "externaldrive.fill").foregroundStyle(kind == 0 ? Color.blue : Color.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.subheadline.weight(.semibold))
                Text(folder?.path ?? (kind == 2 ? "Optional: add the second drive" : "Choose a folder"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if kind == 2 && folder != nil {
                Button { benchmark.secondTarget = nil } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Test the first target only")
            }
            Button(folder == nil ? "Choose…" : "Change…") { benchmark.chooseFolder(kind) }.controlSize(.small)
        }
        .padding(12)
        .background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 10))
        .disabled(benchmark.isRunning)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit()).fontWeight(.medium)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Legacy diagnostic: these tests use the version 10 transfer engine. Use Start Backup to measure version 13 normal backup speed.")
                .font(.caption).foregroundStyle(.orange)
            HStack {
                Text("Test folders").font(.headline)
                Spacer()
                Button("Use current workspace") { benchmark.useWorkspace(workspace) }.disabled(benchmark.isRunning)
            }
            folderRow("Source for every test", folder: benchmark.source, kind: 0)
            folderRow("Target A", folder: benchmark.firstTarget, kind: 1)
            folderRow("Target B", folder: benchmark.secondTarget, kind: 2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { modeOrder; hiddenOption }
                VStack(alignment: .leading, spacing: 8) { modeOrder; hiddenOption }
            }.disabled(benchmark.isRunning)
            Text("Two targets run six tests: each target alone, then both together, using both modes. Each target receives four copies over the suite. Choose a smaller representative source for a shorter test.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Test copies use fresh temporary folders and are removed after each test. All included source files are used with the same selection in both modes; destination backup exclusions are not applied.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Pause other disk-heavy work while timing the tests.").font(.caption).foregroundStyle(.secondary)
            if benchmark.sameVolume {
                Label("These targets share a mounted volume. Use separate drives to compare independent destinations.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var modeOrder: some View {
        Picker("Run first", selection: $benchmark.verifiedFirst) {
            Text("Copy only").tag(false)
            Text("Copy + SHA-256").tag(true)
        }.frame(maxWidth: 340)
    }
    private var hiddenOption: some View {
        Toggle("Include hidden files", isOn: $benchmark.includeHidden).toggleStyle(.checkbox)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(benchmark.status).font(.subheadline.weight(.medium)).textSelection(.enabled)
            if !benchmark.sourceDescription.isEmpty {
                Text(benchmark.sourceDescription).font(.caption).foregroundStyle(.secondary)
            }
            if benchmark.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("\(benchmark.completedTests) of \(benchmark.totalTests) tests finished").font(.caption)
                    Spacer()
                    if let started = benchmark.trialStarted {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text("Test elapsed " + duration(context.date.timeIntervalSince(started))).font(.caption.monospacedDigit())
                        }
                    }
                }
                ForEach(benchmark.live, id: \.destination) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.destination).font(.caption).lineLimit(1).truncationMode(.middle)
                        ProgressView(value: item.totalBytes > 0 ? min(1, Double(item.completedBytes) / Double(item.totalBytes)) : 0)
                        Text(item.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text("\(item.completedFiles) / \(item.totalFiles) finished · " + ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(DigiBrand.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !benchmark.comparisons.isEmpty {
                Text("Timing comparison").font(.headline)
                ForEach(benchmark.comparisons) { comparison in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(comparison.configuration).font(.subheadline.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                            metric("Copy only", duration(comparison.copySeconds))
                            metric("Copy + SHA-256", duration(comparison.verifiedSeconds))
                            metric("Elapsed difference", String(format: "%+.1f%%", 100 * (comparison.verifiedSeconds - comparison.copySeconds) / max(0.001, comparison.copySeconds)))
                        }
                    }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func resultCard(_ row: DigiBenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(row.configuration) · \(row.mode.rawValue)").font(.subheadline.weight(.semibold))
                    Text(row.target + " · " + row.progress.status).font(.caption).foregroundStyle(row.passed ? Color.secondary : Color.orange)
                }
                Spacer()
                Image(systemName: row.passed ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(row.passed ? Color.green : Color.orange)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 10) {
                metric("Copy", duration(row.progress.copySeconds))
                metric("Verify", row.mode == .copyOnly ? "Off for test" : duration(row.progress.verifySeconds))
                metric("Target total", duration(row.progress.elapsedSeconds))
                metric("Test total", duration(row.trialSeconds))
                metric("Effective speed", String(format: "%.1f MB/s", Double(row.progress.completedBytes) / max(0.001, row.progress.elapsedSeconds) / 1_000_000))
            }
            if let error = row.progress.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if row.cleanup != "Removed" {
                Text(row.cleanup).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Button("Show temporary folder") { NSWorkspace.shared.selectFile(row.temporaryPath, inFileViewerRootedAtPath: row.targetPath) }
                    .controlSize(.small)
            }
        }.padding(14).background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Backup Speed Benchmark", systemImage: "speedometer").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.disabled(benchmark.isRunning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    configuration
                    progressSection
                    comparisonSection
                    if !benchmark.results.isEmpty {
                        Text("Per-destination results").font(.headline)
                        ForEach(benchmark.results) { row in resultCard(row) }
                    }
                    Text("Copy time includes source hashing when enabled. Copy and destination verification overlap, so their stage times do not add up to total time. Total excludes inventory checks and cleanup. macOS caching stays enabled; reverse the mode order on a repeat run to check for order effects.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Normal backups retain SHA-256 verification.", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing, 6)
            }
            Divider()
            HStack {
                Button("Export CSV…") { benchmark.exportCSV() }.disabled(benchmark.results.isEmpty || benchmark.isRunning)
                Spacer()
                if benchmark.isRunning {
                    Button(benchmark.stopping ? "Stopping…" : "Stop Benchmark") { benchmark.stop() }
                        .disabled(benchmark.stopping).foregroundStyle(.red)
                } else {
                    Button(benchmark.results.isEmpty ? "Run Benchmark" : "Run Again") { benchmark.start() }
                        .disabled(benchmark.source == nil || benchmark.firstTarget == nil)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 700, idealWidth: 900, minHeight: 580, idealHeight: 740)
        .interactiveDismissDisabled(benchmark.isRunning)
        .onAppear { benchmark.useWorkspace(workspace, onlyIfEmpty: true) }
    }
}
