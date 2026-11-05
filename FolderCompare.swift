import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

private enum CompareMode: String, CaseIterable, Identifiable {
    case quick = "Quick", standard = "Standard", deep = "Deep Verify"
    var id: String { rawValue }
    var tooltip: String {
        switch self {
        case .quick:
            return "Quick: Compares relative file paths and file sizes. Fastest scan; does not check dates or file contents."
        case .standard:
            return "Standard: Compares file paths, sizes, and modification dates (2-second tolerance). Does not read file contents."
        case .deep:
            return "Deep Verify: Compares paths and sizes, then reads files to calculate SHA-256 hashes. Slowest, but detects same-size content changes."
        }
    }
}
private struct CompareFile: Sendable {
    let size: Int64
    let modified: Date
    let url: URL
}
private struct CompareSnapshot: Sendable {
    let root: URL
    let files: [String: CompareFile]
    let folders: Set<String>
    let errors: [String]
}
private struct CompareDifference: Identifiable {
    let id: String
    let states: [String]
    let status: Int // 0 matches, 1 differs, 2 missing
    let isFolder: Bool
}
private final class DeepVerifyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Int64 = 0
    private var filesDone = 0
    private var cancelled = false
    private let started = Date()
    let totalBytes: Int64
    let totalFiles: Int
    init(totalBytes: Int64, totalFiles: Int) {
        self.totalBytes = max(0, totalBytes)
        self.totalFiles = totalFiles
    }
    func add(_ bytes: Int) { lock.lock(); completed += Int64(bytes); lock.unlock() }
    func finishFile() { lock.lock(); filesDone += 1; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func snapshot() -> (Int64, Int, Double) {
        lock.lock(); defer { lock.unlock() }
        return (completed, filesDone, Date().timeIntervalSince(started))
    }
}
private enum CompareScanner {
    static func scan(_ root: URL, excludeHidden: Bool) -> CompareSnapshot {
        var files: [String: CompareFile] = [:]
        var folders: Set<String> = [""]
        var errors: [String] = []
        // Walk directories explicitly. FileManager.enumerator can produce an incomplete
        // traversal for certain Capture One directory/package arrangements. Reading
        // each directory's immediate children ensures we descend into every real
        // directory, including bundles, instead of trusting implicit recursion.
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey,
                                         .isSymbolicLinkKey, .fileSizeKey,
                                         .contentModificationDateKey]
        var pending: [(url: URL, relative: String)] = [(root, "")]
        var visitedDirectories = 0
        while let directory = pending.popLast() {
            visitedDirectories += 1
            let children: [URL]
            do {
                children = try manager.contentsOfDirectory(at: directory.url,
                                                            includingPropertiesForKeys: Array(keys),
                                                            options: [])
            } catch {
                errors.append("Cannot list directory \(directory.relative.isEmpty ? "." : directory.relative): \(error.localizedDescription)")
                continue
            }
            for child in children {
                let rel = directory.relative.isEmpty ? child.lastPathComponent : directory.relative + "/" + child.lastPathComponent
                if excludeHidden && child.lastPathComponent.hasPrefix(".") { continue }
                // v1.25: archive and report folders on a backup drive aren't shoot files.
                if directory.relative.isEmpty && DigiFastBackupEngine.toolFolderNames.contains(child.lastPathComponent) { continue }
                do {
                    let values = try child.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true {
                        errors.append("Skipped symbolic link: \(rel)")
                    } else if values.isDirectory == true {
                        folders.insert(rel)
                        pending.append((child, rel))
                    } else if values.isRegularFile == true {
                        guard let size = values.fileSize else {
                            errors.append("Cannot determine file size: \(rel)")
                            continue
                        }
                        files[rel] = CompareFile(size: Int64(size),
                                                 modified: values.contentModificationDate ?? .distantPast,
                                                 url: child)
                    } else {
                        errors.append("Unsupported file type: \(rel)")
                    }
                } catch {
                    errors.append("Cannot inspect \(rel): \(error.localizedDescription)")
                }
            }
        }
        if visitedDirectories == 0 { errors.append("No directories visited: \(root.path)") }
        return CompareSnapshot(root: root, files: files, folders: folders, errors: errors)
    }
    static func hash(_ url: URL, tracker: DeepVerifyTracker?) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open(); defer { stream.close() }
        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024 * 1024)
        defer { buffer.deallocate() }
        while true {
            if tracker?.isCancelled == true { return nil }
            let count = stream.read(buffer, maxLength: 1024 * 1024)
            if count < 0 { return nil }
            if count == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: count))
            tracker?.add(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func compare(_ snapshots: [CompareSnapshot], mode: CompareMode, tracker: DeepVerifyTracker? = nil) -> [CompareDifference] {
        guard !snapshots.isEmpty else { return [] }
        let allFiles = Set(snapshots.flatMap { $0.files.keys })
        let allFolders = Set(snapshots.flatMap { $0.folders }).subtracting([""])
        var rows: [CompareDifference] = []
        for path in allFiles.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if tracker?.isCancelled == true { return [] }
            let entries = snapshots.map { $0.files[path] }
            let missing = entries.contains { $0 == nil }
            var differs = false
            if !missing, let first = entries[0] {
                differs = entries.dropFirst().contains { entry in
                    guard let entry else { return true }
                    if entry.size != first.size { return true }
                    if mode == .standard && abs(entry.modified.timeIntervalSince(first.modified)) > 2 { return true }
                    return false
                }
                if mode == .deep && !differs {
                    let hashes = entries.compactMap { entry -> String? in
                        guard let entry else { return nil }
                        let digest = hash(entry.url, tracker: tracker)
                        tracker?.finishFile()
                        return digest
                    }
                    differs = hashes.count != entries.count || Set(hashes).count != 1
                }
            }
            let status = missing ? 2 : (differs ? 1 : 0)
            rows.append(CompareDifference(id: path, states: entries.map { $0 == nil ? "Missing" : (status == 1 ? "Different" : "Match") }, status: status, isFolder: false))
        }
        for folder in allFolders.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let missing = snapshots.contains { !$0.folders.contains(folder) }
            let child = rows.filter { $0.id.hasPrefix(folder + "/") }
            // An empty directory has no files to lose. Treat absent empty
            // directories as equivalent for content verification.
            let status = child.isEmpty ? (missing ? 2 : 0) : (missing ? 2 : (child.contains(where: { $0.status != 0 }) ? 1 : 0))
            rows.append(CompareDifference(id: folder, states: snapshots.map { $0.folders.contains(folder) ? (status == 0 ? "Match" : "Review") : "Missing" }, status: status, isFolder: true))
        }
        return rows.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

