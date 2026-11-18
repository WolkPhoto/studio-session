
import SwiftUI
import AppKit
import PDFKit
import ImageIO
import CoreText
import CoreGraphics
import UniformTypeIdentifiers

private struct ContactLogo: Identifiable {
    let id: UUID
    var url: URL
    var placement: String
    var widthPercent: Double
    var firstPageOnly: Bool
    init(url: URL, placement: String = "Top right", widthPercent: Double = 18, firstPageOnly: Bool = false) {
        self.id = UUID()
        self.url = url
        self.placement = placement
        self.widthPercent = widthPercent
        self.firstPageOnly = firstPageOnly
    }
}
private let contactLogoPlacements = ["Top left", "Top center", "Top right", "Bottom left", "Bottom center", "Bottom right"]

// A real file thumbnail, not a generic image symbol. NSImage also supports PDF logos.
private struct ContactLogoThumbnail: View {
    let url: URL

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: 58)
        .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityLabel("Preview of " + url.lastPathComponent)
    }
}

private struct ContactItem: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}

struct ContactSheetsView: View {
    let sessionRoot: URL?
    @State private var showPagePreview = false
    @State private var selectedFolderPaths: Set<String> = []
    @State private var externalURLs: [URL] = []
    @State private var items: [ContactItem] = []
    @State private var rows = 3
    @State private var columns = 4
    @State private var pageWidth = 11.0
    @State private var pageHeight = 8.5
    @State private var margin = 0.25
    @State private var showNames = true
    @State private var showExtension = false
    @State private var singleLine = false
    @State private var fontSize = 9.0
    @State private var quality = 75.0
    @State private var dpi = 120.0
    @State private var title = ""
    @State private var author = ""
    @State private var subject = ""
    @State private var header = ""
    @State private var footer = ""
    @State private var logos: [ContactLogo] = []
    @State private var pageIndex = 0
    @State private var estimatedBytes: Int64 = 0
    @State private var estimating = false
    @State private var exporting = false
    @State private var exportProgress = 0.0
    @State private var exportedPages = 0
    @State private var totalExportPages = 0
    @State private var message = ""
    @State private var generation = 0
    @State private var scanGeneration = 0
    @State private var scanning = false
    @State private var preview: NSImage?
    private var perPage: Int { max(1, rows * columns) }
    private var pageCount: Int { items.isEmpty ? 0 : (items.count + perPage - 1) / perPage }

