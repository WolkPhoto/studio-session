import SwiftUI

// STUDIO SESSION (code name GRIP): a pro studio tool. v1.29 moves navigation
// from the old slide-out sidebar to tabs across the top (like Tally). The tools,
// their order and the keyboard shortcuts (Command-1..8) are unchanged; only the
// layout moved. The Backups tab carries a live status light, and a thin progress
// strip appears under the tabs while a backup runs, so the backup is never out
// of sight no matter which tool is open.

struct GripShell<Content: View>: View {
    @ObservedObject var model: WrapModel
    let content: Content
    @AppStorage(DigiHiddenTools.key) private var hiddenRaw = ""
    @AppStorage(DigiToolOrder.key) private var orderRaw = ""

    init(model: WrapModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    private var t: DigiTheme { DigiBrand.theme }
    private var hidden: Set<Int> { DigiHiddenTools.parse(hiddenRaw) }
    private var visibleList: [DigiTool] { DigiBrand.visibleTools(hidden: hidden) }

    var body: some View {
        let snapshot = DigiBackupSnapshot.from(model)
        return VStack(spacing: 0) {
            brandStrip
            tabStrip(snapshot)
                .zIndex(1)
            if snapshot.running {
                runningStrip(snapshot)
            }
            Rectangle().fill(t.line).frame(height: 1)
            header
            Rectangle().fill(t.line).frame(height: 1)
            if model.lastTab == 0 { homeHero }
            content
        }
        .background(t.background)
        .frame(minHeight: 620)
    }

    // MARK: Brand line (sits on the window-button row, not clickable so the
    // window still drags there and the traffic lights stay clear on the left).

    private var brandStrip: some View {
        HStack(spacing: 8) {
            GripMark(size: 17)
            Text("STUDIO SESSION")
                .font(DigiBrand.display(13, .heavy))
                .foregroundStyle(t.text)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DigiBrand.titleBarInset)
        .allowsHitTesting(false)
    }

    // MARK: Tabs

    private func tabStrip(_ snapshot: DigiBackupSnapshot) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(visibleList.enumerated()), id: \.element.id) { position, tool in
                tabButton(tool, position: position, count: visibleList.count, snapshot: snapshot)
            }
            DigiAddToolMenu(model: model)
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// Green when the last backup was clean, amber while running, red on a
    /// problem. Always visible on the Backups tab, from any tool.
    private func backupLight(_ snapshot: DigiBackupSnapshot) -> Color {
        if snapshot.running { return snapshot.paused ? t.warn : t.accent }
        if snapshot.problemCount > 0 { return t.bad }
        if snapshot.lastBackup != nil { return t.good }
        return t.subtext
    }

    private func tabButton(_ tool: DigiTool, position: Int, count: Int, snapshot: DigiBackupSnapshot) -> some View {
        let selected = model.lastTab == tool.id
        // Two-word names stack onto two lines; single words stay on one.
        let stacked = tool.name.replacingOccurrences(of: " ", with: "\n")
        return Button { model.lastTab = tool.id } label: {
            VStack(spacing: 4) {
                Image(systemName: tool.icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(stacked)
                    .font(DigiBrand.body(11, selected ? .semibold : .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? t.onAccent : t.text)
            .frame(minWidth: 70, maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(selected ? t.accent : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if tool.id == 1 {
                    Circle()
                        .fill(backupLight(snapshot))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(selected ? t.accent : t.surface, lineWidth: 1.5))
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.blurb)
        .accessibilityLabel(tool.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .digiToolMenu(model, tool: tool.id)
        .digiArrange(model, tool: tool.id, index: position, count: count)
    }

    /// A thin live progress strip under the tabs while a backup runs, so you can
    /// watch it from any tool. Replaces the old always-on sidebar panel.
    private func runningStrip(_ snapshot: DigiBackupSnapshot) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                Text(snapshot.verifying ? "Verifying" : "Backing up")
                    .font(DigiBrand.body(11, .semibold))
                    .foregroundStyle(t.accent)
                let left = DigiBackupSnapshot.etaText(snapshot.eta)
                if !left.isEmpty {
                    Text(left.prefix(1).uppercased() + left.dropFirst())
                        .font(DigiBrand.body(11))
                        .foregroundStyle(t.subtext)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("\(Int((snapshot.fraction * 100).rounded()))%")
                    .font(DigiBrand.numbers(11, .semibold))
                    .foregroundStyle(t.accent)
                if model.syncBusy { DigiStopButton(model: model) }
            }
            DigiProgressBar(fraction: snapshot.fraction, height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Header and Home (unchanged behavior, now below the tabs)

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(DigiBrand.toolName(model.lastTab))
                    .font(DigiBrand.display(21, .heavy))
                    .foregroundStyle(t.text)
                Text(DigiBrand.toolBlurbs[min(8, max(0, model.lastTab))])
                    .font(DigiBrand.body(12))
                    .foregroundStyle(t.subtext)
                    .lineLimit(1)
            }
            Spacer()
            DigiSessionChip(model: model)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var homeHero: some View {
        let step = DigiNextStep.current(model)
        return HStack(spacing: 14) {
            Image(systemName: step.icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(t.accent)
                .frame(width: 44, height: 44)
                .background(t.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT")
                    .font(DigiBrand.numbers(11, .semibold))
                    .foregroundStyle(t.accent)
                Text(step.title)
                    .font(DigiBrand.display(20, .bold))
                    .foregroundStyle(t.text)
                Text(step.detail)
                    .font(DigiBrand.body(13))
                    .foregroundStyle(t.subtext)
            }
            Spacer()
            DigiNextStepButton(model: model, large: true)
            if model.syncBusy { DigiStopButton(model: model) }
        }
        .digiCard(padding: 14)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }
}
