import Foundation
import ImageIO
import CoreGraphics

// v1.42: IPTC metadata as sidecar .xmp files next to each raw. The raw is never
// written. Capture One (Preferences > Image > Auto Sync Sidecar XMP = Load) picks
// the sidecar up on its own (tested Nov 10, Capture One 16.9, session open).
// Foundation only, so the smoke tests can use it.

struct MetadataField: Sendable {
    let label: String
    let tag: String
    let wide: Bool
    let list: Bool
    init(_ label: String, _ tag: String, wide: Bool = false, list: Bool = false) {
        self.label = label
        self.tag = tag
        self.wide = wide
        self.list = list
    }
}

struct MetadataSection: Sendable {
    let title: String
    let fields: [MetadataField]
}

enum MetadataFields {
    /// v1.43: the same sections, order and labels as Capture One's Metadata tool,
    /// so a field here is the field you see there.
    static let sections: [MetadataSection] = [
        MetadataSection(title: "IPTC - Contact", fields: [
            MetadataField("Creator", "XMP-dc:Creator"),
            MetadataField("Creator's Job Title", "XMP-photoshop:AuthorsPosition"),
            MetadataField("Address", "XMP-iptcCore:CreatorAddress"),
            MetadataField("City", "XMP-iptcCore:CreatorCity"),
            MetadataField("State/Province", "XMP-iptcCore:CreatorRegion"),
            MetadataField("Postal code", "XMP-iptcCore:CreatorPostalCode"),
            MetadataField("Country", "XMP-iptcCore:CreatorCountry"),
            MetadataField("Phone(s)", "XMP-iptcCore:CreatorWorkTelephone"),
            MetadataField("E-Mail(s)", "XMP-iptcCore:CreatorWorkEmail"),
            MetadataField("Website(s)", "XMP-iptcCore:CreatorWorkURL")
        ]),
        MetadataSection(title: "IPTC - Content", fields: [
            MetadataField("Headline", "XMP-photoshop:Headline"),
            MetadataField("Description", "XMP-dc:Description", wide: true),
            MetadataField("Category", "XMP-photoshop:Category"),
            MetadataField("Supplemental Categories", "XMP-photoshop:SupplementalCategories", list: true),
            MetadataField("IPTC subject code", "XMP-iptcCore:SubjectCode", list: true),
            MetadataField("Description Writer", "XMP-photoshop:CaptionWriter")
        ]),
        MetadataSection(title: "IPTC - Image", fields: [
            MetadataField("Intellectual genre", "XMP-iptcCore:IntellectualGenre"),
            MetadataField("IPTC scene", "XMP-iptcCore:Scene", list: true),
            MetadataField("Location", "XMP-iptcCore:Location"),
            MetadataField("City", "XMP-photoshop:City"),
            MetadataField("State/Province", "XMP-photoshop:State"),
            MetadataField("Country", "XMP-photoshop:Country"),
            MetadataField("ISO Country Code", "XMP-iptcCore:CountryCode")
        ]),
        MetadataSection(title: "IPTC - Status", fields: [
            MetadataField("Title", "XMP-dc:Title"),
            MetadataField("Job Identifier", "XMP-photoshop:TransmissionReference"),
            MetadataField("Instructions", "XMP-photoshop:Instructions"),
            MetadataField("Provider", "XMP-photoshop:Credit"),
            MetadataField("Source", "XMP-photoshop:Source"),
            MetadataField("Copyright Notice", "XMP-dc:Rights"),
            MetadataField("Rights usage terms", "XMP-xmpRights:UsageTerms")
        ]),
        MetadataSection(title: "IPTC - Getty Images", fields: [
            MetadataField("Personality", "XMP-getty:Personality", list: true),
            MetadataField("Original Filename", "XMP-getty:OriginalFileName"),
            MetadataField("Parent MEID", "XMP-getty:ParentMEID")
        ]),
        MetadataSection(title: "Keywords", fields: [
            MetadataField("Keywords", "XMP-dc:Subject", wide: true, list: true)
        ])
    ]
    /// v1.43.6: the everyday fields shown up top (Capture One's names); the rest sit in
    /// their Capture One sections behind "More IPTC fields".
    static let topTags: [String] = [
        "XMP-dc:Creator", "XMP-dc:Rights", "XMP-photoshop:Credit",
        "XMP-photoshop:Headline", "XMP-photoshop:TransmissionReference", "XMP-xmpRights:UsageTerms",
        "XMP-dc:Description", "XMP-dc:Subject"
    ]
    static var top: [MetadataField] {
        topTags.compactMap { tag in all.first(where: { $0.tag == tag }) }
    }
    static var all: [MetadataField] { sections.flatMap(\.fields) }
    static var allTags: Set<String> { Set(all.map(\.tag)) }
    /// Fields that hold a list (written one item per comma).
    static var listTags: Set<String> { Set(all.filter(\.list).map(\.tag)) }
    /// Our tag for ExifTool's spelling of it (ExifTool's output may differ in case).
    static func canonicalTag(_ tag: String) -> String? {
        let lower: String = tag.lowercased()
        return all.first(where: { $0.tag.lowercased() == lower })?.tag
    }
}

