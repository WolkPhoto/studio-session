import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision

/// v1.22: reads the words in a picture of a shot list (a screenshot, a photo of a
/// whiteboard or call sheet). Runs on the Mac with Apple's Vision; nothing is uploaded.
enum FolderImageText {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func read(url: URL) throws -> String {
        try read(VNImageRequestHandler(url: url, options: [:]))
    }

    static func read(data: Data) throws -> String {
        try read(VNImageRequestHandler(data: data, options: [:]))
    }

    private static func read(_ handler: VNImageRequestHandler) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try handler.perform([request])
        let observations: [VNRecognizedTextObservation] = request.results ?? []
        // Top of the picture first (Vision measures from the bottom).
        let ordered = observations.sorted { first, second in
            first.boundingBox.midY > second.boundingBox.midY
        }
        var lines: [String] = []
        for observation in ordered {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        if lines.isEmpty { throw FolderPlan.failure("No text was found in this picture.") }
        return lines.joined(separator: "\n")
    }
}

// Version 20: Folder Maker rebuilt around real job inputs (spreadsheets,
// emails, PDF or text shot lists, sequences). All parsing and folder work is
// in FolderPlanCore.swift; this file is the interface.
struct FolderMakerView: View {
    let sessionRoot: URL?
    let captureFolder: URL?
    let outputFolder: URL?

    // Input
    @AppStorage("DigiSuite.folderMaker.mode") private var mode = 0 // 0 Sequences, 1 Import File, 2 Paste List
    @State private var paste = ""
    @AppStorage("DigiSuite.folderMaker.splitCommas") private var splitCommas = true
    @AppStorage("DigiSuite.folderMaker.stripBullets") private var stripBullets = true
    @State private var sheets: [FolderPlan.Sheet] = []
    @State private var sheetIndex = 0
    @State private var header = true
    // Version 20.4: one column, one folder per cell. Simple on purpose.
    @State private var selectedColumn: Int?
    @State private var duplicateIndices: Set<Int> = []
    @State private var importedName = ""
    @State private var reading = false
    @State private var dropTargeted = false
    @State private var prefix = "Shot_"
    @State private var suffix = ""
    @State private var start = 1
    @State private var end = 10
    @State private var digits = 2
    @State private var step = 1
    @State private var sequenceRequest = ""

    // Result
    @State private var bases: [String] = []
    @State private var subfoldersText = ""
    @AppStorage("DigiSuite.folderMaker.subfolderPresets") private var presetStore = "Selects\nSelects, Output"
    @State private var planned = FolderPlan.Planned()
    @AppStorage("DigiSuite.folderMaker.destinationChoice") private var destinationChoice = "capture"
    /// v1.22: Command-click adds more places; stored as "capture,output".
    @AppStorage("DigiSuite.folderMaker.destinationChoices") private var choicesRaw = ""
    /// v1.22: "" keeps spaces, "_" or "-" replaces them.
    @AppStorage("DigiSuite.folderMaker.spaces") private var spaceStyle = ""
    @State private var plans: [FolderPlan.Planned] = []
    @State private var customDestination = ""
    @State private var lastCreated: [URL] = []
    @State private var message = "Import a shot list, a picture of one, paste an email, or build a sequence. Nothing is created until you click Create."
    @State private var confirmCreate = false

    // MARK: Derived values

    private var sessionName: String? { sessionRoot?.lastPathComponent }

    private static let choiceOrder = ["session", "capture", "output", "custom"]

    private var choices: [String] {
        let saved = choicesRaw.split(separator: ",").map(String.init)
        let list = Self.choiceOrder.filter { saved.contains($0) }
        return list.isEmpty ? [destinationChoice] : list
    }

    private func setChoices(_ list: [String]) {
        let sorted = Self.choiceOrder.filter { list.contains($0) }
        guard let first = sorted.first else { return }
        choicesRaw = sorted.joined(separator: ",")
        destinationChoice = first
    }

    /// Every chosen place, without repeats (Capture falls back to the session
    /// folder when there isn't one, so two choices can be the same folder).
    private var destinationURLs: [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for choice in choices {
            let place: URL = url(for: choice)
            let key = place.standardizedFileURL.path
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(place)
        }
        return result
    }

