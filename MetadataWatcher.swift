import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// v1.42: the Metadata tab writes IPTC info to a sidecar .xmp next to each raw (see
// MetadataSidecar.swift). The raw is never written and no *_original copies are left.
// Capture One loads the sidecar itself (Auto Sync Sidecar XMP = Load).

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

enum MetadataFolderMode: String {
    case session
    case chosen
}

/// One watcher for the whole app (v1.4), so it keeps running when you switch tabs
/// and the menu bar can show and stop it.
@MainActor final class MetadataWatcherModel: ObservableObject {
    static let shared = MetadataWatcherModel()

    private static let modeKey = "DigiSuite.metadata.folderMode"
    private static let chosenKey = "DigiSuite.metadata.chosenFolder"
    private static let recursiveKey = "DigiSuite.metadata.recursive"
    private static let keepKey = "DigiSuite.metadata.keepExisting"
    private static let watchingKey = "DigiSuite.metadata.watching"
    private static let embedKey = "DigiSuite.metadata.embedImages"
    static let presetFileKey = "DigiSuite.metadata.currentPresetFile"

    @Published var mode: MetadataFolderMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey); folderChanged() }
    }
    @Published var chosenFolder: URL? {
        didSet { UserDefaults.standard.set(chosenFolder?.path, forKey: Self.chosenKey); folderChanged() }
    }
    @Published var recursive: Bool {
        didSet { UserDefaults.standard.set(recursive, forKey: Self.recursiveKey); folderChanged() }
    }
    @Published var keepExisting: Bool {
        didSet { UserDefaults.standard.set(keepExisting, forKey: Self.keepKey) }
    }
    /// v1.44: also write into JPEG/TIFF/PNG files (inside the file). Off by default.
    @Published var embedImages: Bool {
        didSet { UserDefaults.standard.set(embedImages, forKey: Self.embedKey); folderChanged() }
    }
    @Published var watching = false
    /// The form: a name and the field values. Saved as an .xmp in the presets folder.
    @Published var preset = MetadataPreset()
    @Published var presetFiles: [URL] = []
    @Published var currentPresetFile: URL?
    /// The folder the newest stamped frame was in (relative to the watched folder).
    @Published var lastLanding: String?
    /// The folder the newest stamped frame was in (Capture One's current capture folder).
    @Published var lastLandingFolder: URL?
    /// v1.43.5: Capture One's own capture folder, asked every few seconds (session mode).
    @Published var captureOneFolder: URL?
    private var lastCaptureOneCheck = Date.distantPast
    private var captureOneChecking = false
    @Published var events: [MetadataEvent] = []
    @Published var stamped = 0
    @Published var kept = 0
    @Published var failed = 0
    @Published var status = "Fill in your fields, then start watching."
    @Published var loadNote: String?
    @Published var loadNoteIsError = false
    /// Raws in the folder without a sidecar yet; nil until counted.
    @Published var withoutSidecar: Int?
    @Published var applying = false
    @Published var applyProgress = ""

    private var timer: Timer?
    private var known: [String: String] = [:]
    private var waiting: [String: String] = [:]
    private var scanning = false
    private var lastFolderPath: String?

    private var stateURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DigiTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metadata-presets.json")
    }

    init() {
        let defaults = UserDefaults.standard
        mode = MetadataFolderMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .session
        if let path = defaults.string(forKey: Self.chosenKey) {
            chosenFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            chosenFolder = nil
        }
        recursive = defaults.object(forKey: Self.recursiveKey) as? Bool ?? true
        keepExisting = defaults.object(forKey: Self.keepKey) as? Bool ?? true
        embedImages = defaults.bool(forKey: Self.embedKey)
        // v1.43: watching never starts by itself; the person starts it on the tab.
        defaults.set(false, forKey: Self.watchingKey)
        presetFiles = MetadataSidecar.presetFiles()
        let lastPath: String? = defaults.string(forKey: Self.presetFileKey)
        DispatchQueue.main.async {
            let model = MetadataWatcherModel.shared
            model.migrateOldPresets()
            if let lastPath, FileManager.default.fileExists(atPath: lastPath) {
                model.selectPresetFile(URL(fileURLWithPath: lastPath))
            }
        }
    }

    /// Before 1.42 the field labelled "Creator" wrote the creator's job title tag.
    nonisolated static func migrated(_ old: MetadataPreset) -> MetadataPreset {
        var preset = old
        let creator: String = (preset.values["XMP-dc:Creator"] ?? "").trimmingCharacters(in: .whitespaces)
        let title: String = (preset.values["XMP-photoshop:AuthorsPosition"] ?? "").trimmingCharacters(in: .whitespaces)
        if creator.isEmpty && !title.isEmpty {
            preset.values["XMP-dc:Creator"] = title
            preset.values["XMP-photoshop:AuthorsPosition"] = nil
        }
        return preset
    }

    // MARK: Folder

    var sessionCaptureFolder: URL? {
        let model = DigiPrimaryModel.shared
        if let capture = model.qcCaptureFolder { return capture }
        if let root = model.root { return root.appendingPathComponent("Capture", isDirectory: true) }
        return nil
    }

    var folder: URL? { mode == .chosen ? chosenFolder : sessionCaptureFolder }

    private func folderChanged() {
        lastFolderPath = nil
        lastLanding = nil
        lastLandingFolder = nil
        withoutSidecar = nil
        refreshCount()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            chosenFolder = url
            mode = .chosen
        }
    }

    // MARK: Presets

    var hasValues: Bool {
        preset.values.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func binding(_ tag: String) -> Binding<String> {
        Binding(get: { self.preset.values[tag] ?? "" }, set: { self.preset.values[tag] = $0 })
    }

    func refreshPresetFiles() {
        presetFiles = MetadataSidecar.presetFiles()
    }

    /// Opens a saved preset: the form becomes exactly what the file holds.
    func selectPresetFile(_ url: URL) {
        guard let tool = MetadataSidecar.exiftoolPath() else {
            loadNoteIsError = true
            loadNote = "ExifTool isn't installed, so presets can't be read. Get it free at exiftool.org (or: brew install exiftool)."
            return
        }
        Task.detached(priority: .userInitiated) {
            let result = MetadataSidecar.loadClient(url, tool: tool)
            await MainActor.run {
                let model = MetadataWatcherModel.shared
                var loaded = MetadataPreset()
                loaded.name = url.deletingPathExtension().lastPathComponent
                loaded.values = result.values
                model.preset = loaded
                model.currentPresetFile = url
                model.loadNote = nil
                UserDefaults.standard.set(url.path, forKey: MetadataWatcherModel.presetFileKey)
                model.loadNoteIsError = false
                model.loadNote = "Preset “" + loaded.name + "” loaded."
            }
        }
    }

    func newPreset() {
        preset = MetadataPreset()
        currentPresetFile = nil
        loadNote = nil
        UserDefaults.standard.removeObject(forKey: Self.presetFileKey)
    }

    func savePreset() {
        let name: String = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: URL = MetadataSidecar.presetsFolder.appendingPathComponent(MetadataSidecar.presetFileName(name))
        let previous: URL? = currentPresetFile
        let renaming: Bool = previous != nil && previous?.standardizedFileURL != target.standardizedFileURL
        if (previous == nil || renaming) && FileManager.default.fileExists(atPath: target.path) {
            guard confirmReplace(target) else { return }
        }
        writePreset(to: target, removing: renaming ? previous : nil)
    }

    func saveAsNew() {
        let alert = NSAlert()
        alert.messageText = "Name this preset"
        alert.informativeText = "For example the client or the job. It's saved as an .xmp in Documents › Studio Session › Metadata Presets."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = preset.name == "New Preset" ? "" : preset.name + " copy"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var name: String = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "New Preset" }
        let target: URL = MetadataSidecar.presetsFolder.appendingPathComponent(MetadataSidecar.presetFileName(name))
        if FileManager.default.fileExists(atPath: target.path) {
            guard confirmReplace(target) else { return }
        }
        preset.name = name
        writePreset(to: target, removing: nil)
    }

    private func confirmReplace(_ target: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace the preset “" + target.deletingPathExtension().lastPathComponent + "”?"
        alert.informativeText = "A preset with this name already exists."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func writePreset(to target: URL, removing old: URL?) {
        guard let tool = MetadataSidecar.exiftoolPath() else {
            loadNoteIsError = true
            loadNote = "ExifTool isn't installed, so the preset can't be saved. Get it free at exiftool.org (or: brew install exiftool)."
            return
        }
        let values: [String: String] = preset.values
        let name: String = target.deletingPathExtension().lastPathComponent
        Task.detached(priority: .userInitiated) {
            let error: String? = MetadataSidecar.writePreset(values, to: target, tool: tool)
            if error == nil, let old { try? FileManager.default.trashItem(at: old, resultingItemURL: nil) }
            await MainActor.run {
                let model = MetadataWatcherModel.shared
                if let error {
                    model.loadNoteIsError = true
                    model.loadNote = error
                    return
                }
                model.preset.name = name
                model.currentPresetFile = target
                UserDefaults.standard.set(target.path, forKey: MetadataWatcherModel.presetFileKey)
                model.refreshPresetFiles()
                model.loadNoteIsError = false
                model.loadNote = "Saved “" + name + "” to Metadata Presets."
            }
        }
    }

    func deletePreset() {
        guard let file = currentPresetFile else {
            newPreset()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move the preset “" + file.deletingPathExtension().lastPathComponent + "” to the Trash?"
        alert.informativeText = "Sidecars already written aren't changed. You can get it back from the Trash."
        alert.addButton(withTitle: "Cancel")
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        } catch {
            loadNoteIsError = true
            loadNote = "Couldn't move it to the Trash: " + error.localizedDescription
            return
        }
        refreshPresetFiles()
        newPreset()
    }

    func showPresetsFolder() {
        let folder: URL = MetadataSidecar.presetsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file = currentPresetFile, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    /// Presets saved by 1.42 (a JSON list) become .xmp files, once.
    func migrateOldPresets() {
        guard let data = try? Data(contentsOf: stateURL),
              let list = try? JSONDecoder().decode([MetadataPreset].self, from: data),
              !list.isEmpty,
              let tool = MetadataSidecar.exiftoolPath() else { return }
        let source: URL = stateURL
        Task.detached(priority: .utility) {
            for old in list {
                let preset = MetadataWatcherModel.migrated(old)
                let target: URL = MetadataSidecar.presetsFolder.appendingPathComponent(MetadataSidecar.presetFileName(preset.name))
                if FileManager.default.fileExists(atPath: target.path) { continue }
                _ = MetadataSidecar.writePreset(preset.values, to: target, tool: tool)
            }
            let done: URL = source.deletingLastPathComponent().appendingPathComponent("metadata-presets (moved to xmp).json")
            try? FileManager.default.moveItem(at: source, to: done)
            await MainActor.run { MetadataWatcherModel.shared.refreshPresetFiles() }
        }
    }

    // MARK: Client .xmp

    func chooseClientXMP() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "xmp") { panel.allowedContentTypes = [type] }
        panel.prompt = "Load"
        if panel.runModal() == .OK, let url = panel.url { loadClientXMP(url) }
    }

    func loadClientXMP(_ url: URL) {
        guard let tool = MetadataSidecar.exiftoolPath() else {
            loadNoteIsError = true
            loadNote = "ExifTool isn't installed, so the file can't be read. Get it free at exiftool.org (or: brew install exiftool)."
            return
        }
        loadNoteIsError = false
        loadNote = "Reading " + url.lastPathComponent + "…"
        Task.detached(priority: .userInitiated) {
            let result = MetadataSidecar.loadClient(url, tool: tool)
            await MainActor.run {
                let model = MetadataWatcherModel.shared
                if let error = result.error {
                    model.loadNoteIsError = true
                    model.loadNote = url.lastPathComponent + ": " + error
                    return
                }
                for (tag, value) in result.values { model.preset.values[tag] = value }
                let count: Int = result.values.count
                var note: String = "Loaded from " + url.lastPathComponent + ": " + (count == 1 ? "1 field" : "\(count) fields") + " filled in below (fields not in the file were left as they were). Check them, then Save to keep them in a preset."
                if result.otherFields > 0 {
                    note += " " + (result.otherFields == 1 ? "1 other field" : "\(result.otherFields) other fields") + " in the file aren't used here."
                }
                model.loadNoteIsError = false
                model.loadNote = note
            }
        }
    }

    // MARK: Capture One's capture folder (v1.43.5)

    /// Asks the running Capture One for its capture folder (never launches it).
    func refreshCaptureOneFolder(force: Bool = false) {
        guard mode == .session else {
            if captureOneFolder != nil { captureOneFolder = nil }
            return
        }
        guard !captureOneChecking else { return }
        if !force && Date().timeIntervalSince(lastCaptureOneCheck) < 3 { return }
        lastCaptureOneCheck = Date()
        guard let app = CaptureOneTarget.running(), let target = CaptureOneTarget.reference(app) else {
            if captureOneFolder != nil { captureOneFolder = nil }
            return
        }
        captureOneChecking = true
        Task.detached(priority: .utility) {
            let path: String? = MetadataWatcherModel.captureFolderPath(target)
            await MainActor.run {
                let model = MetadataWatcherModel.shared
                model.captureOneChecking = false
                guard let path, !path.isEmpty else {
                    if model.captureOneFolder != nil { model.captureOneFolder = nil }
                    return
                }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                if model.captureOneFolder?.standardizedFileURL.path != url.standardizedFileURL.path {
                    model.captureOneFolder = url
                }
            }
        }
    }

    nonisolated static func captureFolderPath(_ target: String) -> String? {
        var script: String = "if not (" + target + " is running) then return \"\"\n"
        script += "try\n"
        script += "tell " + target + " to set captureFolder to captures of current document\n"
        script += "return POSIX path of (captureFolder as alias)\n"
        script += "on error\n"
        script += "return \"\"\n"
        script += "end try"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.qualityOfService = .background
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        let bytes: Data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let base: String = parent.standardizedFileURL.path
        let here: String = child.standardizedFileURL.path
        return here == base || here.hasPrefix(base + "/")
    }

    /// The folders to watch: the chosen/session folder, plus Capture One's capture
    /// folder when it's somewhere outside that (session mode).
    var watchRoots: [URL] {
        guard let folder else { return [] }
        var roots: [URL] = [folder]
        if mode == .session, let capture = captureOneFolder, !Self.isInside(capture, folder) {
            roots.append(capture)
        }
        return roots
    }

    // MARK: Watching

    func start() {
        // v1.43.4: every reason Start can't run is a dialog (Return closes it), never just small text.
        guard MetadataSidecar.exiftoolPath() != nil else {
            status = "ExifTool isn't installed."
            simpleAlert("ExifTool isn't installed", "Studio Session uses the free ExifTool to write sidecars. Get it at exiftool.org (or in Terminal: brew install exiftool), then click Start Watching again.")
            return
        }
        guard hasValues else {
            status = "Enter something in at least one field to start watching."
            simpleAlert("Fill in a field first", "Enter something in at least one metadata field (for example Creator or Copyright Notice), or pick a preset. Then click Start Watching again.")
            return
        }
        guard folder != nil || mode == .session else {
            simpleAlert("Choose a folder first", "Click “A folder I choose…” to pick the folder to watch, or switch to the session's Capture folder.")
            return
        }
        watching = true
        UserDefaults.standard.set(true, forKey: Self.watchingKey)
        lastFolderPath = nil
        status = "Starting…"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MetadataWatcherModel.shared.tick() }
        }
        tick()
    }

    func stop() {
        watching = false
        UserDefaults.standard.set(false, forKey: Self.watchingKey)
        timer?.invalidate()
        timer = nil
        status = "Stopped. New frames don't get a sidecar until you start watching again."
    }

    func tick() {
        refreshCaptureOneFolder()
        guard watching, !scanning, !applying else { return }
        guard let folder else {
            status = mode == .session ? "Waiting for a Capture One session to open." : "Choose a folder to watch."
            return
        }
        guard let tool = MetadataSidecar.exiftoolPath() else {
            status = "ExifTool isn't installed. Get it free at exiftool.org (or: brew install exiftool)."
            return
        }
        scanning = true
        let roots: [URL] = watchRoots
        let path: String = roots.map(\.path).joined(separator: "|")
        let isNewFolder: Bool = path != lastFolderPath
        let deep: Bool = recursive
        let values: [String: String] = preset.values
        let keep: Bool = keepExisting
        let embed: Bool = embedImages
        let session: String = MetadataSidecar.sessionName(for: folder)
        let knownNow: [String: String] = known
        let waitingNow: [String: String] = waiting
        Task.detached(priority: .utility) {
            var raws: [URL] = []
            for root in roots { raws += MetadataSidecar.listWork(in: root, recursive: deep, embed: embed) }
            var signatures: [String: String] = [:]
            for raw in raws { signatures[raw.path] = MetadataSidecar.signature(raw) }
            if isNewFolder {
                // Frames already here are left to "Apply to Existing Frames".
                let baseline = signatures
                await MainActor.run {
                    let model = MetadataWatcherModel.shared
                    model.known = baseline
                    model.waiting = [:]
                    model.lastFolderPath = path
                    model.scanning = false
                    model.status = "Watching " + folder.lastPathComponent + ". New frames get a sidecar as they arrive."
                    model.refreshCount()
                }
                return
            }
            // v1.43.3: a NEW raw is stamped the first time it's seen. The sidecar doesn't
            // depend on the raw's contents, so there's no need to wait for it to finish
            // arriving (that wait was most of the delay Jeff saw).
            var ready: [URL] = []
            var stillWaiting: [String: String] = [:]
            for raw in raws where knownNow[raw.path] == nil {
                if MetadataSidecar.isRaw(raw) {
                    ready.append(raw)
                } else {
                    // A JPEG/TIFF/PNG is written into, so wait until it has stopped
                    // changing for one look (an export may still be arriving).
                    let sig: String = signatures[raw.path] ?? ""
                    if waitingNow[raw.path] == sig { ready.append(raw) } else { stillWaiting[raw.path] = sig }
                }
            }
            var results: [(URL, String, MetadataSidecar.StampResult)] = []
            for raw in ready.prefix(40) {
                let result = MetadataSidecar.process(file: raw, tool: tool, values: values, keepExisting: keep, session: session, embed: embed)
                let after: String = MetadataSidecar.signature(raw)
                results.append((raw, after, result))
            }
            for raw in ready.dropFirst(40) { stillWaiting[raw.path] = signatures[raw.path] }
            let finalWaiting = stillWaiting
            let finalResults = results
            await MainActor.run {
                let model = MetadataWatcherModel.shared
                model.waiting = finalWaiting
                for (raw, sig, result) in finalResults {
                    model.known[raw.path] = sig
                    model.record(raw, result)
                }
                model.scanning = false
            }
        }
    }

    private func record(_ raw: URL, _ result: MetadataSidecar.StampResult) {
        if result.ok {
            if result.wrote > 0 { stamped += 1 } else { kept += 1 }
        } else {
            failed += 1
        }
        let name: String = MetadataSidecar.isRaw(raw) ? raw.deletingPathExtension().lastPathComponent + ".xmp" : raw.lastPathComponent
        if result.ok { lastLandingFolder = raw.deletingLastPathComponent() }
        if result.ok, let folder {
            let base: String = folder.standardizedFileURL.path
            let here: String = raw.deletingLastPathComponent().standardizedFileURL.path
            if here == base {
                lastLanding = folder.lastPathComponent
            } else if here.hasPrefix(base + "/") {
                lastLanding = folder.lastPathComponent + "/" + String(here.dropFirst(base.count + 1))
            } else {
                lastLanding = here
            }
        }
        events.insert(MetadataEvent(message: name + ": " + result.message, success: result.ok), at: 0)
        if events.count > 60 { events.removeLast(events.count - 60) }
    }

    // MARK: Existing frames

    func refreshCount() {
        guard let folder else { withoutSidecar = nil; return }
        let deep: Bool = recursive
        Task.detached(priority: .utility) {
            let raws: [URL] = MetadataSidecar.listRaws(in: folder, recursive: deep)
            var missing = 0
            for raw in raws where !FileManager.default.fileExists(atPath: MetadataSidecar.sidecarURL(for: raw).path) { missing += 1 }
            let count = missing
            await MainActor.run { MetadataWatcherModel.shared.withoutSidecar = count }
        }
    }

    func applyToExisting() {
        guard let folder else {
            simpleAlert("No folder yet", mode == .session ? "Open a session in Capture One first, or choose a folder." : "Choose a folder first.")
            return
        }
        guard let tool = MetadataSidecar.exiftoolPath() else {
            simpleAlert("ExifTool isn't installed", "Get it free at exiftool.org (or: brew install exiftool), then try again.")
            return
        }
        guard hasValues else {
            simpleAlert("Nothing to write", "Fill in at least one field first.")
            return
        }
        let raws: [URL] = MetadataSidecar.listWork(in: folder, recursive: recursive, embed: embedImages)
        guard !raws.isEmpty else {
            let kinds: String = embedImages ? "raw, JPEG, TIFF or PNG files" : "raw files"
            simpleAlert("Nothing to do here", folder.path + " has no " + kinds + (recursive ? " (subfolders included)." : "."))
            return
        }
        let rawCount: Int = raws.filter { MetadataSidecar.isRaw($0) }.count
        let imageCount: Int = raws.count - rawCount
        let alert = NSAlert()
        var title: String = ""
        if rawCount > 0 { title = "Write sidecars for \(rawCount) " + (rawCount == 1 ? "raw" : "raws") }
        if imageCount > 0 {
            let part: String = "embed into \(imageCount) " + (imageCount == 1 ? "image" : "images")
            if title.isEmpty {
                let capital: String = part.prefix(1).uppercased() + String(part.dropFirst())
                title = capital
            } else {
                title += " and " + part
            }
        }
        alert.messageText = title + "?"
        var info: String = "In " + folder.lastPathComponent + ". Raw files aren't changed (they get a sidecar)."
        if imageCount > 0 { info += " JPEG, TIFF and PNG files get the metadata written inside them; only the metadata changes." }
        info += keepExisting ? " Where a sidecar already has a value, it's kept." : " Values in this preset replace what's already in a sidecar."
        alert.informativeText = info
        alert.addButton(withTitle: imageCount > 0 ? "Write Metadata" : "Write Sidecars")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applying = true
        applyProgress = "0 of \(raws.count)"
        let values: [String: String] = preset.values
        let keep: Bool = keepExisting
        let embed: Bool = embedImages
        let session: String = MetadataSidecar.sessionName(for: folder)
        let total: Int = raws.count
        Task.detached(priority: .userInitiated) {
            var done = 0
            for raw in raws {
                let result = MetadataSidecar.process(file: raw, tool: tool, values: values, keepExisting: keep, session: session, embed: embed)
                let sig: String = MetadataSidecar.signature(raw)
                done += 1
                let step = done
                await MainActor.run {
                    let model = MetadataWatcherModel.shared
                    model.known[raw.path] = sig
                    model.record(raw, result)
                    model.applyProgress = "\(step) of \(total)"
                }
            }
            await MainActor.run {
                let model = MetadataWatcherModel.shared
                model.applying = false
                model.applyProgress = ""
                model.status = "Existing frames done."
                model.refreshCount()
            }
        }
    }

    private func simpleAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - The tab