struct FolderCompareView: View {
    let sessionRoot: URL?
    let backupDestinations: [URL]
    let isActive: Bool
    // Version 20.9: false while a backup runs, so opening the tab does not
    // compete with the copy for the same drives.
    var autoRefreshAllowed: Bool = true
    @State private var linkedToDashboard = true
    @State private var roots: [URL] = []
    @State private var mode: CompareMode = .standard
    @State private var results: [CompareDifference] = []
    @State private var snapshots: [CompareSnapshot] = []
    @State private var expanded: Set<String> = []
    @State private var running = false
    @State private var verifyTracker: DeepVerifyTracker? = nil
    @State private var verifyProgress: Double = 0
    @State private var verifyDetails = ""
    @State private var scanPhase = false
    @State private var verifyETA = "Calculating…"
    @State private var verifyRunID = UUID()
    @State private var progress = "Drop folders into the comparison area or click Add Folder."
    @State private var differencesOnly = false
    @State private var excludeHidden = true
    @State private var draggingColumn: Int? = nil
    @State private var availableWidth: CGFloat = 1200
    private var columnWidth: CGFloat {
        // Reserve one visible drop target in addition to every loaded location.
        let count = max(2, roots.count + 1)
        return max(360, (availableWidth - CGFloat(count - 1) * 10 - 4) / CGFloat(count))
    }
    private var nameWidth: CGFloat { max(150, columnWidth - 168) }

    private var rowLookup: [String: CompareDifference] {
        Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
    }
    // Materialize rows only when the scan results, expansion or filter changes.
    // Never sort and split tens of thousands of paths during SwiftUI body updates.
    @State private var cachedVisibleRows: [CompareDifference] = []
    @State private var cachedSummary: (Int, Int, Int) = (0, 0, 0)
    // Version 20.10: per-column totals and "has children" are worked out once
    // per scan. Before, every redraw (each step of a window resize) re-added
    // every file size and searched every result for every visible row.
    @State private var cachedColumns: [ColumnTotals] = []
    @State private var cachedParentFolders: Set<String> = []
    private struct ColumnTotals {
        var files = 0
        var bytes: Int64 = 0
        var rootFiles = 0
        var rootBytes: Int64 = 0
    }
    private func columnTotals(_ index: Int) -> ColumnTotals {
        cachedColumns.indices.contains(index) ? cachedColumns[index] : ColumnTotals()
    }