    // Version 20.8: labels never wrap letter by letter. In a narrow tile the
    // icon box is dropped so the label and value get the space.
    private func contactStatText(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            Text(value)
                .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func contactStatIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private func contactStat(_ symbol: String, title: String, value: String, tint: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                contactStatIcon(symbol, tint: tint)
                contactStatText(title: title, value: value)
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                contactStatText(title: title, value: value)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.17), lineWidth: 1))
    }

    private func contactSelectionMetric(_ value: String, label: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .pdf, .svg, .tiff]
        panel.message = "Choose one or more logos"
        guard panel.runModal() == .OK else { return }
        logos.append(contentsOf: panel.urls.map { ContactLogo(url: $0) })
        refresh()
    }

    private var logoSettingsSignature: [String] {
        logos.map { "\($0.id)-\($0.placement)-\($0.widthPercent)-\($0.firstPageOnly)" }
    }

    private var renderSettingsSignature: String {
        [
            String(rows), String(columns), String(pageWidth), String(pageHeight),
            String(margin), String(showNames), String(showExtension),
            String(singleLine), String(fontSize), String(quality), String(dpi),
            header, footer
        ].joined(separator: "|") + "|" + logoSettingsSignature.joined(separator: "|")
    }

    private var contactToolbar: some View {
            HStack {
                Text("Contact Sheets").font(.title2).bold()
                Spacer()
                if sessionRoot != nil {
                    Text("Choose folders on the left to add images")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("Add External Images…", action: chooseImages)
                Button("Clear") { selectedFolderPaths = []; externalURLs = []; rebuildImages() }
                    .disabled(items.isEmpty)
                Button(exporting ? "Exporting…" : "Export PDF…", action: exportPDF)
                    .disabled(items.isEmpty || exporting)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 12)
    }

    private var workspaceExplorer: some View {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 18)).foregroundStyle(.blue)
                            .frame(width: 34, height: 34)
                            .background(Color.blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Workspace Explorer").font(.headline)
                            Text("Choose folders for your contact sheet").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    ContactFolderPicker(root: sessionRoot, selectedPaths: $selectedFolderPaths)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("SELECTION SUMMARY", systemImage: "checkmark.circle")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.7).foregroundStyle(.secondary)
                            Spacer()
                            if scanning { ProgressView().controlSize(.small) }
                        }
                        HStack(spacing: 12) {
                            contactSelectionMetric(selectedFolderPaths.count.formatted(), label: "Folders", tint: .blue)
                            contactSelectionMetric(items.count.formatted(), label: "Images", tint: .green)
                        }
                        Button("Clear Selection") {
                            selectedFolderPaths = []; externalURLs = []; rebuildImages()
                        }
                        .disabled(selectedFolderPaths.isEmpty && externalURLs.isEmpty)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.blue.opacity(0.14)))
                }
                .frame(minWidth: 245, idealWidth: 300, maxWidth: 365)
    }

    private var contactPreviewPanel: some View {
                VStack(spacing: 8) {
                    HStack {
                        Text(showPagePreview ? "PDF Page Preview" : "Contact Sheet Images").font(.headline)
                        Button(showPagePreview ? "Show Images" : "Preview PDF") { showPagePreview.toggle(); if showPagePreview { refreshPreview() } else { preview = nil } }
                            .disabled(items.isEmpty)
                        Spacer()
                        Button { pageIndex = max(0, pageIndex - 1); refreshPreview() } label: {
                            Image(systemName: "chevron.left")
                        }.disabled(pageIndex == 0)
                        Text("\(pageCount == 0 ? 0 : pageIndex + 1) / \(pageCount)")
                            .font(.caption).monospacedDigit()
                        Button { pageIndex = min(max(0,pageCount - 1), pageIndex + 1); refreshPreview() } label: {
                            Image(systemName: "chevron.right")
                        }.disabled(pageIndex + 1 >= pageCount)
                    }
                    GeometryReader { geo in
                        ZStack {
                            Color.gray.opacity(0.14)
                            if showPagePreview, let preview {
                                Image(nsImage: preview)
                                    .resizable().aspectRatio(contentMode: .fit).padding(12)
                            } else if items.isEmpty {
                                VStack(spacing: 10) {
                                    Image(systemName: "square.grid.3x3").font(.largeTitle)
                                    Text("Check folders on the left, or drop files from Finder")
                                    Text("Images will appear here, ready for your contact sheet")
                                        .font(.caption)
                                }.foregroundStyle(.secondary)
                            } else {
                                ScrollView {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 170), spacing: 10)], spacing: 12) {
                                        ForEach(items) { item in
                                            VStack(spacing: 4) {
                                                ContactImageThumbnail(url: item.url)
                                                    .frame(height: 105)
                                                Text(item.name).font(.caption2).lineLimit(1)
                                            }
                                            .help(item.url.path)
                                        }
                                    }.padding(12)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                    guard let url else { return }
                                    DispatchQueue.main.async { addURLs([url]) }
                                }
                            }
                            return !providers.isEmpty
                        }
                    }
                    HStack(spacing: 8) {
                        contactStat("photo.on.rectangle.angled", title: "IMAGES", value: items.count.formatted(), tint: .blue)
                        contactStat("doc.on.doc", title: "PAGES", value: pageCount.formatted(), tint: .purple)
                        contactStat("internaldrive", title: "EST. PDF", value: estimating ? "Calculating…" : byteString(estimatedBytes), tint: .green)
                    }
                    .padding(.top, 3)
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contactSettingsPanel: some View {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox("Page Layout") {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("Width (in)")
                                    Spacer()
                                    TextField("Width", value: $pageWidth, format: .number.precision(.fractionLength(1)))
                                        .frame(width: 60)
                                    Text("Height (in)")
                                    TextField("Height", value: $pageHeight, format: .number.precision(.fractionLength(1)))
                                        .frame(width: 60)
                                }
                                HStack {
                                    Text("Rows")
                                    Stepper("\(rows)", value: $rows, in: 1...20)
                                    Text("Columns")
                                    Stepper("\(columns)", value: $columns, in: 1...20)
                                }
                                HStack {
                                    Text("Margin (in)")
                                    Slider(value: $margin, in: 0...1, step: 0.05)
                                    Text(String(format: "%.2f", margin)).monospacedDigit().frame(width: 38)
                                }
                            }.padding(5)
                        }
                        GroupBox("Image Labels") {
                            VStack(alignment: .leading, spacing: 7) {
                                Toggle("Show filenames", isOn: $showNames)
                                Toggle("Include file extension", isOn: $showExtension).disabled(!showNames)
                                Toggle("Single line (truncated filename)", isOn: $singleLine).disabled(!showNames)
                                HStack {
                                    Text("Font size")
                                    Slider(value: $fontSize, in: 6...18, step: 1)
                                    Text("\(Int(fontSize)) pt").frame(width: 40)
                                }.disabled(!showNames)
                            }.padding(5)
                        }
                        GroupBox("Compression") {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text("JPEG quality")
                                    Slider(value: $quality, in: 20...100, step: 5)
                                    Text("\(Int(quality))%").frame(width: 42)
                                }
                                HStack {
                                    Text("Image resolution")
                                    Picker("", selection: $dpi) {
                                        Text("72 dpi").tag(72.0)
                                        Text("120 dpi").tag(120.0)
                                        Text("180 dpi").tag(180.0)
                                        Text("240 dpi").tag(240.0)
                                        Text("300 dpi").tag(300.0)
                                    }.labelsHidden()
                                }
                                Text("Images are resampled to their PDF cell size. The size estimate uses compressed samples and may differ from the final PDF.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }.padding(5)
                        }
                        GroupBox("Header & Footer") {
                            VStack(spacing: 7) {
                                TextField("Header (optional)", text: $header)
                                TextField("Footer (optional)", text: $footer)
                            }.padding(5)
                        }
                        GroupBox("Logos & Branding") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Add logos anywhere in the page header or footer.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Button {
                                        chooseLogo()
                                    } label: {
                                        Label("Add Logo", systemImage: "plus")
                                    }
                                }
                                if logos.isEmpty {
                                    Label("No logos added", systemImage: "photo.badge.plus")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 42)
                                }
                                ForEach($logos) { $logo in
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            ContactLogoThumbnail(url: logo.url)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(logo.url.deletingPathExtension().lastPathComponent)
                                                    .font(.caption).fontWeight(.medium)
                                                    .lineLimit(1).truncationMode(.middle)
                                                Text(logo.url.pathExtension.uppercased() + " logo")
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Button {
                                                logos.removeAll { $0.id == logo.id }
                                                refresh()
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .buttonStyle(.borderless)
                                            .help("Remove logo")
                                        }
                                        Picker("Position", selection: $logo.placement) {
                                            ForEach(contactLogoPlacements, id: \.self) { place in
                                                Text(place).tag(place)
                                            }
                                        }
                                        HStack {
                                            Text("Width")
                                            Slider(value: $logo.widthPercent, in: 5...40, step: 1)
                                            Text("\(Int(logo.widthPercent))%")
                                                .frame(width: 42).monospacedDigit()
                                        }
                                        Toggle("First page only", isOn: $logo.firstPageOnly)
                                    }
                                    .padding(9)
                                    .background(Color.purple.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.purple.opacity(0.15)))
                                }
                            }
                            .padding(5)
                        }
                        GroupBox("PDF Metadata") {
                            VStack(spacing: 7) {
                                TextField("Title", text: $title)
                                TextField("Author", text: $author)
                                TextField("Subject", text: $subject)
                            }.padding(5)
                        }
                    }
                }
                .frame(minWidth: 255, idealWidth: 320, maxWidth: 380)
    }

    @ViewBuilder
    private var exportProgressPanel: some View {
            if exporting {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Exporting contact sheet PDF…").font(.subheadline).bold()
                        Spacer()
                        Text("Page \(exportedPages) of \(totalExportPages) · \(Int(exportProgress * 100))%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: exportProgress, total: 1.0)
                        .progressViewStyle(.linear)
                }
                .padding(.top, 12)
                .accessibilityLabel("PDF export progress")
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            contactToolbar
            HStack(alignment: .top, spacing: 14) {
                workspaceExplorer
                contactPreviewPanel
                contactSettingsPanel
            }
            exportProgressPanel
        }
        .padding(16)
        .onChange(of: renderSettingsSignature) { _, _ in refresh() }
        .onAppear { restoreSelection(); rebuildImages() }
        .onChange(of: selectedFolderPaths) { _, _ in saveSelection(); rebuildImages() }
        .onChange(of: sessionRoot?.standardizedFileURL.path) { _, _ in restoreSelection(); rebuildImages() }
        .onReceive(NotificationCenter.default.publisher(for: .digiSuiteContactFolder)) { notification in
            guard let url = notification.object as? URL, let root = sessionRoot else { return }
            let rootPath = root.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { return }
            selectedFolderPaths.insert(path)
        }

    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return formatter.string(fromByteCount: bytes)
    }
    private var selectionStorageKey: String? {
        guard let root = sessionRoot else { return nil }
        return "DigiSuite.ContactSheets.Folders." + root.standardizedFileURL.path
    }
    private func restoreSelection() {
        if let key = selectionStorageKey {
            selectedFolderPaths = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        } else { selectedFolderPaths = [] }
    }
    private func saveSelection() {
        guard let key = selectionStorageKey else { return }
        UserDefaults.standard.set(selectedFolderPaths.sorted(), forKey: key)
    }
    private func rebuildImages() {
        let rootPath = sessionRoot?.standardizedFileURL.path
        let folders = selectedFolderPaths.sorted().compactMap { path -> URL? in
            guard let rootPath, path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        scanGeneration += 1
        let scanID = scanGeneration
        let targets = folders + externalURLs
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = collectImages(targets)
            DispatchQueue.main.async {
                guard scanID == scanGeneration else { return }
                items = urls.map { ContactItem(url: $0) }
                scanning = false
                pageIndex = 0
                refresh()
            }
        }
    }
    // Discover files using macOS type metadata, not a fixed JPEG/PNG extension list.
    // ImageIO is the final fallback for camera formats with unusual extensions.
    private func isSupportedImage(_ file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        // Explicit camera RAW and professional formats, including types not registered
        // with Launch Services on every version of macOS.
        let cameraAndProExtensions: Set<String> = [
            "raf", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2",
            "dng", "rw2", "rwl", "orf", "pef", "ptx", "3fr", "fff", "iiq",
            "mos", "mrw", "erf", "k25", "kdc", "dcr", "raw", "x3f", "bay",
            "cap", "eip", "mef", "mdc", "obm", "qtk", "rdc", "sti", "pxn",
            "jpg", "jpeg", "jpe", "png", "tif", "tiff", "heic", "heif",
            "webp", "gif", "bmp", "psd", "psb", "jp2", "j2k", "jpf",
            "avif", "exr", "hdr", "tga", "ico", "icns"
        ]
        if cameraAndProExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return true }
        // ImageIO can recognize some files even without a registered extension.
        return false // Unregistered formats are not probed during directory scans.
    }
    private func collectImages(_ urls: [URL]) -> [URL] {
        var unique: [String: URL] = [:]
        let fm = FileManager.default
        for url in urls {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            if directory.boolValue {
                guard let iterator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let file as URL in iterator {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    if isSupportedImage(file) {
                        unique[file.standardizedFileURL.path] = file
                    }
                }
            } else if isSupportedImage(url) {
                unique[url.standardizedFileURL.path] = url
            }
        }
        return unique.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    private func addURLs(_ urls: [URL]) {
        // External drag-and-drop stays independent of workspace checkbox selections.
        let known = Set(externalURLs.map { $0.standardizedFileURL.path })
        externalURLs += urls.filter { !known.contains($0.standardizedFileURL.path) }
        rebuildImages()
    }
    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Select images or folders of images"
        guard panel.runModal() == .OK else { return }
        addURLs(panel.urls)
    }
    private func config() -> ContactPDFConfig {
        ContactPDFConfig(rows: rows, columns: columns,
                         width: CGFloat(max(2,pageWidth) * 72), height: CGFloat(max(2,pageHeight) * 72),
                         margin: CGFloat(min(max(0,margin) * 72, max(2,min(pageWidth,pageHeight) * 18))),
                         filenames: showNames, extensionShown: showExtension,
                         singleLine: singleLine, fontSize: CGFloat(fontSize),
                         quality: CGFloat(quality / 100), dpi: CGFloat(dpi), header: header, footer: footer, logos: logos)
    }
    private func refresh() {
        pageIndex = min(pageIndex, max(0,pageCount - 1))
        if showPagePreview { refreshPreview() }
        generation += 1
        let current = generation
        let urls = items.map(\.url)
        let settings = config()
        estimating = !urls.isEmpty
        if urls.isEmpty { estimatedBytes = 0; return }
        DispatchQueue.global(qos: .utility).async {
            let bytes = ContactPDFRenderer.estimate(urls: urls, config: settings)
            DispatchQueue.main.async {
                if current == generation { estimatedBytes = bytes; estimating = false }
            }
        }
    }
    private func refreshPreview() {
        let urls = Array(items.dropFirst(pageIndex * perPage).prefix(perPage)).map(\.url)
        let settings = config()
        guard !urls.isEmpty else { preview = nil; return }
        guard showPagePreview else { return }
        // Preview rendering is deferred until explicitly requested.
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = ContactPDFRenderer.preview(urls: urls, config: settings, pageIndex: pageIndex)
            DispatchQueue.main.async { if showPagePreview { preview = rendered } }
        }
    }
    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (title.isEmpty ? "Contact Sheet" : title) + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        exportProgress = 0
        exportedPages = 0
        totalExportPages = pageCount
        message = "Exporting PDF…"
        let urls = items.map(\.url)
        let settings = config()
        let metadata = [kCGPDFContextTitle as String: title,
                        kCGPDFContextAuthor as String: author,
                        kCGPDFContextSubject as String: subject]
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ContactPDFRenderer.export(urls: urls, config: settings, to: url, metadata: metadata) { finished, total in
                DispatchQueue.main.async {
                    exportedPages = finished
                    totalExportPages = total
                    // Reserve the final 2% for closing the PDF file.
                    exportProgress = total > 0 ? Double(finished) / Double(total) * 0.98 : 0
                }
            }
            DispatchQueue.main.async {
                if case .success = result { exportProgress = 1 }
                exporting = false
                switch result {
                case .success(let bytes):
                    estimatedBytes = bytes
                    message = "Saved \(byteString(bytes)) to \(url.lastPathComponent)"
                case .failure(let error):
                    message = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct ContactPDFConfig {
    let rows: Int, columns: Int
    let width: CGFloat, height: CGFloat, margin: CGFloat
    let filenames: Bool, extensionShown: Bool, singleLine: Bool
    let fontSize: CGFloat, quality: CGFloat, dpi: CGFloat
    let header: String, footer: String
    let logos: [ContactLogo]
    var topLogoHeight: CGFloat { logos.contains(where: { $0.placement.hasPrefix("Top") }) ? 58 : 0 }
    var bottomLogoHeight: CGFloat { logos.contains(where: { $0.placement.hasPrefix("Bottom") }) ? 58 : 0 }
    var perPage: Int { rows * columns }
    var cellWidth: CGFloat { max(12, (width - 2 * margin) / CGFloat(columns)) }
    var cellHeight: CGFloat { max(12, (height - 2 * margin - (header.isEmpty ? 0 : 18) - (footer.isEmpty ? 0 : 18) - topLogoHeight - bottomLogoHeight) / CGFloat(rows)) }
}
private enum ContactPDFRenderer {
    static func image(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(80, maxPixels)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }
    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
    static func imageData(_ url: URL, config: ContactPDFConfig) -> Data? {
        let maxPixel = Int(max(config.cellWidth, config.cellHeight) / 72 * config.dpi)
        guard let cg = image(url, maxPixels: maxPixel) else { return nil }
        return jpeg(cg, quality: config.quality)
    }
    static func estimate(urls: [URL], config: ContactPDFConfig) -> Int64 {
        // Estimate from a small sample; never decode thousands of RAW files for a size estimate.
        let sample = Array(urls.prefix(3))
        let sizes = sample.compactMap { imageData($0, config: config)?.count }
        guard !sizes.isEmpty else { return 0 }
        let avg = Double(sizes.reduce(0,+)) / Double(sizes.count)
        let pages = (urls.count + config.perPage - 1) / config.perPage
        return Int64(avg * Double(urls.count) + Double(pages) * 2200 + 4096)
    }
    static func preview(urls: [URL], config: ContactPDFConfig, pageIndex: Int = 0) -> NSImage? {
        let factor: CGFloat = min(1, 700 / max(config.width, config.height))
        let size = CGSize(width: config.width * factor, height: config.height * factor)
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return result }
        context.saveGState()
        context.scaleBy(x: factor, y: factor)
        drawPage(context: context, urls: urls, config: config, pageIndex: pageIndex)
        context.restoreGState()
        return result
    }
    static func export(urls: [URL], config: ContactPDFConfig, to url: URL, metadata: [String: String], progress: @escaping (Int, Int) -> Void) -> Result<Int64, Error> {
        let bounds = CGRect(x: 0, y: 0, width: config.width, height: config.height)
        var mediaBox = bounds
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary) else {
            return .failure(NSError(domain: "DigiTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF"]))
        }
        let totalPages = (urls.count + config.perPage - 1) / config.perPage
        var finishedPages = 0
        for start in stride(from: 0, to: urls.count, by: config.perPage) {
            ctx.beginPDFPage(nil)
            drawPage(context: ctx, urls: Array(urls[start..<min(urls.count,start+config.perPage)]), config: config, pageIndex: finishedPages)
            ctx.endPDFPage()
            finishedPages += 1
            progress(finishedPages, totalPages)
        }
        ctx.closePDF()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return .success(bytes)
    }
    static func drawPage(context: CGContext, urls: [URL], config: ContactPDFConfig, pageIndex: Int) {
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: config.width, height: config.height))
        let font = NSFont.systemFont(ofSize: config.fontSize)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style]
        if !config.header.isEmpty {
            drawText(config.header, in: CGRect(x: config.margin, y: config.height-config.margin-15,
                                               width: config.width-2*config.margin, height: 15), context: context, attrs: attrs)
        }
        if !config.footer.isEmpty {
            drawText(config.footer, in: CGRect(x: config.margin, y: config.margin,
                                               width: config.width-2*config.margin, height: 15), context: context, attrs: attrs)
        }
        drawLogos(context: context, config: config, pageIndex: pageIndex)
        let top = config.height - config.margin - (config.header.isEmpty ? 0 : 18) - config.topLogoHeight
        for (i,url) in urls.enumerated() {
            let col = i % config.columns
            let row = i / config.columns
            let cell = CGRect(x: config.margin + CGFloat(col)*config.cellWidth,
                              y: top - CGFloat(row+1)*config.cellHeight,
                              width: config.cellWidth, height: config.cellHeight)
            let imgBox = cell.insetBy(dx: 5, dy: 5)
            // Reserve enough vertical space for the longest filename in this row.
            // A shared row height keeps all thumbnails aligned across columns.
            let rowURLs = Array(urls.dropFirst(row * config.columns).prefix(config.columns))
            let labelHeight: CGFloat = config.filenames ? (config.singleLine
                ? config.fontSize * 1.8
                : min(max(config.fontSize * 2.8, rowURLs.map { item in
                    let filename = config.extensionShown ? item.lastPathComponent : item.deletingPathExtension().lastPathComponent
                    return measuredLabelHeight(filename, width: imgBox.width, font: font)
                }.max() ?? 0), max(config.fontSize * 2.8, imgBox.height - 35))) : 0
            let imageRect = CGRect(x: imgBox.minX, y: imgBox.minY+labelHeight,
                                   width: imgBox.width, height: max(1,imgBox.height-labelHeight))
            if let data = imageData(url, config: config),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let scale = min(imageRect.width / CGFloat(image.width), imageRect.height / CGFloat(image.height))
                let w = CGFloat(image.width)*scale, h = CGFloat(image.height)*scale
                let rect = CGRect(x: imageRect.midX-w/2, y: imageRect.midY-h/2, width: w, height: h)
                context.draw(image, in: rect)
            }
            if config.filenames {
                let name = config.extensionShown ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
                drawFittedLabel(name, in: CGRect(x: imgBox.minX, y: imgBox.minY,
                                                 width: imgBox.width, height: labelHeight),
                                context: context, font: font, singleLine: config.singleLine)
            }
        }
    }
    static func drawLogos(context: CGContext, config: ContactPDFConfig, pageIndex: Int) {
        let available = config.width - 2 * config.margin
        let groups = Dictionary(grouping: config.logos.filter { !$0.firstPageOnly || pageIndex == 0 }, by: { $0.placement })
        for (position, entries) in groups {
            let isTop = position.hasPrefix("Top")
            let bandHeight: CGFloat = 52
            let bandY = isTop
                ? config.height - config.margin - (config.header.isEmpty ? 0 : 18) - bandHeight
                : config.margin + (config.footer.isEmpty ? 0 : 18)
            let maxWidth = available / 3 - 8
            // Multiple logos at the same anchor share its column vertically.
            let slotHeight = bandHeight / CGFloat(max(1, entries.count))
            for (index, logo) in entries.enumerated() {
                guard let image = NSImage(contentsOf: logo.url),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      cgImage.width > 0, cgImage.height > 0 else { continue }
                let targetWidth = min(maxWidth, available * CGFloat(logo.widthPercent / 100))
                let scale = min(targetWidth / CGFloat(cgImage.width),
                                (slotHeight - 3) / CGFloat(cgImage.height))
                let w = CGFloat(cgImage.width) * scale
                let h = CGFloat(cgImage.height) * scale
                let x: CGFloat
                if position.hasSuffix("left") { x = config.margin + (maxWidth - w) / 2 }
                else if position.hasSuffix("right") { x = config.width - config.margin - maxWidth + (maxWidth - w) / 2 }
                else { x = (config.width - w) / 2 }
                let y = bandY + bandHeight - CGFloat(index + 1) * slotHeight + (slotHeight - h) / 2
                context.draw(cgImage, in: CGRect(x: x, y: y, width: w, height: h))
            }
        }
    }

    static func measuredLabelHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        let attr = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRangeMake(0, 0), nil,
            CGSize(width: max(1, width - 4), height: CGFloat.greatestFiniteMagnitude), nil)
        return ceil(size.height + fontSizePadding(font))
    }
    static func fontSizePadding(_ font: NSFont) -> CGFloat { max(4, font.pointSize * 0.35) }

    static func drawFittedLabel(_ text: String, in rect: CGRect, context: CGContext, font: NSFont, singleLine: Bool) {
        guard rect.width > 2, rect.height > 2 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = singleLine ? .byTruncatingMiddle : .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
        context.saveGState()
        context.clip(to: rect)
        if singleLine {
            // CTLine does not automatically truncate when drawn directly. Explicitly truncate to the cell width.
            let original = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let line = CTLineCreateTruncatedLine(original, Double(max(1, rect.width - 2)), .middle, token) ?? original
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.textPosition = CGPoint(x: rect.midX - lineWidth / 2, y: rect.midY - font.ascender / 2)
            CTLineDraw(line, context)
        } else {
            // A CoreText frame wraps to the available width, and clipping prevents spillover into adjacent cells.
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: rect.insetBy(dx: 1, dy: 1), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nil)
            CTFrameDraw(frame, context)
        }
        context.restoreGState()
    }

    static func drawText(_ text: String, in rect: CGRect, context: CGContext, attrs: [NSAttributedString.Key: Any]) {
        context.saveGState()
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: rect.minX + max(0,(rect.width-CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil)))/2),
                                       y: rect.midY - 3)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}


