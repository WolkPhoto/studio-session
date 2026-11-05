import Foundation

// Version 20: checks for the Swift Folder Maker engine. Run from FastBackupSmokeTests.
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "FolderPlanSmokeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum FolderPlanSmokeTests {
    static func run() throws {
        let fm = FileManager.default

        // Names
        let colon = FolderPlan.cleanComponent("Shot 1: Hero")
        try expect(colon.name == "Shot 1 - Hero" && colon.adjusted, "Colon was not made safe")
        try expect(FolderPlan.cleanComponent(".hidden").name == "hidden", "Leading dot was not removed")
        try expect(FolderPlan.cleanComponent("   ").name == nil, "Blank name was accepted")
        try expect(FolderPlan.cleanPath("A/../B").path == nil, "Path traversal was accepted")
        try expect(FolderPlan.cleanPath("Look 1/Selects").path == "Look 1/Selects", "Nested path changed")
        try expect(FolderPlan.expand(["A"], subfolders: ["X", "Y"]) == ["A", "A/X", "A/Y"], "Subfolder expansion is wrong")
        try expect(FolderPlan.replaceSpaces("Look 1 - Hero/Raw  Files", with: "_") == "Look_1-Hero/Raw_Files", "Underscore spaces failed")
        try expect(FolderPlan.replaceSpaces("Look 1/Selects", with: "-") == "Look-1/Selects", "Dash spaces failed")
        try expect(FolderPlan.replaceSpaces("Look 1", with: "") == "Look 1", "Keep spaces changed the name")
        try expect(FolderPlan.applyTokens("{session}_A", session: "S") == "S_A", "Session token failed")
        var dateParts = DateComponents(); dateParts.year = 2026; dateParts.month = 11; dateParts.day = 1; dateParts.hour = 12
        let fixed = Calendar(identifier: .gregorian).date(from: dateParts) ?? Date()
        try expect(FolderPlan.applyTokens("{date}_Shot", session: nil, date: fixed) == "2026_11_01_Shot", "Date token failed")

        // Sequences
        let sequence = try FolderPlan.sequence(prefix: "Shot_", start: 1, end: 3, digits: 2, suffix: "", step: 1)
        try expect(sequence == ["Shot_01", "Shot_02", "Shot_03"], "Sequence is wrong")
        var rejected = false
        do { _ = try FolderPlan.sequence(prefix: "x", start: 5, end: 1, digits: 2, suffix: "", step: 1) } catch { rejected = true }
        try expect(rejected, "Descending sequence was accepted")
        let interpreted = FolderPlan.interpretSequence("shot-01 through shot-04") ?? []
        try expect(interpreted.count == 4 && interpreted.first == "shot-01", "Sequence request not understood")

        // Text
        let literal = FolderPlan.extract("A\nB, C", smart: false, splitCommas: true)
        try expect(literal.names == ["A", "B", "C"], "Literal list is wrong")
        let email = """
        Hi Jeff,

        Here are the folders for the shoot:
        - Hero
        - Lifestyle Kitchen
        - Detail Shots
        Please don't create a folder for outtakes.

        Thanks,
        Sam
        """
        let fromEmail = FolderPlan.extract(email, smart: true, splitCommas: true)
        try expect(fromEmail.names == ["Hero", "Lifestyle Kitchen", "Detail Shots"], "Email list was not read: \(fromEmail.names)")
        try expect(fromEmail.excluded.count == 1, "Do-not-create line was not skipped")
        let shotList = """
        Shot list for Tuesday:
        Shot 1: Hero product on white
        Shot 2: Lifestyle kitchen with model
        """
        let shots = FolderPlan.extract(shotList, smart: true, splitCommas: true)
        try expect(shots.names == ["Shot 1 - Hero product on white", "Shot 2 - Lifestyle kitchen with model"], "Shot list was not read: \(shots.names)")

        let pasted = FolderPlan.listNames("- Hero\n2. Kitchen, Bath\n\n• Look 1/Selects\n", splitCommas: true, stripBullets: true)
        try expect(pasted == ["Hero", "Kitchen", "Bath", "Look 1/Selects"], "Paste list is wrong: \(pasted)")
        let kept = FolderPlan.listNames("- Hero, Two", splitCommas: false, stripBullets: false)
        try expect(kept == ["- Hero, Two"], "Paste list options were ignored")

        let unique = FolderPlan.uniqueNames(["Scene_1", "Scene_1", "scene_1", "Scene_2", "Shot: A", "Shot - A"])
        try expect(unique.names == ["Scene_1", "Scene_2", "Shot: A"] && unique.combined == 3, "Repeated names were not combined: \(unique)")

        // Tables
        let table: [[String]] = [["Shot", "Look"], ["01", "Red Dress"], ["", ""], ["02", "Blue Suit"]]
        let combined = FolderPlan.names(from: table, header: true, columns: [0, 1], nested: false, separator: " - ")
        try expect(combined == ["01 - Red Dress", "02 - Blue Suit"], "Combined columns are wrong")
        let nestedNames = FolderPlan.names(from: table, header: true, columns: [0, 1], nested: true, separator: " - ")
        try expect(nestedNames == ["01/Red Dress", "02/Blue Suit"], "Nested columns are wrong")
        let csv = FolderPlan.parseCSV("Shot,Look\n01,\"Red, Dress\"\n02,\"Blue \"\"Suit\"\"\"\n")
        try expect(csv.count == 3 && csv[1][1] == "Red, Dress" && csv[2][1] == "Blue \"Suit\"", "CSV quoting is wrong")
        let semicolons = FolderPlan.parseCSV("a;b\nc;d")
        try expect(semicolons == [["a", "b"], ["c", "d"]], "Semicolon CSV is wrong")

        // Plan, create, undo
        let root = fm.temporaryDirectory.appendingPathComponent("DigiSuite-Folders-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let paths = ["Shot 1: Hero", "Shot 1: Hero/Selects", "A", "a"]
        let planned = FolderPlan.plan(paths, destination: root)
        try expect(planned.rows.map(\.path) == ["Shot 1 - Hero", "Shot 1 - Hero/Selects", "A"], "Plan is wrong: \(planned.rows.map(\.path))")
        try expect(planned.skipped.count == 1 && planned.adjusted.count == 2, "Plan feedback is wrong")
        let created = try FolderPlan.create(paths, destination: root)
        try expect(created.made.count == 3 && created.errors.isEmpty, "Folders were not created")
        let again = FolderPlan.plan(paths, destination: root)
        try expect(again.rows.allSatisfy { $0.status == .exists }, "Created folders not seen as existing")
        try Data("keep".utf8).write(to: root.appendingPathComponent("A/file.txt"))
        let undone = FolderPlan.undo(created.made)
        try expect(undone.removed == 2 && undone.kept == ["A"], "Undo removed a folder with files, or missed empty ones")
        try expect(fm.fileExists(atPath: root.appendingPathComponent("A/file.txt").path), "Undo touched a file")

        // Excel workbook built from XML parts with the system zip tool.
        let book = root.appendingPathComponent("book", isDirectory: true)
        let parts: [String: String] = [
            "xl/workbook.xml": #"<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Shots" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<Relationships><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#,
            "xl/sharedStrings.xml": #"<sst><si><t>Shot</t></si><si><t>Look</t></si><si><r><t>Red </t></r><r><t>Dress</t></r></si><si><t>Blue Suit</t></si></sst>"#,
            "xl/worksheets/sheet1.xml": #"<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2"><v>1</v></c><c r="B2" t="s"><v>2</v></c></row><row r="3"><c r="A3"><v>2</v></c><c r="C3" t="inlineStr"><is><t>Note</t></is></c><c r="B3" t="s"><v>3</v></c></row></sheetData></worksheet>"#,
        ]
        for (relative, xml) in parts {
            let url = book.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: url)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = book
        zip.arguments = ["-q", "-r", root.appendingPathComponent("book.xlsx").path, "xl"]
        try zip.run(); zip.waitUntilExit()
        let sheets = try FolderPlan.readXLSX(root.appendingPathComponent("book.xlsx"))
        try expect(sheets.count == 1 && sheets[0].name == "Shots", "Workbook sheet not found")
        let rows = sheets[0].rows
        try expect(rows.count == 3 && rows[0] == ["Shot", "Look"], "Workbook header is wrong: \(rows)")
        try expect(rows[1] == ["1", "Red Dress"] && rows[2] == ["2", "Blue Suit", "Note"], "Workbook cells are wrong: \(rows)")

        // Email with a quoted-printable plain-text part.
        let eml = "From: Sam\nSubject: Shoot\nContent-Type: multipart/alternative; boundary=\"XYZ\"\n\n--XYZ\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\nFolders for the shoot:\n- Hero=20Shot\n- Detail\n--XYZ\nContent-Type: text/html\n\n<p>ignored</p>\n--XYZ--\n"
        let body = FolderPlan.emailBody(Data(eml.utf8))
        try expect(body.contains("Hero Shot") && !body.contains("ignored"), "Email body was not decoded: \(body)")

        print("PASS (v20): Folder Maker names, sequences, email and shot-list reading, CSV, Excel, email files, plan/create/undo")
    }
}
