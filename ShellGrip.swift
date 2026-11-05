import SwiftUI

// GRIP: a pro studio tool. Sidebar on the left with every tool and a live
// backup panel that never goes away. Command-1 to Command-9 jump to tools.
// The sidebar collapses to icons (Control-Command-S or the sidebar button).

struct GripShell<Content: View>: View {
    @ObservedObject var model: WrapModel
    let content: Content
    @AppStorage("Grip.sidebarCollapsed") private var collapsed = false
    @AppStorage(DigiHiddenTools.key) private var hiddenRaw = ""
    @AppStorage(DigiToolOrder.key) private var orderRaw = ""

    init(model: WrapModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    private var t: DigiTheme { DigiBrand.theme }
    private var hidden: Set<Int> { DigiHiddenTools.parse(hiddenRaw) }

    var body: some View {
        mainArea
            .background(t.background)
        .frame(minHeight: 640)
    }

    private var mainArea: some View {
        HStack(spacing: 0) {
            sidebar
                .padding(.top, DigiBrand.titleBarInset)
                .frame(width: collapsed ? 72 : 236)
                .background(t.surface)
                .zIndex(1)
            Rectangle().fill(t.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(t.line).frame(height: 1)
                if model.lastTab == 0 { homeHero }
                content
            }
            .background(t.background)
        }
        .background(t.background)
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
    }

    // MARK: Sidebar

    private var sidebarToggle: some View {
        Button { toggleSidebar() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(t.subtext)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.control, .command])
        .help(collapsed ? "Show the full sidebar (Control-Command-S)" : "Collapse the sidebar to icons (Control-Command-S)")
        .accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    private var sidebar: some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 0) {
            if collapsed {
                VStack(spacing: 6) {
                    GripMark(size: 20)
                    sidebarToggle
                }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            } else {
                HStack(spacing: 8) {
                    GripMark(size: 20)
                    Text("STUDIO SESSION")
                        .font(DigiBrand.display(13, .heavy))
                        .foregroundStyle(t.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    sidebarToggle
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }

            VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
                ForEach(Array(visibleList.enumerated()), id: \.element.id) { position, tool in
                    toolRow(tool, position: position, count: visibleList.count)
                }
                if !collapsed {
                    DigiShowHiddenButton()
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)
            if collapsed {
                collapsedBackupPanel
                    .padding(.bottom, 14)
            } else {
                backupPanel
                    .padding(10)
            }
        }
    }

    private var visibleList: [DigiTool] { DigiBrand.visibleTools(hidden: hidden) }

    private func toolRow(_ tool: DigiTool, position: Int, count: Int) -> some View {
        let selected = model.lastTab == tool.id
        let number = DigiBrand.shortcutNumber(tool.id, hidden: hidden)
        var shortcut = ""
        if let number { shortcut = "⌘" + String(number) }
        var tip = tool.blurb
        if collapsed {
            tip = shortcut.isEmpty ? tool.name : tool.name + "  " + shortcut
        }
        return Button { model.lastTab = tool.id } label: {
            HStack(spacing: 10) {
                Image(systemName: tool.icon)
                    .font(.system(size: collapsed ? 17 : 14, weight: .semibold))
                    .frame(width: 20)
                if !collapsed {
                    Text(tool.name)
                        .font(DigiBrand.body(14, selected ? .semibold : .medium))
                    if tool.id == 8 {
                        Text("BETA").font(.system(size: 9, weight: .bold)).foregroundStyle(selected ? t.onAccent : t.warn)
                    }
                    Spacer()
                    Text(shortcut)
                        .font(DigiBrand.numbers(11, .medium))
                        .foregroundStyle(selected ? t.onAccent.opacity(0.7) : t.subtext.opacity(0.7))
                }
            }
            .foregroundStyle(selected ? t.onAccent : t.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: collapsed ? 48 : .infinity, minHeight: collapsed ? 40 : 34)
            .background(selected ? t.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(tool.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .digiToolMenu(model, tool: tool.id)
        .digiArrange(model, tool: tool.id, index: position, count: count, vertical: true)
    }

    private var backupPanel: some View {
        let snapshot = DigiBackupSnapshot.from(model)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BACKUPS")
                    .font(DigiBrand.numbers(11, .semibold))
                    .foregroundStyle(t.subtext)
                Spacer()
                if snapshot.running {
                    Text("\(Int((snapshot.fraction * 100).rounded()))%")
                        .font(DigiBrand.numbers(12, .semibold))
                        .foregroundStyle(t.accent)
                }
            }
            if snapshot.running { DigiProgressBar(fraction: snapshot.fraction, height: 6) }
            if snapshot.drives.isEmpty {
                Text("No drives chosen yet.")
                    .font(DigiBrand.body(12))
                    .foregroundStyle(t.subtext)
            }
            ForEach(snapshot.drives) { line in
                HStack(spacing: 8) {
                    Image(systemName: digiStateIcon(line.state))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(digiStateColor(line.state))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.name).font(DigiBrand.body(12, .semibold)).foregroundStyle(t.text).lineLimit(1)
                        Text(digiStateWord(line)).font(DigiBrand.body(11)).foregroundStyle(t.subtext).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 6) {
                DigiNextStepButton(model: model)
                if model.syncBusy { DigiStopButton(model: model) }
            }
        }
        .padding(12)
        .background(t.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(snapshot.running ? t.accent.opacity(0.7) : t.line))
    }

    /// Collapsed: a status light, the percent while copying, and the next step as one icon.
    private var collapsedBackupPanel: some View {
        let snapshot = DigiBackupSnapshot.from(model)
        let step = DigiNextStep.current(model)
        var light: Color = t.subtext
        if snapshot.running {
            light = snapshot.paused ? t.warn : t.accent
        } else if snapshot.problemCount > 0 {
            light = t.bad
        } else if snapshot.lastBackup != nil {
            light = t.good
        }
        return VStack(spacing: 8) {
            Circle().fill(light).frame(width: 10, height: 10)
            if snapshot.running {
                Text("\(Int((snapshot.fraction * 100).rounded()))%")
                    .font(DigiBrand.numbers(11, .semibold))
                    .foregroundStyle(t.text)
            }
            Button { step.perform(model) } label: {
                Image(systemName: step.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(t.onAccent)
                    .frame(width: 44, height: 44)
                    .background(t.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.driveCheckRunning)
            .help(step.button + ": " + step.detail)
            .accessibilityLabel(step.button)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Header and Home

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
        .padding(.top, 12)
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
