import SwiftUI

// WRAP: just ask for it. One command bar (Command-K) that understands plain
// words, and a row of color-checker patches for people who'd rather click.

struct WrapCommand: Identifiable {
    let id: String
    let title: String
    let hint: String
    let icon: String
    let keywords: String
    let run: () -> Void
}

struct WrapShell<Content: View>: View {
    @ObservedObject var model: WrapModel
    let content: Content
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var commandFocused: Bool
    /// The list opens only on Command-K, typing, or the down arrow, and closes
    /// when a command runs, on Escape, or when the bar loses focus.
    @State private var showSuggestions = false
    @AppStorage(DigiHiddenTools.key) private var hiddenRaw = ""
    @AppStorage(DigiToolOrder.key) private var orderRaw = ""

    init(model: WrapModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    private var t: DigiTheme { DigiBrand.theme }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            patchRow
            Rectangle().fill(t.line).frame(height: 1)
            if model.lastTab == 0 { nextUp }
            content
        }
        .background(t.background)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            WrapMark(size: 26)
            Text("WRAP")
                .font(DigiBrand.display(26, .black))
                .foregroundStyle(t.text)
            Text(DigiBrand.tagline)
                .font(DigiBrand.body(13, .medium))
                .foregroundStyle(t.subtext)
            Spacer()
            backupBadge
            DigiSessionChip(model: model)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16 + DigiBrand.titleBarInset)
        .padding(.bottom, 10)
    }

    private var backupBadge: some View {
        let snapshot = DigiBackupSnapshot.from(model)
        let text: String
        let color: Color
        if snapshot.running {
            text = snapshot.paused ? "Paused" : "Saving \(Int((snapshot.fraction * 100).rounded()))%"
            color = snapshot.paused ? t.warn : t.accent
        } else if let last = snapshot.lastBackup {
            text = "Saved " + DigiNextStep.ago(last)
            color = t.good
        } else {
            text = model.backups.isEmpty ? "No drives yet" : "Not backed up yet"
            color = t.subtext
        }
        return Button { model.lastTab = 1 } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(text).font(DigiBrand.body(12, .semibold)).foregroundStyle(t.text)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(t.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Open \(DigiBrand.toolName(1))")
    }

    // MARK: Command bar

    private var allCommands: [WrapCommand] {
        let m = model
        let step = DigiNextStep.current(m)
        var list: [WrapCommand] = []
        list.append(WrapCommand(id: "next", title: step.button, hint: step.title, icon: step.icon,
                                keywords: "next do it now go", run: { step.perform(m) }))
        list.append(WrapCommand(id: "session", title: "Open a session", hint: "Pick the folder you're shooting into",
                                icon: "folder", keywords: "open session folder capture one choose", run: { m.chooseRoot() }))
        list.append(WrapCommand(id: "backup", title: "Back up now", hint: "Copy new and changed files to every drive",
                                icon: "externaldrive.badge.checkmark", keywords: "back up backup copy save drives sync start",
                                run: { m.lastTab = 1; m.requestStartSync() }))
        if m.syncBusy {
            list.append(WrapCommand(id: "pause", title: m.everythingPaused ? "Resume the backup" : "Pause the backup",
                                    hint: "Nothing is lost", icon: "pause.circle", keywords: "pause resume hold continue",
                                    run: { m.togglePauseAll() }))
            list.append(WrapCommand(id: "stop", title: "Stop the backup", hint: "Stops after the current file",
                                    icon: "stop.circle", keywords: "stop cancel end halt", run: { m.stopSync() }))
        }
        list.append(WrapCommand(id: "drives", title: "Find my drives", hint: "Look for plugged-in backup drives",
                                icon: "externaldrive.badge.plus", keywords: "find drives discover add drive destination plug",
                                run: { m.lastTab = 1; m.discoverExternalBackupFolders() }))
        list.append(WrapCommand(id: "adddrive", title: "Add a backup folder…", hint: "Choose any folder as a backup",
                                icon: "plus.circle", keywords: "add backup folder destination choose", run: { m.lastTab = 1; m.addBackup() }))
        list.append(WrapCommand(id: "compare", title: "Compare session with backups", hint: "Green matches, red is missing",
                                icon: "square.split.2x1", keywords: "compare check verify match missing proof", run: { m.lastTab = 7 }))
        list.append(WrapCommand(id: "folders", title: "Make folders from a list", hint: "Paste, import a spreadsheet or count up",
                                icon: "folder.badge.plus", keywords: "make folders create list spreadsheet excel shot list", run: { m.lastTab = 4 }))
        list.append(WrapCommand(id: "sheets", title: "Make a contact sheet", hint: "Printable pages of thumbnails",
                                icon: "square.grid.3x3", keywords: "contact sheet pdf print thumbnails", run: { m.lastTab = 6 }))
        list.append(WrapCommand(id: "picks", title: "List the picks", hint: "Starred and color-tagged images",
                                icon: "star", keywords: "selects picks stars ratings tags list", run: { m.lastTab = 2 }))
        list.append(WrapCommand(id: "exports", title: "Check the exports", hint: "Was every pick exported?",
                                icon: "checkmark.seal", keywords: "exports processed delivery check jpg", run: { m.lastTab = 3 }))
        list.append(WrapCommand(id: "report", title: "Write the wrap report", hint: "What was shot, saved and sent",
                                icon: "doc.text", keywords: "report wrap job summary", run: { m.lastTab = 5 }))
        list.append(WrapCommand(id: "save", title: "Save the workspace", hint: "Remembers this session and its drives",
                                icon: "square.and.arrow.down", keywords: "save workspace", run: { m.saveProject() }))
        for tool in DigiBrand.visibleTools(hidden: DigiHiddenTools.parse(hiddenRaw)) {
            list.append(WrapCommand(id: "tool\(tool.id)", title: "Go to \(tool.name)", hint: tool.blurb, icon: tool.icon,
                                    keywords: "go open show tab " + tool.name.lowercased(), run: { m.lastTab = tool.id }))
        }
        list.append(WrapCommand(id: "tour", title: "Show the tour", hint: "A one-minute walk through Wrap",
                                icon: "sparkles", keywords: "help tour how learn",
                                run: { NotificationCenter.default.post(name: .digiShowTour, object: nil) }))
        return list
    }

    private var matches: [WrapCommand] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let list = allCommands
        if words.isEmpty { return Array(list.prefix(6)) }
        var found: [WrapCommand] = []
        for command in list {
            let haystack = (command.title + " " + command.keywords).lowercased()
            var all = true
            for word in words where !haystack.contains(word) { all = false; break }
            if all { found.append(command) }
        }
        return Array(found.prefix(8))
    }

    private func runHighlighted() {
        let list = matches
        guard !list.isEmpty else { return }
        let item = list[min(highlighted, list.count - 1)]
        query = ""
        highlighted = 0
        showSuggestions = false
        commandFocused = false
        item.run()
    }

    private var commandArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(t.subtext)
                TextField("What do you want to do? Try \"back up\" or \"compare\"", text: $query)
                    .textFieldStyle(.plain)
                    .font(DigiBrand.body(17, .medium))
                    .foregroundStyle(t.text)
                    .focused($commandFocused)
                    .onSubmit { runHighlighted() }
                    .onChange(of: query) { _, newValue in
                        highlighted = 0
                        if !newValue.isEmpty { showSuggestions = true }
                    }
                    .onChange(of: commandFocused) { _, focused in
                        if !focused { showSuggestions = false }
                    }
                    .onKeyPress(.downArrow) {
                        if !showSuggestions {
                            showSuggestions = true
                            return .handled
                        }
                        highlighted = min(highlighted + 1, max(0, matches.count - 1))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(0, highlighted - 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        query = ""
                        showSuggestions = false
                        commandFocused = false
                        return .handled
                    }
                Text("⌘K")
                    .font(DigiBrand.numbers(12, .medium))
                    .foregroundStyle(t.subtext)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(t.raised, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(t.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(commandFocused ? t.accent : t.line, lineWidth: commandFocused ? 2 : 1))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                commandFocused = true
                showSuggestions = true
            })
            .overlay(alignment: .topLeading) {
                if commandFocused && showSuggestions { suggestions.offset(y: 56) }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private var suggestions: some View {
        let list = matches
        return VStack(alignment: .leading, spacing: 2) {
            if list.isEmpty {
                Text("Nothing matches \"\(query)\". Try \"backup\", \"compare\" or \"folders\".")
                    .font(DigiBrand.body(13))
                    .foregroundStyle(t.subtext)
                    .padding(12)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { position, command in
                Button {
                    highlighted = position
                    runHighlighted()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: command.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 22)
                            .foregroundStyle(position == highlighted ? t.onAccent : t.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(command.title).font(DigiBrand.body(14, .semibold))
                            Text(command.hint).font(DigiBrand.body(12))
                                .foregroundStyle(position == highlighted ? t.onAccent.opacity(0.75) : t.subtext)
                        }
                        Spacer()
                        if position == highlighted {
                            Text("Return").font(DigiBrand.numbers(11, .medium)).foregroundStyle(t.onAccent.opacity(0.75))
                        }
                    }
                    .foregroundStyle(position == highlighted ? t.onAccent : t.text)
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .background(position == highlighted ? t.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in if inside { highlighted = position } }
            }
        }
        .padding(6)
        .frame(maxWidth: 640, alignment: .leading)
        .background(t.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(t.line))
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
    }

    // MARK: Patches

    private var patchRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(visiblePatches.enumerated()), id: \.element.id) { position, tool in
                    patch(tool, position: position, count: visiblePatches.count)
                }
                DigiShowHiddenButton()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
    }

    private var visiblePatches: [DigiTool] { DigiBrand.visibleTools(hidden: DigiHiddenTools.parse(hiddenRaw)) }

    private func patch(_ tool: DigiTool, position: Int, count: Int) -> some View {
        let selected = model.lastTab == tool.id
        let color = DigiBrand.patches[tool.id]
        return Button { model.lastTab = tool.id } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 14)
                Text(tool.name).font(DigiBrand.body(13, selected ? .bold : .medium))
            }
            .foregroundStyle(selected ? t.text : t.subtext)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selected ? t.raised : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? color : t.line, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.blurb)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .digiToolMenu(model, tool: tool.id)
        .digiArrange(model, tool: tool.id, index: position, count: count)
    }

    // MARK: Home

    private var nextUp: some View {
        let step = DigiNextStep.current(model)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("UP NEXT")
                    .font(DigiBrand.numbers(11, .semibold))
                    .foregroundStyle(t.accent)
                Text(step.title)
                    .font(DigiBrand.display(30, .black))
                    .foregroundStyle(t.text)
                Text(step.detail)
                    .font(DigiBrand.body(14))
                    .foregroundStyle(t.subtext)
            }
            Spacer()
            DigiNextStepButton(model: model, large: true)
            if model.syncBusy { DigiStopButton(model: model) }
        }
        .padding(20)
        .background(t.surface, in: RoundedRectangle(cornerRadius: t.radius, style: .continuous))
        .overlay(alignment: .leading) {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { i in
                    Rectangle().fill(DigiBrand.patches[i + 1])
                }
            }
            .frame(width: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }
}