enum MetadataSidecar {
    static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "iiq", "eip", "3fr", "fff", "orf", "rw2", "pef", "srw", "raw", "mos", "rwl", "x3f", "gpr"]

    /// v1.44: finished images that can carry metadata inside the file (opt-in).
    static let embeddableExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff", "png"]

    static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }
    static func isEmbeddable(_ url: URL) -> Bool { embeddableExtensions.contains(url.pathExtension.lowercased()) }

    /// The sidecar Capture One and Lightroom look for: same name, .xmp.
    static func sidecarURL(for raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// {year}, {date} (yyyy-MM-dd), {session} and {filename} (the raw's name) in a field's text.
    static func fillIns(_ text: String, session: String, filename: String = "", now: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year: Int = calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var result: String = text.replacingOccurrences(of: "{year}", with: String(year))
        result = result.replacingOccurrences(of: "{date}", with: formatter.string(from: now))
        result = result.replacingOccurrences(of: "{session}", with: session)
        result = result.replacingOccurrences(of: "{filename}", with: filename)
        return result
    }

    /// "a, b;c" -> "a, b, c" (empty items dropped).
    static func normalizedList(_ text: String) -> String {
        let separators = CharacterSet(charactersIn: ",;\n")
        var items: [String] = []
        for part in text.components(separatedBy: separators) {
            let item: String = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty { items.append(item) }
        }
        return items.joined(separator: ", ")
    }

    /// The values that will actually be written: fill-ins resolved, empty fields left out.
    static func resolvedValues(_ values: [String: String], session: String, filename: String = "", now: Date = Date()) -> [String: String] {
        var result: [String: String] = [:]
        let known: Set<String> = MetadataFields.allTags
        for (tag, raw) in values where known.contains(tag) {
            var value: String = fillIns(raw, session: session, filename: filename, now: now).trimmingCharacters(in: .whitespacesAndNewlines)
            if MetadataFields.listTags.contains(tag) { value = normalizedList(value) }
            if !value.isEmpty { result[tag] = value }
        }
        return result
    }

    /// A session's name for {session}: the folder above Capture, else the folder itself.
    static func sessionName(for folder: URL) -> String {
        if folder.lastPathComponent.lowercased() == "capture" {
            return folder.deletingLastPathComponent().lastPathComponent
        }
        return folder.lastPathComponent
    }

    /// v1.45: ExifTool ships inside the app (vendor/ExifTool, run with macOS's own Perl), so
    /// nobody has to install it. Order: the app's copy, the project's copy (smoke tests),
    /// then an installed one (Homebrew / exiftool.org) if macOS ever drops Perl.
    static let perlPath = "/usr/bin/perl"

    static func bundledExiftool() -> String? {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: perlPath) else { return nil }
        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("vendor/ExifTool/exiftool").path)
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("vendor/ExifTool/exiftool").path)
        for path in candidates where fm.fileExists(atPath: path) { return path }
        return nil
    }

    static func exiftoolPath() -> String? {
        if let bundled = bundledExiftool() { return bundled }
        for path in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// A bundled copy is a Perl script: run it with /usr/bin/perl.
    static func isScriptCopy(_ tool: String) -> Bool {
        tool.hasSuffix("/vendor/ExifTool/exiftool")
    }

    /// Runs ExifTool; returns exit code, standard output and error output.
    static func run(_ tool: String, _ args: [String]) -> (Int32, String, String) {
        let task = Process()
        if isScriptCopy(tool) {
            task.executableURL = URL(fileURLWithPath: perlPath)
            task.arguments = [tool] + args
        } else {
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = args
        }
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
            let outData: Data = out.fileHandleForReading.readDataToEndOfFile()
            let errData: Data = err.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let outText: String = String(data: outData, encoding: .utf8) ?? ""
            let errText: String = String(data: errData, encoding: .utf8) ?? ""
            return (task.terminationStatus, outText, errText)
        } catch {
            return (1, "", error.localizedDescription)
        }
    }

    /// ExifTool -j -G1 output -> [tag: text], tags LOWERCASED (ExifTool's case can differ
    /// from ours). Lists are joined with ", ".
    static func jsonValues(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = parsed.first else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in first where key != "SourceFile" {
            let lower: String = key.lowercased()
            if let list = value as? [Any] {
                result[lower] = list.map { "\($0)" }.joined(separator: ", ")
            } else {
                result[lower] = "\(value)"
            }
        }
        return result
    }

    static func readTags(tool: String, file: URL, tags: [String]) -> [String: String] {
        // JSONQ quotes every value: without it ExifTool prints "2026.10" as the number 2026.1.
        var args: [String] = ["-j", "-G1", "-api", "StructFormat=JSONQ"]
        for tag in tags { args.append("-" + tag) }
        args.append(file.path)
        let (_, out, _) = run(tool, args)
        return jsonValues(out)
    }

    /// An empty XMP packet ExifTool can add fields to.
    static let emptyPacket: String = "<?xpacket begin='\u{FEFF}' id='W5M0MpCehiHzreSzNTczkc9d'?>\n<x:xmpmeta xmlns:x='adobe:ns:meta/'>\n<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>\n</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>\n"

    struct StampResult: Sendable {
        let ok: Bool
        let wrote: Int
        let kept: Int
        let message: String
    }

    /// Writes (or adds to) the raw's sidecar. keepExisting: a field that already has a
    /// value in the sidecar is left alone, so edits made in Capture One win. The raw
    /// itself is never opened for writing, and no *_original copies are left.
    static func stamp(raw: URL, tool: String, values: [String: String], keepExisting: Bool, session: String, now: Date = Date()) -> StampResult {
        let fm = FileManager.default
        let sidecar: URL = sidecarURL(for: raw)
        var toWrite: [String: String] = resolvedValues(values, session: session, filename: raw.lastPathComponent, now: now)
        if toWrite.isEmpty { return StampResult(ok: false, wrote: 0, kept: 0, message: "No fields filled in") }
        let existed: Bool = fm.fileExists(atPath: sidecar.path)
        var kept = 0
        if existed && keepExisting {
            let current: [String: String] = readTags(tool: tool, file: sidecar, tags: Array(toWrite.keys))
            for tag in Array(toWrite.keys) {
                let have: String = (current[tag.lowercased()] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !have.isEmpty {
                    toWrite[tag] = nil
                    kept += 1
                }
            }
            if toWrite.isEmpty { return StampResult(ok: true, wrote: 0, kept: kept, message: "already filled in, kept as is") }
        }
        var created = false
        if !existed {
            guard fm.createFile(atPath: sidecar.path, contents: Data(emptyPacket.utf8)) else {
                return StampResult(ok: false, wrote: 0, kept: kept, message: "Couldn't create the sidecar (no permission to write in this folder?)")
            }
            created = true
        }
        var args: [String] = ["-overwrite_original", "-sep", ", "]
        for tag in toWrite.keys.sorted() {
            let value: String = toWrite[tag] ?? ""
            args.append("-" + tag + "=" + value)
        }
        args.append(sidecar.path)
        let (code, _, errText) = run(tool, args)
        if code != 0 {
            if created { try? fm.removeItem(at: sidecar) }
            let reason: String = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            return StampResult(ok: false, wrote: 0, kept: kept, message: "ExifTool couldn't write it: " + (reason.isEmpty ? "unknown error" : reason))
        }
        // Read back: every field we wrote must be there.
        let check: [String: String] = readTags(tool: tool, file: sidecar, tags: Array(toWrite.keys))
        var missing: [String] = []
        for (tag, value) in toWrite {
            let got: String = (check[tag.lowercased()] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if got.isEmpty { missing.append(tag); continue }
            if !MetadataFields.listTags.contains(tag) && got != value { missing.append(tag) }
        }
        if !missing.isEmpty {
            return StampResult(ok: false, wrote: 0, kept: kept, message: "Read-back didn't match: " + missing.sorted().joined(separator: ", "))
        }
        let fields: String = toWrite.count == 1 ? "1 field" : "\(toWrite.count) fields"
        var message: String = (created ? "sidecar written, " : "added to sidecar, ") + fields
        if kept > 0 { message += ", kept \(kept) already set" }
        return StampResult(ok: true, wrote: toWrite.count, kept: kept, message: message)
    }

    // MARK: Embedding into finished images (v1.44, opt-in)

    /// Raws get a sidecar; JPEG/TIFF/PNG get the metadata inside the file when `embed` is on.
    static func process(file: URL, tool: String, values: [String: String], keepExisting: Bool, session: String, embed: Bool, now: Date = Date()) -> StampResult {
        if isRaw(file) { return stamp(raw: file, tool: tool, values: values, keepExisting: keepExisting, session: session, now: now) }
        if embed && isEmbeddable(file) { return embedInto(file: file, tool: tool, values: values, keepExisting: keepExisting, session: session, now: now) }
        return StampResult(ok: false, wrote: 0, kept: 0, message: "skipped (not a raw, and embedding is off)")
    }

    /// The file still decodes as an image (a tiny thumbnail is enough to prove it).
    static func imageOpens(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        guard CGImageSourceGetCount(source) > 0 else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    /// Writes the fields into the image file itself. ExifTool builds a new copy and swaps it
    /// in only when it's done (no *_original left), and only the metadata changes. The file's
    /// date changes too, on purpose, so the next backup copies the new version.
    static func embedInto(file: URL, tool: String, values: [String: String], keepExisting: Bool, session: String, now: Date = Date()) -> StampResult {
        var toWrite: [String: String] = resolvedValues(values, session: session, filename: file.lastPathComponent, now: now)
        if toWrite.isEmpty { return StampResult(ok: false, wrote: 0, kept: 0, message: "No fields filled in") }
        guard FileManager.default.isWritableFile(atPath: file.path) else {
            return StampResult(ok: false, wrote: 0, kept: 0, message: "No permission to change this file (locked or read-only); left alone")
        }
        guard imageOpens(file) else {
            return StampResult(ok: false, wrote: 0, kept: 0, message: "Doesn't open as an image; left alone")
        }
        var kept = 0
        if keepExisting {
            let current: [String: String] = readTags(tool: tool, file: file, tags: Array(toWrite.keys))
            for tag in Array(toWrite.keys) {
                let have: String = (current[tag.lowercased()] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !have.isEmpty {
                    toWrite[tag] = nil
                    kept += 1
                }
            }
            if toWrite.isEmpty { return StampResult(ok: true, wrote: 0, kept: kept, message: "already filled in, kept as is") }
        }
        var args: [String] = ["-overwrite_original", "-sep", ", "]
        for tag in toWrite.keys.sorted() {
            let value: String = toWrite[tag] ?? ""
            args.append("-" + tag + "=" + value)
        }
        args.append(file.path)
        let (code, _, errText) = run(tool, args)
        if code != 0 {
            let reason: String = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            return StampResult(ok: false, wrote: 0, kept: kept, message: "ExifTool couldn't write it (file unchanged): " + (reason.isEmpty ? "unknown error" : reason))
        }
        guard imageOpens(file) else {
            return StampResult(ok: false, wrote: 0, kept: kept, message: "Doesn't open as an image after writing. Check it, and restore it from a backup if needed")
        }
        let check: [String: String] = readTags(tool: tool, file: file, tags: Array(toWrite.keys))
        var missing: [String] = []
        for (tag, value) in toWrite {
            let got: String = (check[tag.lowercased()] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if got.isEmpty { missing.append(tag); continue }
            if !MetadataFields.listTags.contains(tag) && got != value { missing.append(tag) }
        }
        if !missing.isEmpty {
            return StampResult(ok: false, wrote: 0, kept: kept, message: "Read-back didn't match: " + missing.sorted().joined(separator: ", "))
        }
        let fields: String = toWrite.count == 1 ? "1 field" : "\(toWrite.count) fields"
        var message: String = "embedded, " + fields
        if kept > 0 { message += ", kept \(kept) already set" }
        return StampResult(ok: true, wrote: toWrite.count, kept: kept, message: message)
    }

    struct ClientLoad: Sendable {
        let values: [String: String]
        let otherFields: Int
        let error: String?
    }

    /// Reads a client's .xmp into our fields. Fields we don't show are counted, not used.
    static func loadClient(_ url: URL, tool: String) -> ClientLoad {
        let (code, out, errText) = run(tool, ["-j", "-G1", "-api", "StructFormat=JSONQ", "-XMP:all", url.path])
        if code != 0 {
            let reason: String = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClientLoad(values: [:], otherFields: 0, error: reason.isEmpty ? "ExifTool couldn't read that file." : reason)
        }
        return clientFields(jsonValues(out))
    }

    static func clientFields(_ found: [String: String]) -> ClientLoad {
        let ignoredGroups: [String] = ["xmp-x:", "xmp-xmpmm:", "xmp-xmp:", "xmp-tiff:", "xmp-exif:", "xmp-aux:", "xmp-crs:", "xmp-photoshop:iccprofilename", "xmp-photoshop:colormode"]
        var values: [String: String] = [:]
        var other = 0
        for (tag, value) in found {
            let text: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let lower: String = tag.lowercased()
            if let ours = MetadataFields.canonicalTag(lower) {
                values[ours] = text
            } else if lower.hasPrefix("xmp-") && !ignoredGroups.contains(where: { lower.hasPrefix($0) }) {
                other += 1
            }
        }
        if values.isEmpty {
            return ClientLoad(values: [:], otherFields: other, error: "That file has none of the IPTC fields this tab uses.")
        }
        return ClientLoad(values: values, otherFields: other, error: nil)
    }

    // MARK: Presets as .xmp files (v1.43)

    /// ~/Documents/Studio Session/Metadata Presets. Any .xmp in there shows up as a preset,
    /// so presets can be shared, backed up or dropped in from a client.
    static var presetsFolder: URL {
        let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appendingPathComponent("Studio Session/Metadata Presets", isDirectory: true)
    }

    static func presetFiles() -> [URL] {
        let fm = FileManager.default
        let items: [URL] = (try? fm.contentsOfDirectory(at: presetsFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let xmps: [URL] = items.filter { $0.pathExtension.lowercased() == "xmp" }
        return xmps.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A preset name safe for a file name.
    static func presetFileName(_ name: String) -> String {
        var cleaned: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\"] { cleaned = cleaned.replacingOccurrences(of: bad, with: "-") }
        if cleaned.hasPrefix(".") { cleaned = "_" + cleaned }
        if cleaned.isEmpty { cleaned = "Preset" }
        return cleaned + ".xmp"
    }

    /// Writes a preset as a fresh .xmp (fields as typed, fill-ins kept as {year} etc.),
    /// built beside the target and swapped in, so a cleared field is really gone.
    static func writePreset(_ values: [String: String], to url: URL, tool: String) -> String? {
        let fm = FileManager.default
        do { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { return "Couldn't make the presets folder: " + error.localizedDescription }
        let temp: URL = url.deletingLastPathComponent().appendingPathComponent(".preset-" + UUID().uuidString + ".xmp")
        guard fm.createFile(atPath: temp.path, contents: Data(emptyPacket.utf8)) else { return "Couldn't write the preset file." }
        var args: [String] = ["-overwrite_original", "-sep", ", "]
        let known: Set<String> = MetadataFields.allTags
        for tag in values.keys.sorted() where known.contains(tag) {
            var value: String = (values[tag] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if MetadataFields.listTags.contains(tag) { value = normalizedList(value) }
            if !value.isEmpty { args.append("-" + tag + "=" + value) }
        }
        if args.count > 3 {
            args.append(temp.path)
            let (code, _, errText) = run(tool, args)
            if code != 0 {
                try? fm.removeItem(at: temp)
                let reason: String = errText.trimmingCharacters(in: .whitespacesAndNewlines)
                return "ExifTool couldn't write the preset: " + (reason.isEmpty ? "unknown error" : reason)
            }
        }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            return "Couldn't save the preset: " + error.localizedDescription
        }
        return nil
    }

    /// Raws in a folder. Skips hidden files and Capture One's own CaptureOne folders.
    static func listRaws(in folder: URL, recursive: Bool) -> [URL] {
        listFiles(in: folder, recursive: recursive, extensions: rawExtensions)
    }

    /// Raws, plus JPEG/TIFF/PNG when `embed` is on.
    static func listWork(in folder: URL, recursive: Bool, embed: Bool) -> [URL] {
        let extensions: Set<String> = embed ? rawExtensions.union(embeddableExtensions) : rawExtensions
        return listFiles(in: folder, recursive: recursive, extensions: extensions)
    }

    static func listFiles(in folder: URL, recursive: Bool, extensions: Set<String>) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        if recursive {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if url.lastPathComponent == "CaptureOne" { walker.skipDescendants() }
                    continue
                }
                if extensions.contains(url.pathExtension.lowercased()) { result.append(url) }
            }
        } else {
            let items: [URL] = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in items where extensions.contains(url.pathExtension.lowercased()) { result.append(url) }
        }
        return result
    }

    /// Size + date: a file that stops changing between two looks is done arriving.
    static func signature(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size: Int64 = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let date: Double = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(date)"
    }
}
