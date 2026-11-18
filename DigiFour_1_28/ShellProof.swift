import SwiftUI

// PROOF: the shape of a shoot day, left to right. Each section opens the
// tools for that part of the day. Sections are not steps you must finish:
// a check appears only when Proof can confirm something is done.

struct ProofStage: Identifiable {
    let id: Int
    let name: String
    let icon: String
    let tools: [Int]
}

struct ProofShell<Content: View>: View {
    @ObservedObject var model: WrapModel
    let content: Content
    @AppStorage(DigiHiddenTools.key) private var hiddenRaw = ""
    @AppStorage(DigiToolOrder.key) private var orderRaw = ""
    @AppStorage(DigiAppearance.key) private var appearance = "light"

    init(model: WrapModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    private var t: DigiTheme { DigiBrand.theme }
    private var hidden: Set<Int> { DigiHiddenTools.parse(hiddenRaw) }

    /// Matches DigiBrand.toolOrder for Proof, so Command-numbers run left to right.
    static var stages: [ProofStage] {
        [
            ProofStage(id: 0, name: "Dashboard", icon: "house", tools: [0]),
            ProofStage(id: 1, name: "Folders", icon: "folder.badge.plus", tools: [4]),
            ProofStage(id: 2, name: "Back Up", icon: "externaldrive", tools: [1]),
            ProofStage(id: 3, name: "Verify", icon: "checkmark.shield", tools: [7]),
            ProofStage(id: 4, name: "Selects", icon: "star", tools: [2, 8]),
            ProofStage(id: 5, name: "Deliver", icon: "paperplane", tools: [6, 3]),
            ProofStage(id: 6, name: "Wrap Up", icon: "doc.text", tools: [5])
        ]
    }

    /// v1.12: sections in the order the person arranged them (by their first tool).
    private var orderedStages: [ProofStage] {
        let order = DigiBrand.toolOrder
        return Self.stages.sorted { first, second in
            let a = order.firstIndex(of: first.tools[0]) ?? 0
            let b = order.firstIndex(of: second.tools[0]) ?? 0
            return a < b
        }
    }

    /// Moves a section (with all its tools) to a new place among the showing sections.
    private func moveStage(_ stage: ProofStage, to position: Int) {
        let showing = visibleStages.map(\.id)
        var ids = orderedStages.map(\.id)
        guard let from = ids.firstIndex(of: stage.id) else { return }
        ids.remove(at: from)
        let remainingShowing = showing.filter { $0 != stage.id }
        if position < remainingShowing.count, let anchor = ids.firstIndex(of: remainingShowing[max(0, position)]) {
            ids.insert(stage.id, at: anchor)
        } else if let last = remainingShowing.last, let anchor = ids.firstIndex(of: last) {
            ids.insert(stage.id, at: anchor + 1)
        } else {
            ids.append(stage.id)
        }
        var tools: [Int] = []
        for id in ids {
            if let found = Self.stages.first(where: { $0.id == id }) { tools.append(contentsOf: found.tools) }
        }
        DigiToolOrder.save(tools)
        orderRaw = tools.map(String.init).joined(separator: ",")
    }

    /// Sections with at least one tool showing, each listing only its showing tools.
    private var visibleStages: [ProofStage] {
        let hiddenNow = hidden
        var result: [ProofStage] = []
        for stage in orderedStages {
            let tools = stage.tools.filter { !hiddenNow.contains($0) }
            if !tools.isEmpty {
                result.append(ProofStage(id: stage.id, name: stage.name, icon: stage.icon, tools: tools))
            }
        }
        return result
    }

    private var currentStage: ProofStage {
        let stages = visibleStages
        return stages.first { $0.tools.contains(model.lastTab) } ?? stages[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            timeline
                .zIndex(1)
            Rectangle().fill(t.line).frame(height: 1)
            nextStrip
            if currentStage.tools.count > 1 { subTools }
            content
        }
        .background(t.background)
    }

    /// v1.9: the name sits centered on the same line as the window buttons.
    private var topBar: some View {
        HStack(spacing: 7) {
            ProofMark(size: 16)
            Text("Proof")
                .font(DigiBrand.display(14, .semibold))
                .kerning(-0.3)
                .foregroundStyle(t.text)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DigiBrand.titleBarInset)
        .allowsHitTesting(false)
    }

    /// Light, Dark or Match System, for every screen in Proof.
    private var appearanceMenu: some View {
        Menu {
            Picker("Appearance", selection: Binding(
                get: { appearance },
                set: { value in
                    MainActor.assumeIsolated { DigiAppearance.apply(value) }
                    appearance = value
                }
            )) {
                Label("Light", systemImage: "sun.max").tag("light")
                Label("Dark", systemImage: "moon").tag("dark")
                Label("Match System", systemImage: "circle.lefthalf.filled").tag("system")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: DigiAppearance.isDark ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(t.subtext)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance: Light, Dark or Match System")
        .accessibilityLabel("Appearance")
    }

    // MARK: Sections

    private func stageDone(_ stage: ProofStage) -> Bool {
        switch stage.id {
        case 0: return model.root != nil
        case 2:
            if model.syncBusy { return false }
            return DigiBackupSnapshot.from(model).lastBackup != nil
        default: return false
        }
    }

    private func stageNote(_ stage: ProofStage) -> String {
        switch stage.id {
        case 0: return model.root?.lastPathComponent ?? "Open a session"
        case 1: return "Make folders"
        case 2:
            let snapshot = DigiBackupSnapshot.from(model)
            if snapshot.running {
                if snapshot.paused { return "Paused" }
                return "Copying \(Int((snapshot.fraction * 100).rounded()))%"
            }
            if let last = snapshot.lastBackup { return "Saved " + DigiNextStep.ago(last) }
            if model.backups.isEmpty { return "Choose drives" }
            return "Not yet"
        case 3: return "Session vs. backups"
        case 4: return "Picks and metadata"
        case 5: return "Exports and sheets"
        default: return "The day's report"
        }
    }

    private var timeline: some View {
        HStack(spacing: 8) {
            ForEach(Array(visibleStages.enumerated()), id: \.element.id) { position, stage in
                stageButton(stage, position: position, count: visibleStages.count)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private func stageButton(_ stage: ProofStage, position: Int, count: Int) -> some View {
        let selected = currentStage.id == stage.id
        let done = stageDone(stage)
        let iconName = done && !selected ? "checkmark" : stage.icon
        let iconColor: Color = selected ? t.onAccent : (done ? t.good : t.text)
        let fill: Color = selected ? t.accent : t.surface
        let border: Color = selected ? t.accent : (done ? t.good : t.line)
        return Button { model.lastTab = stage.tools[0] } label: {
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 36, height: 36)
                    .background(fill, in: Circle())
                    .overlay(Circle().strokeBorder(border, lineWidth: 1.5))
                VStack(spacing: 2) {
                    Text(stage.name)
                        .font(DigiBrand.body(14, selected ? .semibold : .medium))
                        .foregroundStyle(t.text)
                    Text(stageNote(stage))
                        .font(DigiBrand.body(11))
                        .foregroundStyle(t.subtext)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selected ? t.surface : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stage.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { stageMenu(stage) }
        .modifier(DigiArrangeDrag(index: position, count: count, vertical: false, removable: stage.id != 0,
            onMove: { destination in moveStage(stage, to: destination) },
            onRemove: { hide(stage.tools) }))
    }

    /// Right-click a section to hide it (Dashboard stays, it holds the session).
    @ViewBuilder private func stageMenu(_ stage: ProofStage) -> some View {
        if stage.id != 0 {
            Button("Hide \(stage.name)") { hide(stage.tools) }
        }
        if !hiddenRaw.isEmpty {
            Button("Show All Sections") { hiddenRaw = "" }
        }
    }

    private func hide(_ tools: [Int]) {
        var set = hidden
        for tool in tools where tool != 0 { set.insert(tool) }
        hiddenRaw = DigiHiddenTools.encode(set)
        if set.contains(model.lastTab) { model.lastTab = 0 }
    }

    // MARK: Next step and the tools inside a section

    private var nextStrip: some View {
        let step = DigiNextStep.current(model)
        return HStack(spacing: 14) {
            Image(systemName: step.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(t.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(DigiBrand.body(15, .semibold)).foregroundStyle(t.text)
                Text(step.detail).font(DigiBrand.body(12)).foregroundStyle(t.subtext)
            }
            Spacer()
            DigiShowHiddenButton()
            appearanceMenu
            DigiSessionChip(model: model)
            DigiNextStepButton(model: model)
            if model.syncBusy { DigiStopButton(model: model) }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(t.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(t.line).frame(height: 1) }
    }

    private var subTools: some View {
        HStack(spacing: 6) {
            ForEach(currentStage.tools, id: \.self) { tool in
                subToolButton(tool)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
    }

    private func subToolButton(_ tool: Int) -> some View {
        let selected = model.lastTab == tool
        return Button { model.lastTab = tool } label: {
            Text(DigiBrand.toolName(tool))
                .font(DigiBrand.body(13, selected ? .semibold : .medium))
                .foregroundStyle(selected ? t.onAccent : t.text)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(selected ? t.accent : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? t.accent : t.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(DigiBrand.toolBlurbs[tool])
        .digiToolMenu(model, tool: tool)
    }
}
