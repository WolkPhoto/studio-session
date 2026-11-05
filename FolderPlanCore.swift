import Foundation

// Version 20: Folder Maker's engine, in Swift. Replaces the bundled Python
// engine (engine.py / folder_bridge.py). Reading, planning and creating are
// local only, never overwrite anything, and never accept paths that escape
// the chosen destination.
enum FolderPlan {

    // MARK: Names

    struct CleanResult: Equatable {
        let name: String?
        let adjusted: Bool
    }

    /// Makes one folder name safe for macOS. Colons and slashes become " - "
    /// (a colon shows as "/" in Finder), surrounding quotes and leading dots
    /// are removed. Returns nil for names that cannot be used.
    static func cleanComponent(_ raw: String) -> CleanResult {
        let quotes = CharacterSet(charactersIn: "\"“”'`")
        var name: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespaces)
        let original = name
        name = name.replacingOccurrences(of: "\0", with: "")
        name = name.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        name = name.replacingOccurrences(of: ":", with: " -")
        name = name.replacingOccurrences(of: "/", with: " - ")
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        while name.hasPrefix(".") || name.hasPrefix("~") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." { return CleanResult(name: nil, adjusted: true) }
        if name.count > 180 { name = String(name.prefix(180)).trimmingCharacters(in: .whitespaces) }
        return CleanResult(name: name, adjusted: name != original)
    }

    /// A relative folder path: "/" separates levels. Each level is cleaned.
    static func cleanPath(_ raw: String) -> (path: String?, adjusted: Bool) {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        let parts = unified.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return (nil, true) }
        var cleaned: [String] = []
        var adjusted = false
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed == "." || trimmed == ".." { return (nil, true) }
            let result = cleanComponent(part)
            guard let name = result.name else { return (nil, true) }
            if result.adjusted { adjusted = true }
            cleaned.append(name)
        }
        return (cleaned.joined(separator: "/"), adjusted)
    }

    /// v1.22: replaces spaces in every level of a path with "_" or "-".
    /// "Look 1 - Hero/Selects" -> "Look_1-Hero/Selects". An empty separator
    /// keeps the path as is. Unusable paths are returned unchanged so the
    /// preview still lists them as skipped.
    static func replaceSpaces(_ raw: String, with separator: String) -> String {
        guard !separator.isEmpty else { return raw }
        guard let cleaned = cleanPath(raw).path else { return raw }
        var levels: [String] = []
        for part in cleaned.split(separator: "/") {
            var name = String(part)
            name = name.replacingOccurrences(of: "\\s*-\\s*", with: "-", options: .regularExpression)
            name = name.replacingOccurrences(of: "\\s+", with: separator, options: .regularExpression)
            levels.append(name)
        }
        return levels.joined(separator: "/")
    }

    static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            guard let name = cleanComponent(item).name else { continue }
            let key = name.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(name)
        }
        return out
    }

    /// {session} -> session folder name, {date} -> today as yyyy_MM_dd.
    static func applyTokens(_ text: String, session: String?, date: Date = Date()) -> String {
        var result = text
        if result.contains("{date}") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy_MM_dd"
            result = result.replacingOccurrences(of: "{date}", with: formatter.string(from: date))
        }
        if let session, !session.isEmpty {
            result = result.replacingOccurrences(of: "{session}", with: session)
        }
        return result
    }

    /// Each base folder, followed by its subfolders: "A", "A/Selects", ...
    static func expand(_ bases: [String], subfolders: [String]) -> [String] {
        var out: [String] = []
        for base in bases {
            out.append(base)
            for sub in subfolders { out.append(base + "/" + sub) }
        }
        return out
    }

    static func splitList(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Sequences

    static func sequence(prefix: String, start: Int, end: Int, digits: Int, suffix: String, step: Int) throws -> [String] {
        guard step >= 1, digits >= 1, digits <= 8, end >= start, (end - start) / step < 1000 else {
            throw failure("Choose an ascending range of at most 1,000 folders.")
        }
        var names: [String] = []
        var value = start
        while value <= end {
            var number = String(value)
            while number.count < digits { number = "0" + number }
            names.append(prefix + number + suffix)
            value += step
        }
        return names
    }

    /// "shot-01 through shot-10", "Look1 - Look12". Never guesses from prose.
    static func interpretSequence(_ text: String) -> [String]? {
        let pattern = #"([A-Za-z][\w-]{0,55}?)(\d{1,6})\s*(?:through|to|[-–])\s*(?:([A-Za-z][\w-]{0,55}?))?(\d{1,6})\b"#
        guard let match = firstMatch(pattern, in: text, caseInsensitive: true) else { return nil }
        let prefix = match[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        let other = match[3].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        if !other.isEmpty && other.lowercased() != prefix.lowercased() { return nil }
        guard let start = Int(match[2]), let end = Int(match[4]) else { return nil }
        let digits = max(match[2].count, match[4].count)
        return try? sequence(prefix: prefix, start: start, end: end, digits: digits, suffix: "", step: 1)
    }

    // MARK: Text extraction (ported from the original engine)

    struct Extraction: Equatable {
        var names: [String] = []
        var review: [String] = []
        var excluded: [String] = []
    }

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()

    static func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = (caseInsensitive ? "i:" : "c:") + pattern
        regexLock.lock(); defer { regexLock.unlock() }
        if let cached = regexCache[key] { return cached }
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let built = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache[key] = built
        return built
    }

    static func matches(_ pattern: String, _ text: String, caseInsensitive: Bool = true) -> Bool {
        guard let rx = regex(pattern, caseInsensitive: caseInsensitive) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return rx.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Capture groups of the first match; missing groups are "".
    static func firstMatch(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> [String]? {
        guard let rx = regex(pattern, caseInsensitive: caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let found = rx.firstMatch(in: text, options: [], range: range) else { return nil }
        return groups(found, in: text)
    }

    static func allMatches(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> [[String]] {
        guard let rx = regex(pattern, caseInsensitive: caseInsensitive) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return rx.matches(in: text, options: [], range: range).map { groups($0, in: text) }
    }

    private static func groups(_ result: NSTextCheckingResult, in text: String) -> [String] {
        var out: [String] = []
        for index in 0..<result.numberOfRanges {
            let nsRange = result.range(at: index)
            if nsRange.location != NSNotFound, let range = Range(nsRange, in: text) {
                out.append(String(text[range]))
            } else {
                out.append("")
            }
        }
        return out
    }

    static func removeLeading(_ pattern: String, from text: String) -> String {
        guard let rx = regex(pattern, caseInsensitive: true) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return rx.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).count
    }

    private static func usable(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'` ").union(.whitespaces))
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." || trimmed.count > 180 { return false }
        if trimmed.contains("/") || trimmed.contains(":") || trimmed.hasPrefix(".") || trimmed.hasPrefix("~") { return false }
        return true
    }

    static let stopWords = #"\b(?:don.t|do not|skip|exclude|omit|not needed|ignore|hold off|no need|without)\b"#
    static let bulletPattern = #"^\s*(?:[-*•]|\d+[.)]|\[[ xX]\])\s*"#

    /// Conservative: never turns arbitrary prose into folder names. Smart mode
    /// reads lists, bullets, "Folder Name: description" lines and explicit
    /// requests; uncertain lines go to `review`. Literal mode: one per line.
    static func extract(_ text: String, smart: Bool, splitCommas: Bool) -> Extraction {
        if !smart {
            var parts: [String] = []
            for line in text.components(separatedBy: .newlines) {
                if splitCommas { parts.append(contentsOf: line.components(separatedBy: ",")) }
                else { parts.append(line) }
            }
            return Extraction(names: dedupe(parts), review: [], excluded: [])
        }
        var results: [String] = []
        var review: [String] = []
        var excluded: [String] = []
        var inList = false
        let lines: [String] = text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let nonEmpty: [String] = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let simpleList: Bool = lines.count <= 15 && !nonEmpty.contains { matches(#"[.!?]"#, $0) }
        let trimSet = CharacterSet.whitespaces

        for raw in lines {
            let line = raw.trimmingCharacters(in: trimSet)
            if line.isEmpty { continue }
            if line.hasPrefix(">") || matches(#"^(?:hi[!, ]|hello[!, ]|thanks\b|regards\b|best[,:]|p\.p\.s\.|p\.s\.|director of|subject:|from:|to:)"#, line) {
                inList = false
                continue
            }
            let bullet = matches(bulletPattern, line)
            let content = removeLeading(bulletPattern, from: line).trimmingCharacters(in: trimSet)
            if matches(#"^(?:please\s+)?(?:don.t|do not|never create|no folder (?:called|named)|skip creating)\b"#, content) {
                excluded.append(line)
                inList = false
                continue
            }
            if matches(#"^(?:for the |for )?[^.!?]{0,65}?(?:folders? for|folders? (?:called|named)|please separate|categories? for)\s*:\s*$"#, content) {
                inList = true
                continue
            }
            // Version 20: any heading ending in ":" that mentions folders,
            // shots, looks, scenes or a shot list also starts a list
            // ("Here are the folders for the shoot:").
            if !bullet && matches(#"^[^.!?]{0,80}?\b(?:folders?|categories?|shots?|shot list|looks?|scenes?|setups?|deliverables?)\b[^.!?]{0,50}:\s*$"#, content) {
                inList = true
                continue
            }
            if matches(#"^(?:a few other|one last thing|speaking of|oh[!,]|also[!,]|basically[!,]|first[!,]|for folder names|for the invoices|we also have|the spreadsheet|the actual|please keep|please don.t)"#, content) {
                inList = false
            }
            if bullet {
                if let heading = firstMatch(#"^(?:\*\*|__)(.{1,65}?)(?:\*\*|__)(?:\s*.*)?$"#, in: content) {
                    var candidate = heading[1].trimmingCharacters(in: trimSet)
                    while candidate.hasSuffix(":") { candidate.removeLast() }
                    candidate = candidate.trimmingCharacters(in: trimSet)
                    if usable(candidate) && wordCount(candidate) <= 8 && !matches(stopWords, candidate) {
                        results.append(candidate)
                        inList = true
                        continue
                    }
                }
                if let heading = firstMatch(#"^([^:]{2,65}):\s+.+$"#, in: content) {
                    let candidate = heading[1].trimmingCharacters(in: trimSet).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                    if usable(candidate) && wordCount(candidate) <= 7 && !matches(#"[.!?]"#, candidate) && !matches(stopWords, candidate) {
                        results.append(candidate)
                        inList = true
                        continue
                    }
                }
            }
            if let named = firstMatch(#"\b(?:folder (?:called|named)|folder for)\s+["“]?([^"”.,;!?]{1,65})"#, in: content) {
                var candidate = named[1].trimmingCharacters(in: trimSet)
                if let cut = regex(#"\s+\b(?:but|because|unless|which|so that|for anything|where)\b"#, caseInsensitive: true),
                   let hit = cut.firstMatch(in: candidate, options: [], range: NSRange(candidate.startIndex..., in: candidate)),
                   let range = Range(hit.range, in: candidate) {
                    candidate = String(candidate[..<range.lowerBound]).trimmingCharacters(in: trimSet)
                }
                if !candidate.isEmpty && !matches(#"\b(?:anything|everyone|all our|each|every)\b"#, candidate) {
                    results.append(candidate)
                }
                continue
            }
            for found in allMatches(#"\b(?:go(?:es)? under|put (?:them|it|those) under)\s+([A-Z][A-Za-z ]{1,35}?)(?=\s*(?:[,.;]|\b(?:except|unless|but|because|which|and|$)))"#, in: content, caseInsensitive: false) {
                results.append(found[1].trimmingCharacters(in: trimSet))
            }
            // Version 20: inside a list, "Shot 1: Hero on white" lines are names.
            if !bullet && inList, let heading = firstMatch(#"^([^:]{2,65}):\s+.+$"#, in: content) {
                let candidate = heading[1].trimmingCharacters(in: trimSet)
                if usable(candidate) && wordCount(candidate) <= 7 && !matches(stopWords, candidate) {
                    results.append(content)
                    continue
                }
            }
            // Version 20: short bullet points count even without a heading.
            let shortBullet: Bool = bullet && content.count <= 65 && wordCount(content) <= 8 &&
                !matches(#"\b(?:should|would|could|please|unless|except|because|which|when|if|don.t|do not|thanks|thank you)\b"#, content)
            if bullet && !inList && shortBullet {
                var item = content.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                while item.hasSuffix(".") || item.hasSuffix(";") { item.removeLast() }
                results.append(item)
                continue
            }
            if bullet && inList {
                var item = content.trimmingCharacters(in: trimSet).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                while item.hasSuffix(".") || item.hasSuffix(";") { item.removeLast() }
                let hedged = matches(#"\b(?:should|would|could|please|unless|except|because|which|when|if|don.t|do not)\b"#, item)
                if item.count <= 65 && wordCount(item) <= 10 && !hedged { results.append(item) }
                else { review.append(content) }
                continue
            }
            if simpleList {
                if wordCount(content) <= 6 && content.count <= 60 && !matches(#"\b(?:also|here|thinking|need|want|should|would|please|because|under|folder|anything)\b"#, content) {
                    if splitCommas { results.append(contentsOf: content.components(separatedBy: ",")) }
                    else { results.append(content) }
                    continue
                }
            }
            if matches(#"\b(?:folder|categor|organize|sort|under|except|unless|if |should|would|need|anything|involving)\b"#, content) {
                review.append(content)
            }
        }
        for found in allMatches(#"["“]([^"”\n]{2,65})["”]\s+folder\b"#, in: text) {
            let candidate = found[1].trimmingCharacters(in: trimSet)
            if usable(candidate) && !matches(stopWords, candidate) { results.append(candidate) }
        }
        let names = dedupe(results)
        let lowered = Set(names.map { $0.lowercased() })
        let reviewOnly = dedupe(review).filter { !lowered.contains($0.lowercased()) }
        return Extraction(names: names, review: reviewOnly, excluded: excluded)
    }

    /// Version 20.3: Paste List. One folder per line; optional bullet and
    /// number removal and comma splitting. Blank lines are ignored.
    static func listNames(_ text: String, splitCommas: Bool, stripBullets: Bool) -> [String] {
        var out: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if stripBullets { line = removeLeading(bulletPattern, from: line).trimmingCharacters(in: .whitespaces) }
            let pieces: [String] = splitCommas ? line.components(separatedBy: ",") : [line]
            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
            }
        }
        return out
    }

    /// Version 20.5: keeps the first of each name (case-insensitive, after
    /// macOS cleanup) so the preview only shows folders that will be made.
    static func uniqueNames(_ names: [String]) -> (names: [String], combined: Int) {
        var seen = Set<String>()
        var out: [String] = []
        var combined = 0
        for name in names {
            let key: String = (cleanPath(name).path ?? name).lowercased()
            if seen.contains(key) { combined += 1; continue }
            seen.insert(key)
            out.append(name)
        }
        return (out, combined)
    }

    // MARK: Planning and creating

    enum Status: String { case ready = "New", exists = "Exists" }

    struct Row: Identifiable, Equatable {
        let path: String
        let status: Status
        var id: String { path.lowercased() }
        var depth: Int { path.split(separator: "/").count - 1 }
        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    }

    struct Planned: Equatable {
        var rows: [Row] = []
        var adjusted: [String] = []   // "original → cleaned"
        var skipped: [String] = []    // unusable or duplicate
    }

    static func plan(_ paths: [String], destination: URL) -> Planned {
        var planned = Planned()
        var seen = Set<String>()
        let fm = FileManager.default
        for raw in paths {
            let cleaned = cleanPath(raw)
            guard let path = cleaned.path else {
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { planned.skipped.append(raw + " (not a usable name)") }
                continue
            }
            let key = path.lowercased()
            if seen.contains(key) {
                planned.skipped.append(path + " (duplicate)")
                continue
            }
            seen.insert(key)
            if cleaned.adjusted { planned.adjusted.append(raw + " → " + path) }
            let target = destination.appendingPathComponent(path, isDirectory: true)
            let exists = fm.fileExists(atPath: target.path)
            planned.rows.append(Row(path: path, status: exists ? .exists : .ready))
        }
        return planned
    }

    struct Created {
        var made: [URL] = []
        var skipped: [String] = []
        var errors: [String] = []
    }

    /// Creates only missing folders, one level at a time, inside destination.
    static func create(_ paths: [String], destination: URL) throws -> Created {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw failure("The destination folder does not exist.")
        }
        var result = Created()
        for row in plan(paths, destination: destination).rows {
            if row.status == .exists { result.skipped.append(row.path); continue }
            var current = destination
            do {
                for part in row.path.split(separator: "/") {
                    current = current.appendingPathComponent(String(part), isDirectory: true)
                    if !fm.fileExists(atPath: current.path) {
                        try fm.createDirectory(at: current, withIntermediateDirectories: false)
                        result.made.append(current)
                    }
                }
            } catch {
                result.errors.append(row.path + ": " + error.localizedDescription)
            }
        }
        return result
    }

    /// Removes folders created by the last run, deepest first, only if still empty.
    static func undo(_ created: [URL]) -> (removed: Int, kept: [String]) {
        let fm = FileManager.default
        var removed = 0
        var kept: [String] = []
        for folder in created.reversed() {
            let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            let meaningful = contents.filter { $0 != ".DS_Store" }
            if !meaningful.isEmpty { kept.append(folder.lastPathComponent); continue }
            do {
                if contents.contains(".DS_Store") { try? fm.removeItem(at: folder.appendingPathComponent(".DS_Store")) }
                try fm.removeItem(at: folder)
                removed += 1
            } catch {
                kept.append(folder.lastPathComponent)
            }
        }
        return (removed, kept)
    }

    // MARK: Reading files

    struct Sheet: Equatable {
        let name: String
        let rows: [[String]]
    }

    enum Imported {
        case tables([Sheet])
        case text(String)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "FolderMaker", code: 20, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Reads any supported file except PDF (handled by the view with PDFKit).
    static func read(_ url: URL) throws -> Imported {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "xlsx", "xlsm":
            return .tables(try readXLSX(url))
        case "csv", "tsv":
            let text = try readPlainText(url)
            return .tables([Sheet(name: url.deletingPathExtension().lastPathComponent, rows: parseCSV(text, tab: ext == "tsv"))])
        case "json":
            return .text(try readJSONNames(url).joined(separator: "\n"))
        case "eml":
            return .text(emailBody(try Data(contentsOf: url)))
        case "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive":
            return .text(try textutil(url))
        case "numbers":
            throw failure("Numbers files cannot be read directly. In Numbers, choose File > Export To > CSV or Excel, then import that file.")
        default:
            return .text(try readPlainText(url))
        }
    }

    static func readPlainText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .macOSRoman) { return text }
        throw failure("Unsupported text encoding.")
    }

    static func readJSONNames(_ url: URL) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        func names(_ list: [Any]) -> [String] {
            list.compactMap { item -> String? in
                if let text = item as? String { return text }
                if let dict = item as? [String: Any] { return dict["name"] as? String }
                return nil
            }
        }
        if let list = object as? [Any] { return names(list) }
        if let dict = object as? [String: Any] {
            for key in ["folders", "names", "items", "categories"] {
                if let list = dict[key] as? [Any] { return names(list) }
            }
        }
        throw failure("JSON must contain a list, or a folders/names/items/categories list.")
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure("Could not read the file (" + URL(fileURLWithPath: executable).lastPathComponent + " failed).")
        }
        return data
    }

    static func textutil(_ url: URL) throws -> String {
        let data = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
        return String(decoding: data, as: UTF8.self)
    }

    /// RFC 4180 CSV. Delimiter is detected (comma, semicolon or tab).
    static func parseCSV(_ text: String, tab: Bool = false) -> [[String]] {
        let sample = String(text.prefix(4096))
        var delimiter: Character = tab ? "\t" : ","
        if !tab {
            let commas = sample.filter { $0 == "," }.count
            let semicolons = sample.filter { $0 == ";" }.count
            let tabs = sample.filter { $0 == "\t" }.count
            if tabs > commas && tabs > semicolons { delimiter = "\t" }
            else if semicolons > commas { delimiter = ";" }
        }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        if iterator.first == "\u{FEFF}" { iterator.removeFirst() }
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < iterator.count && iterator[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field); field = ""
            } else if character == "\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(character)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: Excel (.xlsx): a zip of XML files, read with the built-in unzip.

    static func zipEntry(_ archive: URL, _ entry: String) -> Data? {
        guard let data = try? run("/usr/bin/unzip", ["-p", archive.path, entry]), !data.isEmpty else { return nil }
        return data
    }

    static func readXLSX(_ url: URL) throws -> [Sheet] {
        guard let workbook = zipEntry(url, "xl/workbook.xml") else {
            throw failure("This does not look like an Excel workbook.")
        }
        let shared = zipEntry(url, "xl/sharedStrings.xml").map { SharedStringsReader.read($0) } ?? []
        let relations = zipEntry(url, "xl/_rels/workbook.xml.rels").map { RelationshipsReader.read($0) } ?? [:]
        var sheets: [Sheet] = []
        for (index, entry) in WorkbookReader.read(workbook).enumerated() {
            var target = relations[entry.relation] ?? "worksheets/sheet\(index + 1).xml"
            if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
            guard let xml = zipEntry(url, target) else { continue }
            sheets.append(Sheet(name: entry.name, rows: SheetReader.read(xml, shared: shared)))
        }
        if sheets.isEmpty { throw failure("No worksheets were found in this workbook.") }
        return sheets
    }

    private final class WorkbookReader: NSObject, XMLParserDelegate {
        var sheets: [(name: String, relation: String)] = []
        static func read(_ data: Data) -> [(name: String, relation: String)] {
            let reader = WorkbookReader()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            return reader.sheets
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            guard elementName == "sheet" || elementName.hasSuffix(":sheet") else { return }
            let relation = attributes["r:id"] ?? attributes.first(where: { $0.key.hasSuffix(":id") })?.value ?? ""
            sheets.append((attributes["name"] ?? "Sheet \(sheets.count + 1)", relation))
        }
    }

    private final class RelationshipsReader: NSObject, XMLParserDelegate {
        var map: [String: String] = [:]
        static func read(_ data: Data) -> [String: String] {
            let reader = RelationshipsReader()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            return reader.map
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            guard elementName == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
            map[id] = target
        }
    }

    private final class SharedStringsReader: NSObject, XMLParserDelegate {
        var strings: [String] = []
        var current = ""
        var inItem = false
        var inText = false
        static func read(_ data: Data) -> [String] {
            let reader = SharedStringsReader()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            return reader.strings
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if elementName == "si" { inItem = true; current = "" }
            else if elementName == "t" && inItem { inText = true }
            else if elementName == "rPh" { inText = false } // phonetic hints are not part of the text
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inItem && inText { current += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "t" { inText = false }
            else if elementName == "si" { strings.append(current); inItem = false }
        }
    }

    private final class SheetReader: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [Int: [Int: String]] = [:]
        var currentRow = 0
        var cellColumn = 0
        var cellType = ""
        var value = ""
        var collecting = false
        var nextColumn = 0
        init(shared: [String]) { self.shared = shared }

        static func read(_ data: Data, shared: [String]) -> [[String]] {
            let reader = SheetReader(shared: shared)
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            guard let lastRow = reader.rows.keys.max() else { return [] }
            var out: [[String]] = []
            for rowIndex in 1...lastRow {
                let cells = reader.rows[rowIndex] ?? [:]
                let width = (cells.keys.max() ?? -1) + 1
                var row: [String] = []
                for column in 0..<width { row.append(cells[column] ?? "") }
                out.append(row)
            }
            return out
        }

        static func column(from reference: String) -> Int? {
            var result = 0
            var sawLetter = false
            for scalar in reference.unicodeScalars {
                let value = Int(scalar.value)
                if value >= 65 && value <= 90 { result = result * 26 + (value - 64); sawLetter = true }
                else if value >= 97 && value <= 122 { result = result * 26 + (value - 96); sawLetter = true }
                else { break }
            }
            return sawLetter ? result - 1 : nil
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            switch elementName {
            case "row":
                currentRow = Int(attributes["r"] ?? "") ?? (currentRow + 1)
                nextColumn = 0
            case "c":
                cellColumn = attributes["r"].flatMap { SheetReader.column(from: $0) } ?? nextColumn
                nextColumn = cellColumn + 1
                cellType = attributes["t"] ?? ""
                value = ""
            case "v", "t":
                collecting = true
            default:
                break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { value += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "v" || elementName == "t" { collecting = false; return }
            guard elementName == "c" else { return }
            var text = value
            if cellType == "s", let index = Int(value), index >= 0, index < shared.count {
                text = shared[index]
            } else if cellType == "b" {
                text = value == "1" ? "TRUE" : "FALSE"
            } else if cellType.isEmpty || cellType == "n", let number = Double(value), number == number.rounded(), abs(number) < 1e15 {
                text = String(Int64(number))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                var row = rows[currentRow] ?? [:]
                row[cellColumn] = text
                rows[currentRow] = row
            }
        }
    }

    /// Folder names from a table: one folder per row from the chosen columns,
    /// either combined into one name or as nested levels. Blank rows skipped.
    static func names(from rows: [[String]], header: Bool, columns: [Int], nested: Bool, separator: String) -> [String] {
        guard !columns.isEmpty else { return [] }
        let body: [[String]] = header ? Array(rows.dropFirst()) : rows
        var out: [String] = []
        for row in body {
            var parts: [String] = []
            for column in columns where column < row.count {
                let value = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { parts.append(nested ? value.replacingOccurrences(of: "/", with: " - ") : value) }
            }
            if parts.isEmpty { continue }
            out.append(parts.joined(separator: nested ? "/" : separator))
        }
        return out
    }

    // MARK: Email (.eml)

    static func emailBody(_ data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return messagePart(raw, depth: 0) ?? raw
    }

    private static func headerValue(_ name: String, in headers: String) -> String? {
        let unfolded = headers.replacingOccurrences(of: "\n ", with: " ").replacingOccurrences(of: "\n\t", with: " ")
        for line in unfolded.components(separatedBy: "\n") {
            if line.lowercased().hasPrefix(name.lowercased() + ":") {
                return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func messagePart(_ part: String, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        let split = part.components(separatedBy: "\n\n")
        guard split.count >= 2 else { return part }
        let headers = split[0]
        let body = split.dropFirst().joined(separator: "\n\n")
        let type = (headerValue("Content-Type", in: headers) ?? "text/plain").lowercased()
        let encoding = (headerValue("Content-Transfer-Encoding", in: headers) ?? "").lowercased()
        if type.hasPrefix("multipart/") {
            guard let boundary = firstMatch(#"boundary="?([^";]+)"?"#, in: headerValue("Content-Type", in: headers) ?? "")?[1] else { return nil }
            let pieces = body.components(separatedBy: "--" + boundary)
            var htmlFallback: String?
            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                if trimmed.isEmpty || trimmed.hasPrefix("--") { continue }
                let pieceHeaders = trimmed.components(separatedBy: "\n\n").first ?? ""
                let pieceType = (headerValue("Content-Type", in: pieceHeaders) ?? "text/plain").lowercased()
                if pieceType.hasPrefix("text/plain") || pieceType.hasPrefix("multipart/") {
                    if let text = messagePart(trimmed, depth: depth + 1), !text.isEmpty { return text }
                } else if pieceType.hasPrefix("text/html"), htmlFallback == nil {
                    htmlFallback = messagePart(trimmed, depth: depth + 1)
                }
            }
            return htmlFallback
        }
        var decoded: String = body
        if encoding.contains("base64") {
            let compact = body.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: compact) { decoded = String(decoding: data, as: UTF8.self) }
        } else if encoding.contains("quoted-printable") {
            decoded = decodeQuotedPrintable(body)
        }
        if type.hasPrefix("text/html") {
            decoded = decoded.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
                .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
                .replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
                .replacingOccurrences(of: "<li>", with: "- ", options: .caseInsensitive)
            decoded = removeLeading(#"<[^>]+>"#, from: decoded)
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        }
        return decoded
    }

    static func decodeQuotedPrintable(_ text: String) -> String {
        let joined = text.replacingOccurrences(of: "=\n", with: "")
        var bytes: [UInt8] = []
        let characters = Array(joined.utf8)
        var index = 0
        while index < characters.count {
            if characters[index] == UInt8(ascii: "="), index + 2 < characters.count,
               let value = UInt8(String(decoding: characters[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                bytes.append(value)
                index += 3
            } else {
                bytes.append(characters[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
