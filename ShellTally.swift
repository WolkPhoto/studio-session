import SwiftUI
import AppKit

// TALLY: quiet until it matters. Lives in the menu bar with a tally light
// that shows the backup state; the window is there when you need a tool.

enum TallyState {
    case off, live, paused, safe, attention

    @MainActor static func current(_ model: WrapModel) -> TallyState {
        let snapshot = DigiBackupSnapshot.from(model)
        if snapshot.problemCount > 0 { return .attention }
        if snapshot.running { return snapshot.paused ? .paused : .live }
        if snapshot.lastBackup != nil { return .safe }
        return .off
    }

    var color: Color {
        let t = DigiBrand.theme
        switch self {
        case .off: return t.subtext
        case .live: return t.accent
        case .paused: return t.warn
        case .safe: return t.good
        case .attention: return t.bad
        }
    }

    var symbol: String {
        switch self {
        case .off: return "circle"
        case .live: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .safe: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        }
    }
}

struct TallyShell<Content: View>: View {
    @ObservedObject var model: WrapModel
    let content: Content
    @AppStorage(DigiHiddenTools.key) private var hiddenRaw = ""
    @AppStorage(DigiToolOrder.key) private var orderRaw = ""

    init(model: WrapModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    private var t: DigiTheme { DigiBrand.theme }

    var body: some View {
        VStack(spacing: 0) {
            statusBand
            toolStrip
                .zIndex(1)
            Rectangle().fill(t.line).frame(height: 1)
            content
        }
        .background(t.background)
    }

    /// v1.8: the title bar strip carries the Tally name, so the status band
    /// below can be slimmer. Leaves room for the window buttons on the left.
    private var brandStrip: some View {
        HStack(spacing: 7) {
            TallyLight(color: t.accent, size: 14, glowing: true)
            Text("Tally")
                .font(DigiBrand.display(13, .bold))
                .foregroundStyle(t.text)
            Text(DigiBrand.tagline)
                .font(DigiBrand.body(12))
                .foregroundStyle(t.subtext)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DigiBrand.titleBarInset)
        .allowsHitTesting(false)
    }

    private var statusBand: some View {
        let state = TallyState.current(model)
        let step = DigiNextStep.current(model)
        return VStack(spacing: 0) {
            brandStrip
            HStack(spacing: 14) {
                TallyLight(color: state.color, size: 34, glowing: state != .off)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(DigiBrand.display(19, .bold))
                        .foregroundStyle(t.text)
                    Text(step.detail)
                        .font(DigiBrand.body(12))
                        .foregroundStyle(t.subtext)
                        .lineLimit(1)
                }
                Spacer()
                DigiSessionChip(model: model)
                DigiNextStepButton(model: model)
                if model.syncBusy { DigiStopButton(model: model) }
            }
            .padding(.horizontal, 22)
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
        .background(state.color.opacity(0.08))
    }

    private var toolStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(visibleList.enumerated()), id: \.element.id) { position, tool in
                toolButton(tool, position: position, count: visibleList.count)
            }
            DigiAddToolMenu(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var visibleList: [DigiTool] { DigiBrand.visibleTools(hidden: DigiHiddenTools.parse(hiddenRaw)) }

    private func toolButton(_ tool: DigiTool, position: Int, count: Int) -> some View {
        let selected = model.lastTab == tool.id
        return Button { model.lastTab = tool.id } label: {
            VStack(spacing: 4) {
                Image(systemName: tool.icon).font(.system(size: 16, weight: .semibold))
                Text(tool.name).font(DigiBrand.body(11, selected ? .semibold : .medium)).lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(selected ? t.text : t.subtext)
            .frame(minWidth: 64, maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 4)
            .background(selected ? t.raised : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottom) {
                if selected { Capsule().fill(t.accent).frame(width: 22, height: 3).padding(.bottom, 3) }
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
}

/// The menu bar panel: everything about backups without opening a window.
struct TallyMenuPanel: View {
    @ObservedObject var model: WrapModel
    @ObservedObject private var watcher = MetadataWatcherModel.shared
    @AppStorage(WrapModel.soundsKey) private var sounds = DigiBrand.soundsDefault
    @Environment(\.openWindow) private var openWindow

    init(model: WrapModel) { self.model = model }

    private var t: DigiTheme { DigiBrand.theme }

    private func showWindow(tool: Int?) {
        if let tool {
            model.lastTab = tool
            NotificationCenter.default.post(name: .digiToolChosen, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == DigiBrand.name && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "workspace")
        }
    }

    var body: some View {
        let state = TallyState.current(model)
        let step = DigiNextStep.current(model)
        let snapshot = DigiBackupSnapshot.from(model)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TallyLight(color: state.color, size: 34, glowing: state != .off)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(DigiBrand.display(16, .bold)).foregroundStyle(t.text)
                    Text(model.root?.lastPathComponent ?? "No session open")
                        .font(DigiBrand.body(12)).foregroundStyle(t.subtext).lineLimit(1)
                }
                Spacer()
            }
            if snapshot.running { DigiProgressBar(fraction: snapshot.fraction, color: state.color, height: 6) }
            if !snapshot.drives.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.drives) { line in
                        HStack(spacing: 8) {
                            Image(systemName: digiStateIcon(line.state))
                                .foregroundStyle(digiStateColor(line.state))
                                .frame(width: 16)
                            Text(line.name).font(DigiBrand.body(13, .semibold)).foregroundStyle(t.text).lineLimit(1)
                            Spacer()
                            Text(digiStateWord(line)).font(DigiBrand.body(12)).foregroundStyle(t.subtext).lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .background(t.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 8) {
                DigiNextStepButton(model: model)
                if model.syncBusy { DigiStopButton(model: model) }
            }
            Rectangle().fill(t.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                if watcher.watching {
                    panelLink("Stop Watching Metadata Folder", icon: "stop.circle") { watcher.stop() }
                }
                Toggle(isOn: $sounds) {
                    Text("Sounds when a backup finishes or needs you")
                        .font(DigiBrand.body(13, .medium))
                        .foregroundStyle(t.text)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.vertical, 4)
                panelLink("Open Tally", icon: "macwindow") { showWindow(tool: nil) }
                panelLink("Compare Copies", icon: "square.split.2x1") { showWindow(tool: 7) }
                panelLink("Backup Schedule and Drives", icon: "calendar.badge.clock") { showWindow(tool: 1) }
                panelLink("Quit Tally", icon: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(t.background)
        .environment(\.colorScheme, t.scheme)
        .onAppear { DigiBackupQuitRegistry.shared.register(model) }
    }

    private func panelLink(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(t.subtext)
                Text(title).font(DigiBrand.body(13, .medium)).foregroundStyle(t.text)
                Spacer()
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