    private func rebuildVisibleRows() {
        guard isActive else { return }
        let folders = expanded
        let onlyDifferences = differencesOnly
        cachedVisibleRows = results.filter { row in
            if onlyDifferences && row.status == 0 { return false }
            let parts = row.id.split(separator: "/")
            guard parts.count > 1 else { return true }
            var ancestor = ""
            for part in parts.dropLast() {
                ancestor = ancestor.isEmpty ? String(part) : ancestor + "/" + part
                if !folders.contains(ancestor) { return false }
            }
            return true
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func rebuildSummary() {
        var counts = (0, 0, 0)
        for row in results where !row.isFolder {
            switch row.status {
            case 0: counts.0 += 1
            case 1: counts.1 += 1
            case 2: counts.2 += 1
            default: break
            }
        }
        cachedSummary = counts

        var columns: [ColumnTotals] = []
        for snap in snapshots {
            var totals = ColumnTotals()
            for (path, file) in snap.files {
                totals.files += 1
                totals.bytes += file.size
                if !path.contains("/") {
                    totals.rootFiles += 1
                    totals.rootBytes += file.size
                }
            }
            columns.append(totals)
        }
        cachedColumns = columns

        var parents = Set<String>()
        for row in results {
            var path = Substring(row.id)
            while let slash = path.lastIndex(of: "/") {
                path = path[..<slash]
                if !parents.insert(String(path)).inserted { break }
            }
        }
        cachedParentFolders = parents
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: "square.on.square")
                    .font(.title2).foregroundStyle(DigiBrand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DigiBrand.toolName(7)).font(.title2.bold())
                    Text("Compare session folders and verify backup copies")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button("Add Folder…") { addFolders() }.disabled(running)
                Button("Refresh") { compare() }.disabled(running || roots.count < 2)
                Button("Export Report…") { export() }.disabled(results.isEmpty || running)
            }
            HStack(spacing: 14) {
                Text("Verification").font(.caption)
                HStack(spacing: 0) {
                    ForEach(CompareMode.allCases) { option in
                        Button {
                            guard mode != option else { return }
                            guard !running else { return }
                            verifyRunID = UUID()
                            verifyTracker?.cancel()
                            verifyTracker = nil
                            running = false
                            scanPhase = false
                            verifyProgress = 0
                            verifyDetails = ""
                            verifyETA = "Calculating…"
                            mode = option
                            // v1.15: choosing a mode runs it right away, Deep Verify included.
                            if roots.count < 2 {
                                progress = "Add at least two folders to compare."
                            } else if !autoRefreshAllowed {
                                progress = "A backup is running. Click Refresh to compare now, or wait until it finishes."
                            } else {
                                compare()
                            }
                        } label: {
                            Text(option.rawValue)
                                .font(.callout)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(mode == option ? DigiBrand.accent.opacity(0.28) : Color.clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(running)
                        .help(option.tooltip)
                    }
                }
                .frame(width: 290)
                .background(DigiBrand.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                Toggle("Differences only", isOn: $differencesOnly).toggleStyle(.checkbox)
                Spacer()
                Text(progress).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if running {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(mode.rawValue + " progress").font(.caption.bold())
                        Spacer()
                        Text(verifyETA).font(.caption.monospacedDigit())
                        if mode == .deep { Button("Cancel") { verifyTracker?.cancel() }.disabled(verifyTracker == nil) }
                    }
                    if mode != .deep || scanPhase { ProgressView() } else { ProgressView(value: verifyProgress) }
                    Text(verifyDetails).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(9)
                .background(DigiBrand.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            // Version 20.10: this tab stays loaded while hidden so its results
            // are kept, but the columns are only drawn while it is showing.
            if isActive {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(roots.indices, id: \.self) { index in
                                comparisonHeader(index)
                                    .frame(width: columnWidth)
                                    .onDrag { draggingColumn = index; return NSItemProvider(object: "digitools-column-\(index)" as NSString) }
                                    .onDrop(of: [UTType.plainText.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers in
                                        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                                            return acceptFolders(providers, replacing: index)
                                        }
                                        return reorder(providers, to: index)
                                    }
                            }
                        }
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(roots.indices, id: \.self) { index in
                                    comparisonRows(index)
                                        .frame(width: columnWidth)
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(roots.indices, id: \.self) { index in
                                comparisonFooter(index)
                                    .frame(width: columnWidth)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    addColumn
                }
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .onAppear { availableWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { newWidth in availableWidth = newWidth }
            }
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 22) {
                legend("Match", .green, "Checked values match")
                legend("Different", .yellow, "Size, date, or checksum differs")
                legend("Missing", .red, "Not present in a location")
                Spacer()
                if !results.isEmpty {
                    Text("\(cachedSummary.0) matching  ·  \(cachedSummary.1) different  ·  \(cachedSummary.2) missing")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            HStack {
                Toggle("Exclude hidden files", isOn: $excludeHidden)
                    .toggleStyle(.checkbox)
                    .help("Ignore dot-prefixed files and folders, including .DS_Store and .shootwrap-sync-manifest.json")
                    .disabled(running)
                    .onChange(of: excludeHidden) { _ in
                        progress = "Folders or settings changed. Click Refresh to compare."
                    }
                Spacer()
                Button(role: .destructive) {
                    roots = []; linkedToDashboard = false; results = []; snapshots = []; expanded = []
                    progress = "Cleared. Drop folders or click Add Folder to start again."
                } label: {
                    Label("Clear Comparison / Start New", systemImage: "arrow.counterclockwise")
                }
                .disabled(running || roots.isEmpty)
            }
        }
        .padding(14)
        .onAppear {
            reconcileLinkedFolders()
            if isActive { rebuildSummary(); rebuildVisibleRows(); autoRefresh() }
        }
        .onChange(of: isActive) { _, active in
            if active { reconcileLinkedFolders(); rebuildVisibleRows(); autoRefresh() }
        }
        .onChange(of: differencesOnly) { _ in rebuildVisibleRows() }
        .onChange(of: sessionRoot) { _ in reconcileLinkedFolders() }
        .onChange(of: backupDestinations.map(\.path)) { _ in reconcileLinkedFolders() }
        .task(id: sessionRoot?.standardizedFileURL.path) {
            // Reconcile the source when SwiftUI reconstructs the tab view.
            reconcileLinkedFolders()
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            acceptFolders(providers, replacing: nil)
        }
    }

    private var addColumn: some View {
        Button { addFolders() } label: {
            VStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").font(.system(size: 34))
                Text("Drop Folder Here").font(.headline).lineLimit(2).minimumScaleFactor(0.65)
                Text("or click to browse").font(.caption).lineLimit(2).minimumScaleFactor(0.65)
            }
            .foregroundStyle(.secondary)
            .frame(width: columnWidth)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { acceptFolders($0, replacing: nil) }
    }

    // Identical, fixed-height header structure across all locations.
    // The dashboard link occupies a reserved line on every card so it cannot
    // push the source card's table lower than the destination cards.
    private func comparisonHeader(_ index: Int) -> some View {
        let snap = snapshots.indices.contains(index) ? snapshots[index] : nil
        let totalBytes: Int64 = snap == nil ? 0 : columnTotals(index).bytes
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(index == 0 ? "SOURCE" : "LOCATION \(index + 1)")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Image(systemName: "line.3.horizontal")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button { remove(index) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).disabled(running)
                }
                HStack(spacing: 5) {
                    if index == 0 && linkedToDashboard && sessionRoot != nil {
                        Label("Linked to your session", systemImage: "link")
                    } else {
                        Label(index == 0 ? "Source folder" : "Backup location", systemImage: index == 0 ? "folder" : "externaldrive")
                    }
                    Spacer()
                }
                .font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(systemName: index == 0 ? "folder.fill" : "externaldrive.fill")
                        .font(.system(size: 23))
                        .foregroundStyle(index == 0 ? DigiBrand.accent : Color.secondary)
                        .frame(width: 37, height: 40)
                        .background(DigiBrand.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(roots[index].lastPathComponent)
                            .font(.headline).lineLimit(1).truncationMode(.middle)
                        Text(roots[index].path)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(roots[index].path)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    headerMetric("Files", value: snap.map { "\($0.files.count)" } ?? "—", symbol: "doc")
                    Divider().frame(height: 29)
                    headerMetric("Folders", value: snap.map { "\(max(0, $0.folders.count - 1))" } ?? "—", symbol: "folder")
                    Divider().frame(height: 29)
                    headerMetric("Size", value: snap.map { _ in bytes(totalBytes) } ?? "—", symbol: "internaldrive")
                }
                .frame(height: 48)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(12)
            .frame(height: 174, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DigiBrand.cardFill)
            HStack(spacing: 0) {
                Text("Subfolder / File").frame(width: nameWidth, alignment: .leading)
                Text("Subdirs").frame(width: 48, alignment: .trailing)
                Text("Files").frame(width: 43, alignment: .trailing)
                Text("Size").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2.bold()).foregroundStyle(.secondary)
            .padding(.horizontal, 9).frame(height: 34)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
        .frame(height: 209, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
    }

    private func headerMetric(_ label: String, value: String, symbol: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(DigiBrand.accent)
                Text(value).lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(.caption.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func comparisonRows(_ index: Int) -> some View {
                LazyVStack(spacing: 0) {
                    if snapshots.indices.contains(index) {
                        let totals = columnTotals(index)
                        HStack {
                            Text("Files (not in a subfolder)").italic().lineLimit(1)
                            Spacer()
                            Text("\(totals.rootFiles)").frame(width: 43, alignment: .trailing)
                            Text(bytes(totals.rootBytes))
                                .frame(width: 78, alignment: .trailing)
                        }
                        .font(.caption).padding(.horizontal, 9).frame(height: 31)
                        Divider()
                    }
                    ForEach(cachedVisibleRows) { row in
                        treeRow(row, index: index)
                        Divider().opacity(0.4)
                    }
                }
    }

    private func comparisonFooter(_ index: Int) -> some View {
        VStack(spacing: 0) {
            Divider()
            if snapshots.indices.contains(index) {
                let snap = snapshots[index]
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(snap.folders.count - 1) subfolders").font(.caption2).foregroundStyle(.secondary)
                        Text("Total").font(.caption.bold())
                    }
                    Spacer()
                    Text("\(snap.files.count)").font(.caption.bold()).monospacedDigit()
                    Text(bytes(columnTotals(index).bytes))
                        .font(.caption.bold()).monospacedDigit().frame(width: 90, alignment: .trailing)
                }
                .padding(10)
                .background(DigiBrand.cardFill)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
    }

    private func treeRow(_ row: CompareDifference, index: Int) -> some View {
        let snap = snapshots.indices.contains(index) ? snapshots[index] : nil
        let exists = row.isFolder ? (snap?.folders.contains(row.id) ?? false) : (snap?.files[row.id] != nil)
        let depth = row.id.split(separator: "/").count - 1
        let name = String(row.id.split(separator: "/").last ?? "")
        let status = statusFor(row, index: index)
        let children = row.isFolder && cachedParentFolders.contains(row.id)
        return HStack(spacing: 4) {
            HStack(spacing: 4) {
                if row.isFolder && children {
                    Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2).frame(width: 11)
                } else { Color.clear.frame(width: 11, height: 11) }
                Image(systemName: row.isFolder ? "folder.fill" : "doc")
                    .foregroundStyle(status == 0 ? (row.isFolder ? DigiBrand.accent : Color.secondary) : color(status))
                    .frame(width: 14)
                Text(name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(exists ? Color.primary : Color.secondary)
            }
            .padding(.leading, CGFloat(min(depth, 7)) * 11)
            .frame(width: nameWidth, alignment: .leading)
            if row.isFolder {
                Text(exists ? "\(directSubfolders(row.id, snap: snap))" : "—")
                    .frame(width: 48, alignment: .trailing)
                Text(exists ? "\(fileTotals(row.id, snap: snap).0)" : "—")
                    .frame(width: 43, alignment: .trailing)
                Text(exists ? bytes(fileTotals(row.id, snap: snap).1) : "—")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("—").frame(width: 48, alignment: .trailing)
                Text(exists ? "1" : "—").frame(width: 43, alignment: .trailing)
                Text(snap?.files[row.id].map { bytes($0.size) } ?? "—")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.caption).monospacedDigit()
        .padding(.horizontal, 9)
        .frame(height: 31)
        .background(status == 0 ? Color.clear : color(status).opacity(0.18))
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isFolder {
                if expanded.contains(row.id) { expanded.remove(row.id) }
                else { expanded.insert(row.id) }
                rebuildVisibleRows()
            }
        }
        .help(row.id + (exists ? "" : " (missing here)"))
    }

    private func directSubfolders(_ folder: String, snap: CompareSnapshot?) -> Int {
        guard let snap else { return 0 }
        return snap.folders.filter { path in
            let parent = (path as NSString).deletingLastPathComponent
            return path != folder && (parent == folder || (folder.isEmpty && !path.contains("/")))
        }.count
    }
    private func fileTotals(_ folder: String, snap: CompareSnapshot?) -> (Int, Int64) {
        guard let snap else { return (0, 0) }
        let files = snap.files.filter { $0.key.hasPrefix(folder + "/") }
        return (files.count, files.values.reduce(Int64(0)) { $0 + $1.size })
    }
    private func statusFor(_ row: CompareDifference, index: Int) -> Int {
        guard snapshots.indices.contains(index) else { return row.status }
        let exists = row.isFolder ? snapshots[index].folders.contains(row.id) : snapshots[index].files[row.id] != nil
        return exists ? (row.isFolder && row.status == 2 ? 1 : row.status) : 2
    }
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return formatter
    }()
    private func bytes(_ size: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: size)
    }
    private func color(_ status: Int) -> Color {
        status == 0 ? .green : (status == 1 ? .yellow : .red)
    }
    private func legend(_ name: String, _ color: Color, _ description: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name).font(.caption.bold())
            Text(description).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func acceptFolders(_ providers: [NSItemProvider], replacing index: Int?) -> Bool {
        let valid = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !valid.isEmpty && !running else { return false }
        for (position, provider) in valid.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return }
                DispatchQueue.main.async {
                    if let index, position == 0, roots.indices.contains(index) {
                        roots[index] = url
                        if index == 0 { linkedToDashboard = false }
                    }
                    else if !roots.contains(url) { roots.append(url) }
                    results = []; snapshots = []
                    progress = "Folders or settings changed. Click Refresh to compare."
                }
            }
        }
        return true
    }
    private func reorder(_ providers: [NSItemProvider], to destination: Int) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let value: String?
            if let data = item as? Data { value = String(data: data, encoding: .utf8) }
            else { value = item as? String }
            guard let value, value.hasPrefix("digitools-column-"),
                  let source = Int(value.replacingOccurrences(of: "digitools-column-", with: "")) else { return }
            DispatchQueue.main.async {
                guard roots.indices.contains(source), roots.indices.contains(destination), source != destination else { return }
                let url = roots.remove(at: source)
                roots.insert(url, at: destination)
                progress = "Folders or settings changed. Click Refresh to compare."
            }
        }
        return true
    }
    @State private var lastLinkedBackupPaths: [String] = []

    private func reconcileLinkedFolders() {
        // The Dashboard session owns Folder 1. Backup destinations fill the next
        // columns, while unrelated manually added folders remain available.
        let oldLinked = Set(lastLinkedBackupPaths)
        let destinationURLs = backupDestinations.map { $0.standardizedFileURL }
        let desiredPaths = destinationURLs.map(\.path)
        var next = roots.filter { !oldLinked.contains($0.standardizedFileURL.path) }
        if let sessionRoot {
            let source = sessionRoot.standardizedFileURL
            if linkedToDashboard {
                next.removeAll { $0.standardizedFileURL == source }
                if !next.isEmpty, let oldSource = roots.first,
                   !oldLinked.contains(oldSource.standardizedFileURL.path),
                   oldSource.standardizedFileURL != source {
                    // Replace a previous linked source, not a manually chosen folder.
                    if roots.first?.standardizedFileURL == oldSource.standardizedFileURL {
                        next.removeAll { $0.standardizedFileURL == oldSource.standardizedFileURL }
                    }
                }
                next.insert(source, at: 0)
            }
        }
        let insertion = linkedToDashboard && sessionRoot != nil ? 1 : 0
        for (offset, url) in destinationURLs.enumerated() {
            if !next.contains(where: { $0.standardizedFileURL == url }) {
                next.insert(url, at: min(insertion + offset, next.count))
            }
        }
        lastLinkedBackupPaths = desiredPaths
        guard next.map({ $0.standardizedFileURL.path }) != roots.map({ $0.standardizedFileURL.path }) else { return }
        roots = next
        results = []; snapshots = []; expanded = []
        progress = "Your session and backup drives are linked. Click Refresh to compare."
        // Folder changes never start an implicit filesystem scan.
    }
    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folders"
        if panel.runModal() == .OK {
            for url in panel.urls where !roots.contains(url) { roots.append(url) }
            results = []; snapshots = []
            progress = "Folders or settings changed. Click Refresh to compare."
        }
    }
    private func remove(_ index: Int) {
        roots.remove(at: index)
        if index == 0 { linkedToDashboard = false }
        results = []; snapshots = []; expanded = []
        progress = "Locations changed. Add at least two folders to compare."
        progress = "Folders or settings changed. Click Refresh to compare."
    }
    /// Version 20.9: scan when the tab is opened. Nothing runs in the
    /// background on other tabs. Deep Verify reads every byte, so it still
    /// waits for Refresh.
    private func autoRefresh() {
        guard isActive, !running, roots.count >= 2 else { return }
        if !autoRefreshAllowed {
            progress = "A backup is running. Click Refresh to compare now, or wait until it finishes."
            return
        }
        if mode == .deep {
            progress = "Deep Verify reads every file and can take a while. Click Refresh to start it."
            return
        }
        compare()
    }

