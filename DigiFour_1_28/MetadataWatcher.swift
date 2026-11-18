import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

struct MetadataPreset: Codable, Identifiable {
    var id = UUID()
    var name = "New Preset"
    var values: [String: String] = [:]
}

struct MetadataEvent: Identifiable {
    let id = UUID()
    let message: String
    let success: Bool
    let time = Date()
}

private enum MetadataFields {
    static let sections: [(String, [(String, String)])] = [
        ("IPTC Contact", [("Creator", "XMP-photoshop:AuthorsPosition"), ("Creator Name", "XMP-dc:Creator"), ("Address", "XMP-iptcCore:CreatorAddress"), ("City", "XMP-iptcCore:CreatorCity"), ("State/Province", "XMP-iptcCore:CreatorRegion"), ("Postal Code", "XMP-iptcCore:CreatorPostalCode"), ("Country", "XMP-iptcCore:CreatorCountry"), ("Phone", "XMP-iptcCore:CreatorWorkTelephone"), ("Email", "XMP-iptcCore:CreatorWorkEmail"), ("Website", "XMP-iptcCore:CreatorWorkURL")]),
        ("IPTC Content", [("Headline", "XMP-photoshop:Headline"), ("Description", "XMP-dc:Description"), ("Category", "XMP-photoshop:Category"), ("Supplemental Categories", "XMP-photoshop:SupplementalCategories"), ("Subject Code", "XMP-iptcCore:SubjectCode"), ("Description Writer", "XMP-photoshop:CaptionWriter"), ("Keywords", "XMP-dc:Subject")]),
        ("IPTC Image", [("Intellectual Genre", "XMP-iptcCore:IntellectualGenre"), ("Scene", "XMP-iptcCore:Scene"), ("Location", "XMP-iptcCore:Location"), ("City", "XMP-photoshop:City"), ("State/Province", "XMP-photoshop:State"), ("Country", "XMP-photoshop:Country"), ("ISO Country Code", "XMP-iptcCore:CountryCode")]),
        ("IPTC Status", [("Title", "XMP-dc:Title"), ("Job Identifier", "XMP-photoshop:TransmissionReference"), ("Instructions", "XMP-photoshop:Instructions"), ("Provider", "XMP-photoshop:Credit"), ("Source", "XMP-photoshop:Source"), ("Copyright Notice", "XMP-dc:Rights"), ("Rights Usage Terms", "XMP-xmpRights:UsageTerms")]),
        ("Getty / Additional", [("Personality", "XMP-iptcExt:PersonInImage"), ("Original Filename", "XMP-photoshop:DocumentAncestors")])
    ]
    static var all: [(String, String)] { sections.flatMap { $0.1 } }
}