private struct WorkspaceContactPicker: View {
    let root: URL
    @Binding var selected: Set<String>
    let onApply: () -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Contact Sheet Folders").font(.title3.bold())
            Text("Select folders from the active workspace. Nested folders are included; duplicate images are removed.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                WorkspaceContactNode(url: root, depth: 0, selected: $selected)
            }.frame(minWidth: 420, minHeight: 340)
            HStack {
                Button("Clear") { selected.removeAll() }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Use Selected Folders", action: onApply).buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }.padding(20)
    }
}
private struct WorkspaceContactNode: View {
    let url: URL
    let depth: Int
    @Binding var selected: Set<String>
    @State private var expanded = false
    private var children: [URL] {
        guard depth < 12 else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right") }
                    .buttonStyle(.plain)
                Toggle(isOn: Binding(get: { selected.contains(url.path) }, set: { checked in
                    if checked { selected.insert(url.path) } else { selected.remove(url.path) }
                })) { Label(url.lastPathComponent, systemImage: "folder") }
                    .toggleStyle(.checkbox)
            }.padding(.leading, CGFloat(depth * 15))
            if expanded {
                ForEach(children, id: \.path) { child in
                    WorkspaceContactNode(url: child, depth: depth + 1, selected: $selected)
                }
            }
        }
    }
}