    private func compare() {
        guard roots.count >= 2, !running else { return }
        let selected = roots, selectedMode = mode, selectedExcludeHidden = excludeHidden
        let runID = UUID()
        verifyRunID = runID
        running = true
        // Keep the last completed results visible until the new scan finishes.
        verifyProgress = 0; verifyDetails = "Scanning folders…"; verifyETA = "Calculating…"
        verifyTracker = nil
        scanPhase = true
        progress = "Scanning \(selected.count) locations…"
        Task.detached(priority: .userInitiated) {
            let scanStart = Date()
            var scans: [CompareSnapshot] = []
            for (index, root) in selected.enumerated() {
                scans.append(CompareScanner.scan(root, excludeHidden: selectedExcludeHidden))
                let elapsed = Date().timeIntervalSince(scanStart)
                let completed = index + 1
                await MainActor.run {
                    guard verifyRunID == runID else { return }
                    verifyDetails = "\(completed) / \(selected.count) locations inventoried · elapsed \(Int(elapsed) / 60)m \(Int(elapsed) % 60)s"
                    if elapsed >= 2 && completed < selected.count {
                        let remaining = Int(ceil(elapsed / Double(completed) * Double(selected.count - completed)))
                        verifyETA = "About \(remaining / 60)m \(remaining % 60)s remaining"
                    }
                }
            }
            await MainActor.run {
                guard verifyRunID == runID else { return }
                scanPhase = false
                verifyETA = selectedMode == .deep ? "Calculating…" : "Comparing…"
                verifyDetails = "Inventoried \(selected.count) locations · elapsed \(Int(Date().timeIntervalSince(scanStart)) / 60)m \(Int(Date().timeIntervalSince(scanStart)) % 60)s"
            }
            let tracker: DeepVerifyTracker?
            if selectedMode == .deep {
                // Only equal-sized, present files are hashed by the compare engine.
                let paths = Set(scans.flatMap { $0.files.keys })
                var bytes: Int64 = 0
                var count = 0
                for path in paths {
                    let entries = scans.compactMap { $0.files[path] }
                    if entries.count == scans.count, let first = entries.first,
                       entries.allSatisfy({ $0.size == first.size }) {
                        for entry in entries { bytes += entry.size; count += 1 }
                    }
                }
                tracker = DeepVerifyTracker(totalBytes: bytes, totalFiles: count)
                await MainActor.run { if verifyRunID == runID { verifyTracker = tracker } }
            } else { tracker = nil }
            // Sample every 0.5s, with ETA calculated from throughput after 15s.
            // The sampler ends when comparison completes or is cancelled.
            let done = DeepVerifyTracker(totalBytes: 0, totalFiles: 0)
            if let tracker {
                Task.detached {
                    while !done.isCancelled && !tracker.isCancelled {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if done.isCancelled || tracker.isCancelled { break }
                        let (bytes, files, elapsed) = tracker.snapshot()
                        let fraction = tracker.totalBytes > 0 ? min(1, Double(bytes) / Double(tracker.totalBytes)) : 0
                        let rate = elapsed > 0 ? Double(bytes) / elapsed : 0
                        let remaining = max(0, tracker.totalBytes - bytes)
                        let eta: String
                        if elapsed < 15 || bytes == 0 || rate <= 0 { eta = "Calculating…" }
                        else {
                            let seconds = Int(ceil(Double(remaining) / rate))
                            eta = "About \(seconds / 60)m \(seconds % 60)s remaining"
                        }
                        let details = "\(files.formatted()) / \(tracker.totalFiles.formatted()) files · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: tracker.totalBytes, countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file))/s · elapsed \(Int(elapsed) / 60)m \(Int(elapsed) % 60)s"
                        await MainActor.run {
                            if verifyRunID == runID {
                                verifyProgress = fraction; verifyDetails = details; verifyETA = eta
                            }
                        }
                    }
                }
            }
            let output = CompareScanner.compare(scans, mode: selectedMode, tracker: tracker)
            done.cancel()
            let wasCancelled = tracker?.isCancelled == true
            // Freeze the completed scan results before crossing the actor boundary.
            // Swift 6 disallows capturing a mutable local in a concurrently executing closure.
            let completedScans = scans
            let errors = completedScans.flatMap { $0.errors }
            await MainActor.run {
                guard verifyRunID == runID else { return }
                verifyTracker = nil
                running = false
                if wasCancelled {
                    progress = "Deep Verify cancelled. No partial comparison results shown."
                    return
                }
                snapshots = completedScans; results = output
                expanded = []
                rebuildSummary()
                rebuildVisibleRows()
                let sourceCapture = completedScans.first.map { snapshot -> String in
                    let capture = snapshot.files.filter { $0.key.hasPrefix("Capture/") }
                    let bytes = capture.values.reduce(Int64(0)) { $0 + $1.size }
                    return "Source Capture: \(capture.count) files, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
                } ?? "No source"
                progress = sourceCapture + " · \(output.filter { !$0.isFolder }.count) unique files" +
                    (errors.isEmpty ? "" : " · ⚠️ \(errors.count) scan warnings (see report)")
            }
        }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Folder_Compare_Differences.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["DigiTools Folder Compare", "Mode: \(mode.rawValue)", "Exclude hidden files: \(excludeHidden ? "Yes" : "No")", "Date: \(Date())", ""]
        for (i, root) in roots.enumerated() { lines.append("Location \(i + 1): \(root.path)") }
        lines.append("")
        lines.append("SCAN COVERAGE")
        for snapshot in snapshots {
            let totalBytes = snapshot.files.values.reduce(Int64(0)) { $0 + $1.size }
            lines.append("\(snapshot.root.path): \(snapshot.files.count) files, \(totalBytes) logical bytes, \(snapshot.errors.count) warnings")
            let captureFiles = snapshot.files.filter { $0.key.hasPrefix("Capture/") }
            lines.append("  Capture: \(captureFiles.count) files, \(captureFiles.values.reduce(Int64(0)) { $0 + $1.size }) logical bytes")
            let captureGroups = Dictionary(grouping: captureFiles.keys, by: { path -> String in
                let parts = path.split(separator: "/")
                return parts.count > 2 ? String(parts[1]) : "(Capture root)"
            })
            for group in captureGroups.keys.sorted() {
                let paths = captureGroups[group] ?? []
                let groupBytes = paths.reduce(Int64(0)) { $0 + (snapshot.files[$1]?.size ?? 0) }
                lines.append("    \(group): \(paths.count) files, \(groupBytes) bytes")
            }
            for error in snapshot.errors { lines.append("WARNING: \(error)") }
        }
        lines.append("")
        for row in results where row.status != 0 {
            lines.append("\(row.isFolder ? "FOLDER" : "FILE") | \(row.status == 2 ? "MISSING" : "DIFFERENT") | \(row.id) | \(row.states.joined(separator: " | "))")
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            progress = "Exported \(url.lastPathComponent)"
        } catch { progress = "Export failed: \(error.localizedDescription)" }
    }
}