/// One watcher for the whole app (v1.4), so it keeps running when you switch
/// tabs and the menu bar can show and stop it.
@MainActor final class MetadataWatcherModel: ObservableObject {
    static let shared = MetadataWatcherModel()
    private var timer: Timer?
    @Published var folder: URL?
    @Published var watching = false
    @Published var recursive = true
    @Published var processExisting = true
    @Published var fillEmptyOnly = true
    @Published var allowRaw = false
    @Published var preset = MetadataPreset()
    @Published var presets: [MetadataPreset] = []
    @Published var events: [MetadataEvent] = []
    @Published var processed = 0
    @Published var failed = 0
    @Published var pending = 0
    @Published var busy = false
    @Published var status = "Choose a folder and start watching."
    private var seen: [String: String] = [:]
    private var scanning = false
    private let supported = Set(["jpg", "jpeg", "tif", "tiff", "png", "psd", "dng", "cr2", "cr3", "nef", "arw", "raf", "iiq", "eip", "3fr", "orf", "rw2", "pef", "srw", "raw", "mos", "fff"])
    private let rawTypes = Set(["dng", "cr2", "cr3", "nef", "arw", "raf", "iiq", "eip", "3fr", "orf", "rw2", "pef", "srw", "raw", "mos", "fff"])
    private var stateURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DigiTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metadata-presets.json")
    }
    init() { if let data = try? Data(contentsOf: stateURL), let list = try? JSONDecoder().decode([MetadataPreset].self, from: data) { presets = list } }
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { folder = panel.url; stop(); seen.removeAll() }
    }
    func savePreset() {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = preset } else { presets.append(preset) }
        persist()
    }
    func selectPreset(_ id: UUID) { if let p = presets.first(where: { $0.id == id }) { preset = p } }
    func deletePreset() { presets.removeAll { $0.id == preset.id }; persist(); preset = MetadataPreset() }
    private func persist() { if let data = try? JSONEncoder().encode(presets) { try? data.write(to: stateURL, options: .atomic) } }
    func stop() {
        watching = false
        timer?.invalidate()
        timer = nil
        status = "Stopped"
    }
    func start() {
        guard folder != nil else { status = "Choose a watched folder first."; return }
        guard executable() != nil else { status = "ExifTool not found. Install it from exiftool.org or with Homebrew."; return }
        guard preset.values.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { status = "Enter at least one metadata field."; return }
        seen.removeAll(); processed = 0; failed = 0; pending = 0; events = []
        if !processExisting { for url in files() { seen[url.path] = signature(url) } }
        watching = true; status = "Watching for incoming images"
        timer?.invalidate()
        // The timer runs on the main thread, where the watcher lives.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { MetadataWatcherModel.shared.tick() }
        }
        tick()
    }
    private func executable() -> String? {
        for path in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
    private func files() -> [URL] {
        guard let folder else { return [] }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey]
        if recursive {
            guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            return en.compactMap { $0 as? URL }.filter { url in
                supported.contains(url.pathExtension.lowercased()) && ((try? url.resourceValues(forKeys: keys).isRegularFile) ?? false)
            }
        }
        return ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []).filter { supported.contains($0.pathExtension.lowercased()) && ((try? $0.resourceValues(forKeys: keys).isRegularFile) ?? false) }
    }
    private func signature(_ url: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\(a?[.size] ?? 0)|\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    func tick() {
        guard watching, !scanning, let tool = executable() else { return }
        scanning = true
        let candidates = files().filter { seen[$0.path] != signature($0) }
        pending = candidates.count
        guard let url = candidates.first else { scanning = false; return }
        // Wait for a stable file across two polls, so we never edit a file still arriving.
        let before = signature(url)
        let path = url.path
        let presetValues = preset.values
        let onlyEmpty = fillEmptyOnly
        let rawAllowed = allowRaw
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let after = "\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            if before != after { await MainActor.run { self.scanning = false }; return }
            let result = Self.embed(path: path, tool: tool, values: presetValues, fillOnly: onlyEmpty, rawAllowed: rawAllowed)
            await MainActor.run {
                self.seen[path] = self.signature(url)
                if result.0 { self.processed += 1 } else { self.failed += 1 }
                self.events.insert(MetadataEvent(message: "\(url.lastPathComponent): \(result.1)", success: result.0), at: 0)
                if self.events.count > 120 { self.events.removeLast() }
                self.status = result.1
                self.scanning = false
            }
        }
    }
    nonisolated private static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let task = Process(); task.executableURL = URL(fileURLWithPath: tool); task.arguments = args
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        do { try task.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit(); return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "") }
        catch { return (1, error.localizedDescription) }
    }
    nonisolated private static func embed(path: String, tool: String, values: [String: String], fillOnly: Bool, rawAllowed: Bool) -> (Bool, String) {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let raw = Set(["dng", "cr2", "cr3", "nef", "arw", "raf", "iiq", "eip", "3fr", "orf", "rw2", "pef", "srw", "raw", "mos", "fff"])
        if raw.contains(ext) && !rawAllowed { return (false, "RAW embedding disabled. Enable experimental RAW writes to try this format.") }
        let fields = values.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if fields.isEmpty { return (false, "No enabled metadata fields") }
        var args: [String] = []
        for (tag, text) in fields.sorted(by: { $0.key < $1.key }) {
            let value = text.replacingOccurrences(of: "{year}", with: String(Calendar.current.component(.year, from: Date())))
            if fillOnly {
                let (code, existing) = run(tool, ["-s3", "-\(tag)", path])
                if code == 0 && !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            }
            args.append("-\(tag)=\(value)")
        }
        if args.isEmpty { return (true, "Already populated, no changes needed") }
        // ExifTool's normal write mode retains a *_original backup. Never overwrite it.
        let (code, output) = run(tool, ["-P"] + args + [path])
        if code != 0 { return (false, "Write failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        for (tag, text) in fields {
            let wanted = text.replacingOccurrences(of: "{year}", with: String(Calendar.current.component(.year, from: Date())))
            let (_, readback) = run(tool, ["-s3", "-\(tag)", path])
            if !fillOnly && !readback.contains(wanted) { return (false, "Read-back verification failed for \(tag)") }
        }
        return (true, "Embedded and verified")
    }
}