private enum ContactThumbnailStore {
    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 350
        c.totalCostLimit = 120 * 1024 * 1024
        return c
    }()
    static let queue = DispatchQueue(label: "DigiSuite.ContactThumbnails", qos: .utility, attributes: .concurrent)
    static let slots = DispatchSemaphore(value: 3)
}

private struct ContactImageThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.18))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(3)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .onAppear { load() }
        .onChange(of: url) { _, _ in image = nil; load() }
    }
    private func load() {
        let key = url.standardizedFileURL.path as NSString
        if let cached = ContactThumbnailStore.cache.object(forKey: key) {
            image = cached
            return
        }
        let requestedURL = url
        ContactThumbnailStore.queue.async {
            ContactThumbnailStore.slots.wait()
            defer { ContactThumbnailStore.slots.signal() }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false
            ]
            var result: NSImage?
            if let source = CGImageSourceCreateWithURL(requestedURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            if let result {
                ContactThumbnailStore.cache.setObject(result, forKey: key, cost: 240 * 240 * 4)
            }
            DispatchQueue.main.async {
                if requestedURL == url { image = result }
            }
        }
    }
}


// Dedicated Contact Sheets tree. Selection is owned by the workspace's ContactSheetsView.
private struct ContactFolderPicker: View {
    let root: URL?
    @Binding var selectedPaths: Set<String>
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let root {
                ScrollView {
                    ContactFolderCheckNode(url: root, depth: 0, selectedPaths: $selectedPaths)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Parent folders include images in all subfolders. Overlapping selections never duplicate images.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Open a workspace to browse its folders.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ContactFolderCheckNode: View {
    let url: URL
    let depth: Int
    @Binding var selectedPaths: Set<String>
    @State private var expanded = false
    private var path: String { url.standardizedFileURL.path }
    private var children: [URL] {
        guard depth < 12 else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    private var includedByParent: Bool {
        selectedPaths.contains { path.hasPrefix($0 + "/") }
    }
    private var hasSelectedDescendant: Bool {
        selectedPaths.contains { $0.hasPrefix(path + "/") }
    }
    private var folderTint: Color {
        let name = url.lastPathComponent.lowercased()
        if name.contains("capture") { return .blue }
        if name.contains("output") { return .green }
        if name.contains("select") { return .purple }
        if name.contains("trash") { return .gray }
        return .cyan
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 17, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(children.isEmpty)
                Toggle(isOn: Binding(
                    get: { selectedPaths.contains(path) || includedByParent },
                    set: { checked in
                        if checked {
                            selectedPaths.insert(path)
                        } else {
                            // Unchecking a child of a selected parent must exclude that child:
                            // replace each selected ancestor with its siblings along the path.
                            let ancestors = selectedPaths.filter { path.hasPrefix($0 + "/") }
                            for ancestor in ancestors {
                                selectedPaths.remove(ancestor)
                                var cursor = URL(fileURLWithPath: ancestor, isDirectory: true)
                                let components = String(path.dropFirst(ancestor.count + 1)).split(separator: "/")
                                for component in components {
                                    let next = cursor.appendingPathComponent(String(component), isDirectory: true)
                                    let siblings = ((try? FileManager.default.contentsOfDirectory(at: cursor, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                                        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                                    for sibling in siblings where sibling.standardizedFileURL.path != next.standardizedFileURL.path {
                                        selectedPaths.insert(sibling.standardizedFileURL.path)
                                    }
                                    cursor = next
                                }
                            }
                            selectedPaths = selectedPaths.filter { $0 != path && !$0.hasPrefix(path + "/") }
                        }
                    }
                )) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(folderTint)
                        Text(url.lastPathComponent).lineLimit(1)
                            .font(.system(size: 14, weight: depth == 0 ? .semibold : .regular))
                        if hasSelectedDescendant && !selectedPaths.contains(path) && !includedByParent {
                            Image(systemName: "minus.square.fill").foregroundStyle(.secondary)
                                .help("Some subfolders are selected")
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .onDrag { NSItemProvider(object: url as NSURL) }
            }
            .padding(.leading, CGFloat(depth * 16))
            .padding(.vertical, 5)
            .padding(.horizontal, 5)
            .background((selectedPaths.contains(path) || includedByParent) ? folderTint.opacity(0.10) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 9))
            if expanded {
                ForEach(children, id: \.path) { child in
                    ContactFolderCheckNode(url: child, depth: depth + 1, selectedPaths: $selectedPaths)
                }
            }
        }
    }
}