struct MetadataWatcherView: View {
    @ObservedObject var wrap: WrapModel
    @ObservedObject private var model = MetadataWatcherModel.shared
    @State private var collapsed: Set<String> = []
    @State private var showMore = false
    @State private var dropTargeted = false

    private let accentText = Color(red: 0.10, green: 0.08, blue: 0.03)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            whereCard
            presetCard
            fieldsCard
            applyCard
            captureOneTip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.refreshCount() }
        .task {
            // Keep the folder line in step with Capture One while this tab is open.
            while !Task.isCancelled {
                model.refreshCaptureOneFolder()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onChange(of: wrap.root) { _ in if model.mode == .session { model.refreshCount() } }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "xmp" else { return }
                DispatchQueue.main.async { MetadataWatcherModel.shared.loadClientXMP(url) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(DigiBrand.accent, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(DigiBrand.toolName(8)).font(.title2.bold())
                Text("Writes your IPTC info to a sidecar .xmp next to each raw. Raws are never changed. Capture One picks it up on its own when Preferences › Image › Auto Sync Sidecar XMP is set to Load.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Circle().fill(model.watching ? Color.green : Color.secondary).frame(width: 9, height: 9)
                Text(model.watching ? "Watching" : "Stopped").fontWeight(.semibold)
                Text(countsText).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(DigiBrand.cardFill, in: Capsule())
        }
    }

    private var countsText: String {
        var parts: [String] = ["\(model.stamped) stamped"]
        if model.kept > 0 { parts.append("\(model.kept) kept") }
        let problems: String = model.failed == 1 ? "1 problem" : "\(model.failed) problems"
        parts.append(problems)
        return parts.joined(separator: " · ")
    }

    // MARK: Where

    private var whereCard: some View {
        card {
            HStack {
                Text("Where").font(.headline)
                Spacer()
                Button(model.watching ? "Stop Watching" : "Start Watching") {
                    if model.watching { model.stop() } else { model.start() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            HStack(spacing: 10) {
                choiceButton("Session's Capture folder (automatic)", selected: model.mode == .session) { model.mode = .session }
                choiceButton(model.chosenFolder == nil ? "A folder I choose…" : "A folder I choose", selected: model.mode == .chosen) {
                    if model.chosenFolder == nil { model.chooseFolder() } else { model.mode = .chosen }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(folderPathText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(folderNoteText).font(.callout).foregroundStyle(.secondary)
                if model.mode == .chosen {
                    Button("Change…") { model.chooseFolder() }
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            if let folder = model.folder, let capture = captureOneShown, !MetadataWatcherModel.isInside(capture, folder) {
                Label("Capture One is capturing outside " + folder.lastPathComponent + ". That folder is watched too.", systemImage: "arrow.down.to.line")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let folder = model.folder, captureOneShown != nil || landingSubfolder != nil {
                Label("Watching all of " + folder.lastPathComponent + ", so frames in any folder inside it get a sidecar.", systemImage: "arrow.down.to.line")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Toggle("Include subfolders", isOn: $model.recursive)
            Toggle(isOn: $model.embedImages) {
                Text("Also write into JPEG, TIFF and PNG files ") + Text("(inside the file itself; raws always get a sidecar)").foregroundColor(.secondary)
            }
            Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The folder frames are actually arriving in, when that's a subfolder of the
    /// watched folder (Capture One's capture folder moved inside Capture).
    private var landingSubfolder: URL? {
        guard let landing = model.lastLandingFolder, let folder = model.folder else { return nil }
        let base: String = folder.standardizedFileURL.path
        let here: String = landing.standardizedFileURL.path
        return here.hasPrefix(base + "/") ? landing : nil
    }

    /// Capture One's capture folder, when we know it (session mode).
    private var captureOneShown: URL? {
        model.mode == .session ? model.captureOneFolder : nil
    }

    private var folderPathText: String {
        if let capture = captureOneShown { return capture.path }
        if let landing = landingSubfolder { return landing.path }
        if let folder = model.folder { return folder.path }
        return model.mode == .session ? "No Capture One session open" : "No folder chosen"
    }

    private var folderNoteText: String {
        if captureOneShown != nil { return "Capture One's capture folder" }
        if landingSubfolder != nil { return "Where new frames are landing" }
        if model.mode == .session { return model.folder == nil ? "Opens with your session" : "From the open session" }
        return "Chosen by you"
    }

    private func choiceButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                Text(title).fontWeight(selected ? .bold : .semibold)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(selected ? accentText : Color.primary)
            .background(selected ? DigiBrand.accent : Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: Preset

    private var presetCard: some View {
        card {
            HStack {
                Text("Preset").font(.headline)
                Spacer()
                Button("Show Presets in Finder") { model.showPresetsFolder() }
                    .buttonStyle(.link)
            }
            HStack(spacing: 10) {
                TextField("Preset name", text: $model.preset.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Menu("Presets") {
                    if model.presetFiles.isEmpty { Text("No saved presets yet") }
                    ForEach(model.presetFiles, id: \.self) { file in
                        Button(file.deletingPathExtension().lastPathComponent) { model.selectPresetFile(file) }
                    }
                    Divider()
                    Button("New (Empty)") { model.newPreset() }
                }
                .frame(maxWidth: 130)
                .onAppear { model.refreshPresetFiles() }
                Button("Save") { model.savePreset() }
                Button("Save as New…") { model.saveAsNew() }
                Button("Delete…") { model.deletePreset() }
                Spacer(minLength: 8)
                Button {
                    model.chooseClientXMP()
                } label: {
                    Label("Load .xmp…", systemImage: "square.and.arrow.down")
                        .fontWeight(.bold)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(accentText)
                        .background(DigiBrand.accent, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
            if let note = model.loadNote {
                Label(note, systemImage: model.loadNoteIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.loadNoteIsError ? Color.orange : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Presets are saved as .xmp files in Documents › Studio Session › Metadata Presets. Any .xmp you put there shows up in Presets. You can also drop an .xmp anywhere on this tab. Fill-ins: {year}  {date}  {session}  {filename}")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Fields (same sections and labels as Capture One)

    private var fieldsCard: some View {
        let columns: [GridItem] = [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)]
        let top: [MetadataField] = MetadataFields.top
        return card {
            Text("Fields").font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(top.filter { !$0.wide }, id: \.tag) { field in fieldEditor(field) }
            }
            ForEach(top.filter { $0.wide }, id: \.tag) { field in fieldEditor(field) }
            Button(showMore ? "▾ Fewer fields" : "▸ More IPTC fields") { showMore.toggle() }
                .buttonStyle(.plain)
                .foregroundStyle(DigiBrand.accent)
                .fontWeight(.semibold)
            if showMore {
                Divider()
                ForEach(moreSections, id: \.title) { section in
                    sectionView(section)
                }
            }
        }
    }

    /// Capture One's sections without the fields already shown up top.
    private var moreSections: [MetadataSection] {
        let shown: Set<String> = Set(MetadataFields.topTags)
        var result: [MetadataSection] = []
        for section in MetadataFields.sections {
            let rest: [MetadataField] = section.fields.filter { !shown.contains($0.tag) }
            if !rest.isEmpty { result.append(MetadataSection(title: section.title, fields: rest)) }
        }
        return result
    }

    private func sectionView(_ section: MetadataSection) -> some View {
        let open: Bool = !collapsed.contains(section.title)
        let columns: [GridItem] = [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)]
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if open { collapsed.insert(section.title) } else { collapsed.remove(section.title) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption.weight(.bold)).frame(width: 12)
                    Text(section.title).font(.callout.weight(.bold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(section.fields.filter { !$0.wide }, id: \.tag) { field in fieldEditor(field) }
                }
                ForEach(section.fields.filter { $0.wide }, id: \.tag) { field in fieldEditor(field) }
            }
        }
        .padding(.top, 6)
    }

    private func fieldEditor(_ field: MetadataField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(field.label).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            if field.wide {
                TextField(field.list ? "separate with commas" : "", text: model.binding(field.tag), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(field.list ? "separate with commas" : "", text: model.binding(field.tag))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: Apply

    private var applyCard: some View {
        card {
            Text("Apply").font(.headline)
            Toggle(isOn: $model.keepExisting) {
                Text("Keep values already in a sidecar ") + Text("(anything you changed in Capture One stays)").foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                Text(existingText)
                Spacer(minLength: 8)
                if model.applying {
                    ProgressView().controlSize(.small)
                    Text(model.applyProgress).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Button("Apply to Existing Frames…") { model.applyToExisting() }
                        .controlSize(.large)
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            if !model.events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.events.prefix(8)) { event in
                        HStack(spacing: 8) {
                            Image(systemName: event.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(event.success ? Color.green : Color.orange)
                            Text(event.message).font(.system(.caption, design: .monospaced)).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(event.time, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var existingText: String {
        guard model.folder != nil else { return "Existing frames: no folder yet." }
        guard let count = model.withoutSidecar else { return "Counting frames…" }
        if count == 0 { return "Every frame here has a sidecar." }
        return (count == 1 ? "1 frame here has" : "\(count) frames here have") + " no sidecar yet."
    }

    private var captureOneTip: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(DigiBrand.accent)
            Text("Capture One setting needed once: Preferences › Image › Auto Sync Sidecar XMP = Load (not Full Sync).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5])))
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 14))
    }
}