struct MetadataWatcherView: View {
    @ObservedObject private var model = MetadataWatcherModel.shared
    @State private var selectedSection = "IPTC Contact"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(DigiBrand.isClassic ? "Metadata Watcher" : DigiBrand.toolName(8)).font(.title2.bold())
                    Text("Embed IPTC/XMP metadata automatically as images arrive.").foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.watching ? "Watching" : "Stopped", systemImage: model.watching ? "circle.fill" : "pause.circle")
                    .foregroundStyle(model.watching ? .green : .secondary)
            }
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.gearshape").font(.system(size: 35)).foregroundStyle(.secondary)
                Text(model.folder?.lastPathComponent ?? "Drop a folder to watch").font(.headline)
                if let folder = model.folder { Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Button("Browse…") { model.choose() }.disabled(model.watching)
            }
            .frame(maxWidth: .infinity, minHeight: 145)
            .background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                guard !model.watching, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var dir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue else { return }
                    DispatchQueue.main.async { model.folder = url }
                }
                return true
            }
            HStack {
                Toggle("Include subfolders", isOn: $model.recursive)
                Toggle("Process existing images", isOn: $model.processExisting)
                Spacer()
            }
            .disabled(model.watching)
            Divider()
            HStack {
                Text("Metadata Preset").font(.headline)
                TextField("Preset name", text: $model.preset.name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Menu("Load Preset") {
                    ForEach(model.presets) { p in Button(p.name) { model.selectPreset(p.id) } }
                }
                Button("Save Preset") { model.savePreset() }
                Button("New") { model.preset = MetadataPreset() }
                Spacer()
            }
            .disabled(model.watching)
            Picker("Fields", selection: $selectedSection) {
                ForEach(MetadataFields.sections, id: \.0) { section in Text(section.0).tag(section.0) }
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(MetadataFields.sections.first(where: { $0.0 == selectedSection })?.1 ?? [], id: \.1) { field in
                    HStack {
                        Text(field.0).frame(width: 180, alignment: .leading)
                        TextField("Leave unchanged", text: Binding(get: { model.preset.values[field.1] ?? "" }, set: { model.preset.values[field.1] = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(12).background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 10))
            .disabled(model.watching)
            Divider()
            Toggle("Only fill empty fields (preserve existing values)", isOn: $model.fillEmptyOnly).disabled(model.watching)
            Toggle("Experimental: attempt embedded writes to proprietary RAW files", isOn: $model.allowRaw).disabled(model.watching)
            Text("RAW writing varies by format. Unsupported writes are reported as failures. ExifTool retains an *_original backup of modified files. Test with copies before using on a live shoot.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(model.watching ? "Stop Watching" : "Start Watching") { model.watching ? model.stop() : model.start() }
                    .buttonStyle(.borderedProminent)
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Text("\(model.processed) verified · \(model.failed) failed · \(model.pending) pending").font(.caption).monospacedDigit()
            }
            if !model.events.isEmpty {
                Text("Activity").font(.headline)
                ForEach(model.events.prefix(15)) { event in
                    HStack {
                        Image(systemName: event.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(event.success ? .green : .orange)
                        Text(event.message).font(.caption).lineLimit(2)
                        Spacer()
                        Text(event.time, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

    }
}
