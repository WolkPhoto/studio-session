import SwiftUI

// TECH CART: made for the cart monitor. A status bar with huge numbers that
// reads from across the set, and a row of big tool buttons along the bottom,
// each showing its live status. One click switches tools; no Home detour.

struct CartShell<Content: View>: View {
    @ObservedObject var model: WrapModel
    let content: Content
    @AppStorage(DigiHiddenTools.key) private var hiddenRaw = ""

    init(model: WrapModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    private var t: DigiTheme { DigiBrand.theme }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Rectangle().fill(t.line).frame(height: 2)
            content
            Rectangle().fill(t.line).frame(height: 2)
            toolDock
        }
        .background(t.background)
    }

    // MARK: Status bar

    private var statusBar: some View {
        let snapshot = DigiBackupSnapshot.from(model)
        let step = DigiNextStep.current(model)
        return HStack(alignment: .center, spacing: 18) {
            CartMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(DigiBrand.toolName(model.lastTab).uppercased())
                    .font(DigiBrand.display(26, .black))
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("TECH CART")
                    .font(DigiBrand.numbers(11, .semibold))
                    .foregroundStyle(t.subtext)
            }
            DigiSessionChip(model: model)
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 2) {
                if snapshot.running {
                    Text(snapshot.paused ? "PAUSED" : "BACKING UP")
                        .font(DigiBrand.body(13, .bold))
                        .foregroundStyle(snapshot.paused ? t.warn : t.accent)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(Int((snapshot.fraction * 100).rounded()))%")
                            .font(DigiBrand.numbers(40, .bold))
                            .foregroundStyle(t.text)
                        if snapshot.mbps > 0 {
                            Text("\(Int(snapshot.mbps.rounded())) MB/s")
                                .font(DigiBrand.numbers(16, .medium))
                                .foregroundStyle(t.subtext)
                        }
                    }
                } else {
                    Text(step.title.uppercased())
                        .font(DigiBrand.display(20, .black))
                        .foregroundStyle(step.kind == .safe ? t.good : t.text)
                        .lineLimit(1)
                    Text(step.detail).font(DigiBrand.body(13)).foregroundStyle(t.subtext).lineLimit(1)
                }
            }
            DigiNextStepButton(model: model, large: true)
            if model.syncBusy { DigiStopButton(model: model) }
            Button { NotificationCenter.default.post(name: .digiShowTour, object: nil) } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 18)).foregroundStyle(t.subtext)
            }
            .buttonStyle(.plain)
            .help("Show the tour")
            .accessibilityLabel("Show the tour")
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 92)
        .padding(.top, DigiBrand.titleBarInset)
        .background(t.surface)
    }

    // MARK: Tool dock

    private func liveLine(_ tool: Int, _ snapshot: DigiBackupSnapshot) -> (String, Color) {
        switch tool {
        case 0:
            if model.root == nil { return ("No session", t.subtext) }
            return ("\(model.assets.count.formatted()) files", t.text)
        case 1:
            if snapshot.running {
                return (snapshot.paused ? "Paused" : "\(Int((snapshot.fraction * 100).rounded()))%", t.accent)
            }
            if snapshot.problemCount > 0 { return ("Needs attention", t.bad) }
            if model.backups.isEmpty { return ("No drives", t.subtext) }
            if let last = snapshot.lastBackup { return ("Saved " + DigiNextStep.ago(last), t.good) }
            return ("\(snapshot.connectedCount) of \(model.backups.count) ready", t.text)
        case 2: return ("Picks list", t.subtext)
        case 3:
            if model.qcRawCount > 0 { return ("\(model.qcMatchedCount) of \(model.qcRawCount) done", t.text) }
            return ("Check exports", t.subtext)
        case 4: return ("Make folders", t.subtext)
        case 5: return ("Day report", t.subtext)
        case 6: return ("Print pages", t.subtext)
        case 7: return ("Match check", t.subtext)
        default: return ("Beta", t.warn)
        }
    }

    private var toolDock: some View {
        let snapshot = DigiBackupSnapshot.from(model)
        let hidden = DigiHiddenTools.parse(hiddenRaw)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(DigiBrand.visibleTools(hidden: hidden)) { tool in
                    dockButton(tool, snapshot, hidden)
                }
                DigiShowHiddenButton(compact: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(t.surface)
    }

    private func dockButton(_ tool: DigiTool, _ snapshot: DigiBackupSnapshot, _ hidden: Set<Int>) -> some View {
        let selected = model.lastTab == tool.id
        let line = liveLine(tool.id, snapshot)
        let live = tool.id == 1 && snapshot.running
        let alert = line.1 == t.bad
        var shortcut = ""
        if let number = DigiBrand.shortcutNumber(tool.id, hidden: hidden) { shortcut = "⌘" + String(number) }
        let textColor: Color = selected ? t.onAccent : t.text
        let lineColor: Color = selected ? t.onAccent.opacity(0.8) : line.1
        let borderColor: Color = alert ? t.bad : (live ? t.accent : t.line)
        return Button { model.lastTab = tool.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: tool.icon)
                        .font(.system(size: 18, weight: .bold))
                    Spacer()
                    Text(shortcut)
                        .font(DigiBrand.numbers(10, .medium))
                        .opacity(0.7)
                }
                Text(tool.name.uppercased())
                    .font(DigiBrand.display(14, .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(line.0)
                    .font(DigiBrand.body(11, .semibold))
                    .foregroundStyle(lineColor)
                    .lineLimit(1)
                if live {
                    DigiProgressBar(fraction: snapshot.fraction, color: selected ? t.onAccent : t.accent, height: 4)
                }
            }
            .foregroundStyle(textColor)
            .padding(12)
            .frame(width: 140, height: 92, alignment: .topLeading)
            .background(selected ? t.accent : t.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? t.accent : borderColor, lineWidth: alert || live ? 2.5 : 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.blurb)
        .accessibilityLabel(tool.name + ". " + line.0)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .digiToolMenu(model, tool: tool.id)
    }
}