    private var destinationURL: URL { destinationURLs.first ?? url(for: destinationChoice) }

    private var destinationNames: String {
        let names = destinationURLs.map(\.lastPathComponent)
        if names.count <= 1 { return names.first ?? "" }
        if names.count == 2 { return names[0] + " and " + names[1] }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    private func url(for choice: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch choice {
        case "session": return sessionRoot ?? home
        case "capture": return captureFolder ?? sessionRoot ?? home
        case "output": return outputFolder ?? sessionRoot ?? home
        default: return customDestination.isEmpty ? (sessionRoot ?? home) : URL(fileURLWithPath: customDestination)
        }
    }

    private var subfolders: [String] {
        FolderPlan.splitList(FolderPlan.applyTokens(subfoldersText, session: sessionName))
    }

    private func styled(_ path: String) -> String {
        FolderPlan.replaceSpaces(path, with: spaceStyle)
    }

    private var finalPaths: [String] {
        let named: [String] = bases.map { FolderPlan.applyTokens($0, session: sessionName) }
        return FolderPlan.expand(named, subfolders: subfolders).map { styled($0) }
    }

    /// Totals across every chosen place, worked out in recompute (not in the view body).
    @State private var newCount = 0
    @State private var existingCount = 0
    private var presets: [String] { presetStore.components(separatedBy: "\n").filter { !$0.isEmpty } }
    private var currentSheet: FolderPlan.Sheet? { sheetIndex < sheets.count ? sheets[sheetIndex] : nil }

    private func recompute() {
        let paths = finalPaths
        var all: [FolderPlan.Planned] = []
        var ready = 0
        var existing = 0
        for url in destinationURLs {
            let plan = FolderPlan.plan(paths, destination: url)
            ready += plan.rows.filter { $0.status == .ready }.count
            existing += plan.rows.filter { $0.status == .exists }.count
            all.append(plan)
        }
        plans = all
        planned = all.first ?? FolderPlan.Planned()
        newCount = ready
        existingCount = existing
        // A name that appears again later in the list is a duplicate; only the
        // first one is created.
        var seen = Set<String>()
        var duplicates = Set<Int>()
        for (index, base) in bases.enumerated() {
            let named: String = styled(FolderPlan.applyTokens(base, session: sessionName))
            guard let path = FolderPlan.cleanPath(named).path else { continue }
            let key = path.lowercased()
            if seen.contains(key) { duplicates.insert(index) } else { seen.insert(key) }
        }
        duplicateIndices = duplicates
    }

    // MARK: Actions

    private func generateSequence() {
        do {
            bases = try FolderPlan.sequence(prefix: prefix, start: start, end: end, digits: digits, suffix: suffix, step: step)
            message = "\(bases.count) folders from the sequence. Nothing has been created yet."
        } catch {
            message = error.localizedDescription
        }
    }

    private func updatePasteList() {
        let unique = FolderPlan.uniqueNames(FolderPlan.listNames(paste, splitCommas: splitCommas, stripBullets: stripBullets))
        bases = unique.names
        if bases.isEmpty {
            message = "Paste or type one folder name per line."
        } else {
            var text: String = "\(bases.count) folders from your list."
            if unique.combined > 0 { text += " \(unique.combined) repeated lines combined." }
            message = text + " Nothing has been created yet."
        }
    }

    private func pasteFromClipboard() {
        let board = NSPasteboard.general
        if let text = board.string(forType: .string), !text.isEmpty {
            paste = text
            updatePasteList()
            return
        }
        if let image = NSImage(pasteboard: board), let data = image.tiffRepresentation {
            readImageText(data, source: "the copied picture")
            return
        }
        message = "The clipboard has no text or picture to use."
    }

    private func imageMessage(_ source: String) -> String {
        "Text read from " + source + " is in the list. Check the spelling and delete any lines that should not be folders."
    }

    /// Reads the words in a picture (clipboard or dropped image data) into the Paste List.
    private func readImageText(_ data: Data, source: String) {
        reading = true
        message = "Reading the text in " + source + "…"
        Task.detached(priority: .userInitiated) {
            var text = ""
            var problem: String?
            do { text = try FolderImageText.read(data: data) } catch { problem = error.localizedDescription }
            let found = text
            let failure = problem
            await MainActor.run {
                reading = false
                if let failure { message = "Couldn't read that picture: " + failure; return }
                sheets = []
                paste = found
                mode = 2
                updatePasteList()
                let note = imageMessage(source)
                DispatchQueue.main.async { message = note }
            }
        }
    }

    /// Shows the list for the tab you are on.
    private func modeChanged() {
        switch mode {
        case 0: generateSequence()
        case 1: if currentSheet != nil { applyTable() } else { bases = [] }
        default: updatePasteList()
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a spreadsheet, email, PDF, Word document, text file or a picture of a list."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    /// v1.23: Paste List's own picture button.
    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a screenshot or photo of a shot list."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    private func importFile(_ url: URL) {
        reading = true
        importedName = url.lastPathComponent
        let isImage = FolderImageText.isImage(url)
        message = (isImage ? "Reading the text in " : "Reading ") + url.lastPathComponent + "…"
        Task.detached(priority: .userInitiated) {
            var imported: FolderPlan.Imported?
            var failure: String?
            do {
                if isImage {
                    imported = .text(try FolderImageText.read(url: url))
                } else if url.pathExtension.lowercased() == "pdf" {
                    guard let document = PDFDocument(url: url) else { throw FolderPlan.failure("Could not open this PDF.") }
                    imported = .text(document.string ?? "")
                } else {
                    imported = try FolderPlan.read(url)
                }
            } catch {
                failure = error.localizedDescription
            }
            let result = imported
            let problem = failure
            await MainActor.run {
                reading = false
                if let problem { message = "Import failed: " + problem; return }
                guard let result else { return }
                switch result {
                case .tables(let found):
                    sheets = found
                    sheetIndex = 0
                    header = true
                    selectedColumn = firstUsefulColumn(found.first?.rows ?? [])
                    mode = 1
                    applyTable()
                case .text(let text):
                    sheets = []
                    paste = text
                    mode = 2
                    updatePasteList()
                    var note = "Text from " + url.lastPathComponent + " is in the list. Delete any lines that should not be folders."
                    if isImage { note = imageMessage(url.lastPathComponent) }
                    message = note
                    DispatchQueue.main.async { message = note }
                }
            }
        }
    }

    private func firstUsefulColumn(_ rows: [[String]]) -> Int? {
        let width: Int = rows.map(\.count).max() ?? 0
        for column in 0..<width {
            let filled = rows.filter { column < $0.count && !$0[column].isEmpty }.count
            if filled > 0 { return column }
        }
        return nil
    }

    private func applyTable() {
        guard let sheet = currentSheet, let column = selectedColumn else {
            bases = []
            if currentSheet != nil { message = "Click a column. Each cell in it becomes a folder." }
            return
        }
        let all: [String] = FolderPlan.names(from: sheet.rows, header: header, columns: [column], nested: false, separator: "")
        let unique = FolderPlan.uniqueNames(all)
        bases = unique.names
        var text: String = "\(bases.count) folders from column " + columnLetter(column) + "."
        if unique.combined > 0 { text += " \(unique.combined) repeated cells combined." }
        message = text + " Nothing has been created yet."
    }

    private func selectColumn(_ column: Int) {
        selectedColumn = column
        applyTable()
    }

    private func create() {
        let paths = finalPaths
        var made: [URL] = []
        var skipped = 0
        var problems: [String] = []
        for url in destinationURLs {
            do {
                let result = try FolderPlan.create(paths, destination: url)
                made += result.made
                skipped += result.skipped.count
                for error in result.errors { problems.append(url.lastPathComponent + ": " + error) }
            } catch {
                problems.append(url.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        lastCreated = made
        var text = "Created \(made.count) folders in " + destinationNames + "."
        if skipped > 0 { text += " \(skipped) already existed and were left alone." }
        if !problems.isEmpty { text += " Problems: " + problems.joined(separator: "; ") }
        message = text
        recompute()
    }

    private func undo() {
        let result = FolderPlan.undo(lastCreated)
        var text = "Removed \(result.removed) empty folders."
        if !result.kept.isEmpty { text += " Kept \(result.kept.count) that now contain files." }
        message = text
        lastCreated = []
        recompute()
    }

    /// Click picks one place. Command-click adds it, or takes it away again.
    private func pick(_ choice: String) {
        let adding = NSEvent.modifierFlags.contains(.command)
        var list = choices
        if adding {
            if list.contains(choice) {
                if list.count > 1 { list.removeAll { $0 == choice } }
            } else {
                list.append(choice)
            }
        } else {
            list = [choice]
        }
        setChoices(list)
    }

    private func chooseDestination() {
        let adding = NSEvent.modifierFlags.contains(.command)
        if adding && choices.contains("custom") && choices.count > 1 {
            setChoices(choices.filter { $0 != "custom" })
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destinationURL
        panel.message = "Choose the folder to create the new folders in."
        if panel.runModal() == .OK, let url = panel.url {
            customDestination = url.path
            if adding {
                setChoices(choices + ["custom"])
            } else {
                setChoices(["custom"])
            }
        }
    }

    private func savePreset() {
        let value = subfoldersText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !presets.contains(value) else { return }
        presetStore = (presets + [value]).joined(separator: "\n")
    }

    private func removePreset(_ value: String) {
        presetStore = presets.filter { $0 != value }.joined(separator: "\n")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { importFile(url) }
            }
            return true
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { readImageText(data, source: "the dropped picture") }
            }
            return true
        }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text else { return }
                DispatchQueue.main.async {
                    paste = text
                    mode = 2
                    updatePasteList()
                }
            }
            return true
        }
        return false
    }

    // MARK: Layout pieces

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DigiBrand.cardFill.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.18)))
    }

    private func numberField(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 60, idealWidth: 90, maxWidth: 120)
                    .onChange(of: value.wrappedValue) { _, newValue in
                        if !range.contains(newValue) {
                            value.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
                        }
                    }
                Stepper(title, value: value, in: range).labelsHidden().fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sequenceInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sequence", systemImage: "number.square").font(.headline)
            HStack {
                TextField("Or type a range, e.g. Shot_01 through Shot_24", text: $sequenceRequest)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { interpretSequenceRequest() }
                Button("Use") { interpretSequenceRequest() }
                    .disabled(sequenceRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Prefix").font(.caption).foregroundStyle(.secondary)
                    TextField("Prefix", text: $prefix).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading) {
                    Text("Suffix").font(.caption).foregroundStyle(.secondary)
                    TextField("Optional suffix", text: $suffix).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 14) {
                numberField("Start", value: $start, range: 0...999_999)
                numberField("End", value: $end, range: 0...999_999)
                numberField("Digits", value: $digits, range: 1...8)
                numberField("Step", value: $step, range: 1...9_999)
            }
            Text("The preview updates as you type.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func interpretSequenceRequest() {
        if let names = FolderPlan.interpretSequence(sequenceRequest) {
            bases = names
            message = "\(names.count) folders from \"" + sequenceRequest + "\"."
        } else {
            message = "Could not read a range from that. Try something like Shot_01 through Shot_24."
        }
    }

    private func columnLetter(_ index: Int) -> String {
        var number = index + 1
        var letters = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            let scalar = Unicode.Scalar(UInt8(65 + remainder))
            letters = String(Character(scalar)) + letters
            number = (number - 1) / 26
        }
        return letters
    }

    private func columnHeaderButton(_ column: Int, rows: [[String]]) -> some View {
        let selected: Bool = selectedColumn == column
        let title: String = header && !rows.isEmpty && column < rows[0].count ? rows[0][column] : ""
        let fill: Color = selected ? DigiBrand.accent.opacity(0.35) : Color.secondary.opacity(0.12)
        return Button { selectColumn(column) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(columnLetter(column)).font(.caption.weight(.bold))
                    if selected { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.tint) }
                }
                Text(title.isEmpty ? " " : title).font(.caption).lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
            .padding(6)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Make a folder from each cell in this column")
    }

    private func tableCell(_ text: String, selected: Bool) -> some View {
        let color: Color = selected ? Color.primary : Color.secondary
        return Text(text)
            .font(.caption).lineLimit(1)
            .frame(width: 130, alignment: .leading)
            .padding(.horizontal, 6)
            .foregroundStyle(color)
    }

    private func tableRow(_ row: [String], width: Int) -> some View {
        GridRow {
            ForEach(0..<width, id: \.self) { column in
                tableCell(column < row.count ? row[column] : "", selected: selectedColumn == column)
            }
        }
    }

    private func tableGrid(_ sheet: FolderPlan.Sheet) -> some View {
        let width: Int = min(30, sheet.rows.map(\.count).max() ?? 0)
        let bodyRows: [[String]] = Array(sheet.rows.dropFirst(header ? 1 : 0).prefix(8))
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    ForEach(0..<width, id: \.self) { column in columnHeaderButton(column, rows: sheet.rows) }
                }
                ForEach(Array(bodyRows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, width: width)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var importInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import a File", systemImage: "square.and.arrow.down").font(.headline)
            HStack {
                Button("Choose File…") { chooseFile() }.buttonStyle(.borderedProminent)
                Text(importedName.isEmpty ? "Excel, CSV, email (.eml), PDF, Word, text, or a picture of a list. Or drop a file anywhere here." : importedName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if reading { ProgressView().controlSize(.small) }
            }
            if let sheet = currentSheet {
                sheetControls
                Text("Click a column. Each cell in it becomes a folder; blank cells are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
                tableGrid(sheet)
            }
        }
    }

    private var sheetControls: some View {
        HStack(spacing: 12) {
            if sheets.count > 1 {
                Picker("Sheet", selection: $sheetIndex) {
                    ForEach(Array(sheets.enumerated()), id: \.offset) { index, item in
                        Text(item.name).tag(index)
                    }
                }
                .frame(maxWidth: 240)
            }
            Toggle("First row is a header", isOn: $header)
            Spacer()
        }
    }

    private var pasteInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Paste a List", systemImage: "list.bullet").font(.headline)
            Text("One folder per line. Use / for subfolders, for example Look 1/Selects. Got a picture of a list? Click Read a Picture, paste a copied screenshot, or drop it here.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $paste)
                .font(.body)
                .frame(minHeight: 150)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            HStack {
                Button("Paste from Clipboard") { pasteFromClipboard() }
                    .help("Pastes copied text, or reads the text in a copied picture or screenshot.")
                Button("Read a Picture…") { choosePicture() }
                    .help("Pick a screenshot or photo of a shot list. Each line of text becomes a folder.")
                if reading { ProgressView().controlSize(.small) }
                Button("Clear List") { paste = "" }.disabled(paste.isEmpty)
                Toggle("Remove bullets and numbers", isOn: $stripBullets)
                    .help("Strips -, •, * and 1. 2. 3. from the start of each line.")
                Toggle("Split commas", isOn: $splitCommas)
                    .help("A, B, C on one line becomes three folders.")
                Spacer()
            }
        }
    }

    private var subfolderPanel: some View {
        panel {
            HStack {
                Label("Subfolders Inside Each Folder", systemImage: "folder.badge.plus").font(.headline)
                Spacer()
                Menu("Presets") {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset) { subfoldersText = preset }
                    }
                    Divider()
                    Button("Save Current as Preset") { savePreset() }
                        .disabled(subfoldersText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if presets.contains(subfoldersText) {
                        Button("Remove This Preset") { removePreset(subfoldersText) }
                    }
                }
                .fixedSize()
            }
            TextField("Optional, comma separated: Selects, Output", text: $subfoldersText)
                .textFieldStyle(.roundedBorder)
            Text("Use {session} or {date} in any name. Example: {date}_Shot_01.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// New, Exists, Skipped, or "New in 1 of 2" when creating in several places.
    private func statusLabel(for path: String) -> some View {
        let key = path.lowercased()
        var found = 0
        var ready = 0
        for plan in plans {
            if let row = plan.rows.first(where: { $0.id == key }) {
                found += 1
                if row.status == .ready { ready += 1 }
            }
        }
        var text = "New"
        var color: Color = .green
        if found == 0 {
            text = "Skipped"
            color = .secondary
        } else if ready == 0 {
            text = "Exists"
            color = .orange
        } else if ready < found {
            text = "New in \(ready) of \(found)"
        }
        return Text(text).font(.caption).foregroundStyle(color)
    }

    private func previewRow(_ index: Int) -> some View {
        let base: String = FolderPlan.applyTokens(bases[index], session: sessionName)
        let plain: String = FolderPlan.cleanPath(base).path ?? base
        let cleaned: String = FolderPlan.cleanPath(styled(base)).path ?? base
        let renamed: Bool = cleaned != plain
        let children: [String] = subfolders
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                TextField("Folder", text: Binding(
                    get: { index < bases.count ? bases[index] : "" },
                    set: { if index < bases.count { bases[index] = $0 } }
                ))
                .textFieldStyle(.plain)
                if renamed {
                    Text("→ " + cleaned).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("The folder will be named " + cleaned)
                }
                if duplicateIndices.contains(index) {
                    Text("Duplicate").font(.caption).foregroundStyle(.secondary)
                        .help("Same name as a folder above; it will not be created twice.")
                } else {
                    statusLabel(for: cleaned)
                }
                Button(role: .destructive) {
                    if index < bases.count { bases.remove(at: index) }
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            }
            ForEach(children, id: \.self) { child in
                let childName: String = styled(FolderPlan.cleanComponent(child).name ?? child)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(childName).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    statusLabel(for: cleaned + "/" + childName)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
    }

    private var countText: String {
        var text = "\(newCount) new · \(existingCount) already exist"
        let places = destinationURLs.count
        if places > 1 { text += " · in \(places) places" }
        return text
    }

    private var previewPanel: some View {
        panel {
            HStack {
                Label("Preview", systemImage: "folder").font(.headline)
                Text(countText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Folder") { bases.append("New Folder") }
                Button("Clear") { bases = []; if mode == 2 { paste = "" } }.disabled(bases.isEmpty)
            }
            HStack(spacing: 10) {
                Text("Spaces in names").font(.caption).foregroundStyle(.secondary)
                Picker("Spaces in names", selection: $spaceStyle) {
                    Text("Keep").tag("")
                    Text("Use _").tag("_")
                    Text("Use -").tag("-")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Shot 01 becomes Shot_01 or Shot-01. Applies to subfolders too.")
                Spacer()
            }
            if bases.isEmpty {
                Text("Nothing to preview yet. Import, paste or build a sequence above.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(bases.indices, id: \.self) { index in previewRow(index) }
                    }
                }
                .frame(maxHeight: 360)
            }
            if !planned.adjusted.isEmpty {
                DisclosureGroup("Renamed for macOS (\(planned.adjusted.count))") {
                    ForEach(planned.adjusted, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .font(.caption)
            }
            if !planned.skipped.isEmpty {
                DisclosureGroup("Skipped (\(planned.skipped.count))") {
                    ForEach(planned.skipped, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .font(.caption)
            }
        }
    }

    /// Version 20.6: the chosen location is a filled blue button with a
    /// checkmark; the others are plain.
    @ViewBuilder private func destinationButton(_ title: String, choice: String, available: Bool) -> some View {
        if choices.contains(choice) {
            Button { pick(choice) } label: {
                Label(title, systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .help("Command-click to take this place away")
        } else {
            Button(title) { pick(choice) }
                .buttonStyle(.bordered)
                .disabled(!available)
                .help("Click to use only this place. Command-click to add it.")
        }
    }

    @ViewBuilder private var chooseButton: some View {
        if choices.contains("custom") {
            Button { chooseDestination() } label: {
                Label("Chosen Folder…", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .help("Click to pick a different folder")
        } else {
            Button("Choose…") { chooseDestination() }
                .buttonStyle(.bordered)
        }
    }

    private var destinationPanel: some View {
        panel {
            Label("Create In", systemImage: "folder.badge.gearshape").font(.headline)
            HStack(spacing: 8) {
                destinationButton("Session", choice: "session", available: sessionRoot != nil)
                destinationButton("Capture", choice: "capture", available: captureFolder != nil || sessionRoot != nil)
                destinationButton("Output", choice: "output", available: outputFolder != nil)
                chooseButton
                Spacer()
            }
            ForEach(destinationURLs, id: \.self) { url in
                Text(url.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(url.path)
            }
            Text("Command-click to create the same folders in more than one place.")
                .font(.caption).foregroundStyle(.tertiary)
            Divider()
            HStack {
                Button("Create \(newCount) Folders") { confirmCreate = true }
                    .buttonStyle(.borderedProminent).disabled(newCount == 0)
                Button("Undo Last Creation") { undo() }.disabled(lastCreated.isEmpty)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(destinationURLs) }
                Spacer(minLength: 0)
            }
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DigiBrand.toolName(4)).font(.title2.bold())
                        Text("Turn shot lists, spreadsheets and emails into folders.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "folder.badge.gearshape").font(.title2).foregroundStyle(.tint)
                }
                panel {
                    Picker("Input method", selection: $mode) {
                        Text("Sequences").tag(0)
                        Text("Import File").tag(1)
                        Text("Paste List").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                inputPanel
                subfolderPanel
                previewPanel
                destinationPanel
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var inputPanel: some View {
        if mode == 0 { panel { sequenceInput } }
        else if mode == 1 { panel { importInput } }
        else { panel { pasteInput } }
    }

    private var dropOutline: some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(DigiBrand.accent, style: StrokeStyle(lineWidth: 3, dash: [8]))
            .padding(6)
            .allowsHitTesting(false)
            .opacity(dropTargeted ? 1 : 0)
    }

    private var droppableContent: some View {
        mainContent
            .overlay(dropOutline)
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, UTType.plainText.identifier], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }
    }

    private var previewWatching: some View {
        droppableContent
            .onAppear {
                if bases.isEmpty { modeChanged() }
                recompute()
            }
            .onChange(of: bases) { _, _ in recompute() }
            .onChange(of: subfoldersText) { _, _ in recompute() }
            .onChange(of: destinationChoice) { _, _ in recompute() }
            .onChange(of: choicesRaw) { _, _ in recompute() }
            .onChange(of: spaceStyle) { _, _ in recompute() }
            .onChange(of: outputFolder) { _, _ in recompute() }
            .onChange(of: customDestination) { _, _ in recompute() }
            .onChange(of: sessionRoot) { _, _ in recompute() }
            .onChange(of: captureFolder) { _, _ in recompute() }
    }

    private func pasteChanged() {
        if mode == 2 { updatePasteList() }
    }

    private var pasteWatching: some View {
        previewWatching
            .onChange(of: mode) { _, _ in modeChanged() }
            .onChange(of: paste) { _, _ in pasteChanged() }
            .onChange(of: splitCommas) { _, _ in pasteChanged() }
            .onChange(of: stripBullets) { _, _ in pasteChanged() }
    }

    private func sequenceChanged() {
        if mode == 0 { generateSequence() }
    }

    private var sequenceWatching: some View {
        pasteWatching
            .onChange(of: prefix) { _, _ in sequenceChanged() }
            .onChange(of: suffix) { _, _ in sequenceChanged() }
            .onChange(of: start) { _, _ in sequenceChanged() }
            .onChange(of: end) { _, _ in sequenceChanged() }
            .onChange(of: digits) { _, _ in sequenceChanged() }
            .onChange(of: step) { _, _ in sequenceChanged() }
    }

    private func sheetChanged() {
        selectedColumn = firstUsefulColumn(currentSheet?.rows ?? [])
        applyTable()
    }

    private var tableWatching: some View {
        sequenceWatching
            .onChange(of: sheetIndex) { _, _ in sheetChanged() }
            .onChange(of: header) { _, _ in applyTable() }

    }

    private var createTitle: String { "Create \(newCount) folders?" }
    private var createMessage: String {
        let urls = destinationURLs
        if urls.count == 1 {
            return "They will be created inside " + destinationURL.path + ". Existing folders are never changed."
        }
        let list = urls.map(\.path).joined(separator: "\n")
        return "The same folders will be created in each of these places:\n" + list + "\nExisting folders are never changed."
    }

    var body: some View {
        tableWatching
            .alert(createTitle, isPresented: $confirmCreate) {
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
            } message: {
                Text(createMessage)
            }
    }
}
