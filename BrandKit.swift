import SwiftUI
import AppKit

// Shared pieces every app shell uses: a plain-language reading of the
// backup state, the single "what to do next" step, and the guided tour.

enum DigiDriveState {
    case idle, copying, paused, queued, done, problem, disconnected
}

struct DigiDriveLine: Identifiable {
    let id: String
    let name: String
    let fraction: Double
    let status: String
    let mbps: Double
    let state: DigiDriveState
    let lastBackup: Date?
    /// v1.26: seconds left on this drive while it copies.
    var eta: Double? = nil
    /// v1.28: in Full verify's read-back pass.
    var verifying: Bool = false
}

struct DigiBackupSnapshot {
    let running: Bool
    let paused: Bool
    let fraction: Double
    let mbps: Double
    let drives: [DigiDriveLine]
    let lastBackup: Date?
    /// v1.26: time until the slowest copying drive finishes.
    var eta: Double? = nil

    /// "about 3 min left", "under a minute left", or "" when unknown.
    static func etaText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 60 { return "under a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        return String(format: "about %dh %02dm left", minutes / 60, minutes % 60)
    }

    var connectedCount: Int { drives.filter { $0.state != .disconnected }.count }
    var doneCount: Int { drives.filter { $0.state == .done }.count }
    var problemCount: Int { drives.filter { $0.state == .problem }.count }

    @MainActor static func from(_ model: WrapModel) -> DigiBackupSnapshot {
        var lines: [DigiDriveLine] = []
        var total: Int64 = 0
        var done: Int64 = 0
        var speed: Double = 0
        var newest: Date? = nil
        var longest: Double? = nil
        for destination in model.backups {
            let path = destination.path
            let progress = model.syncProgress.first { $0.destination == path }
            let last = model.lastBackups[path]?.date
            if let last {
                if newest == nil || last > newest! { newest = last }
            }
            let available = WrapModel.availableBackupDirectory(destination)
            var state = DigiDriveState.idle
            var status = available ? "Ready" : "Not connected"
            var fraction: Double = 0
            var mbps: Double = 0
            var driveETA: Double? = nil
            if let progress {
                status = progress.status
                let isComplete = progress.status == DigiFastBackupEngine.completeStatus
                let isProblem = progress.status.hasPrefix("Error") || progress.status == "Source Unavailable" ||
                    progress.status == DigiDestinationLock.busyStatus
                if progress.totalBytes > 0 {
                    // v1.27: Full verify counts copying and reading back, half each.
                    var ratio = Double(progress.completedBytes) / Double(progress.totalBytes)
                    if progress.readBackOn {
                        ratio = Double(progress.completedBytes + progress.verifiedBytes) / Double(progress.totalBytes * 2)
                    }
                    fraction = min(1, max(0, ratio))
                } else if isComplete {
                    fraction = 1
                }
                if isComplete {
                    state = .done
                    fraction = 1
                } else if isProblem {
                    state = .problem
                } else if progress.status.hasPrefix("Stopped") || progress.status.hasPrefix("Skipped") {
                    state = .idle
                } else if progress.status.hasPrefix("Queued") {
                    state = .queued
                } else if model.syncBusy && model.destinationIsPaused(path) {
                    state = .paused
                } else if model.syncBusy {
                    state = .copying
                    mbps = progress.liveMBps
                }
                if state == .copying, let left = progress.eta {
                    driveETA = left
                    longest = max(longest ?? 0, left)
                }
                let work: Int64 = progress.readBackOn ? progress.totalBytes * 2 : progress.totalBytes
                let workDone: Int64 = progress.readBackOn ? progress.completedBytes + progress.verifiedBytes : progress.completedBytes
                total += work
                done += min(workDone, work)
                speed += mbps
            }
            if !available && state != .done && state != .copying {
                state = .disconnected
                status = "Not connected"
            }
            lines.append(DigiDriveLine(id: path, name: destination.lastPathComponent, fraction: fraction,
                                       status: status, mbps: mbps, state: state, lastBackup: last, eta: driveETA,
                                       verifying: progress?.status.hasPrefix("Verifying") == true))
        }
        var overall: Double = 0
        if total > 0 { overall = Double(done) / Double(total) }
        return DigiBackupSnapshot(running: model.syncBusy, paused: model.everythingPaused,
                                  fraction: overall, mbps: speed, drives: lines, lastBackup: newest, eta: longest)
    }
}

enum DigiNextStepKind {
    case openSession, chooseDrive, plugInDrive, backUp, backingUp, paused, safe
}

struct DigiNextStep {
    let kind: DigiNextStepKind
    let title: String
    let detail: String
    let button: String
    let icon: String

    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @MainActor static func current(_ model: WrapModel) -> DigiNextStep {
        guard let root = model.root else {
            return DigiNextStep(kind: .openSession, title: "Open your session",
                detail: "Pick the folder you're shooting into. Nothing in it is moved or changed.",
                button: "Choose Session Folder…", icon: "folder")
        }
        let snapshot = DigiBackupSnapshot.from(model)
        if model.syncBusy {
            let percent = Int((snapshot.fraction * 100).rounded())
            if snapshot.paused {
                return DigiNextStep(kind: .paused, title: "Backup paused at \(percent)%",
                    detail: "Nothing is lost. Resume when you're ready.", button: "Resume", icon: "pause.circle")
            }
            let speed = Int(snapshot.mbps.rounded())
            var detail = speed > 0 ? "Copying \(root.lastPathComponent) at \(speed) MB/s." : "Copying \(root.lastPathComponent)."
            let left = DigiBackupSnapshot.etaText(snapshot.eta)
            if !left.isEmpty { detail += " " + left.prefix(1).uppercased() + left.dropFirst() + "." }
            return DigiNextStep(kind: .backingUp, title: "Backing up: \(percent)%",
                detail: detail, button: "Pause", icon: "pause.fill")
        }
        if model.backups.isEmpty {
            return DigiNextStep(kind: .chooseDrive, title: "Choose a backup drive",
                detail: "Plug in drive(s), get these files to safety.",
                button: "Choose a Drive", icon: "externaldrive.badge.plus")
        }
        if snapshot.connectedCount == 0 {
            let names = model.backups.map(\.lastPathComponent).joined(separator: ", ")
            return DigiNextStep(kind: .plugInDrive, title: "Plug in your backup drive",
                detail: "Not connected: \(names).", button: "Check Again", icon: "cable.connector")
        }
        if let last = snapshot.lastBackup {
            return DigiNextStep(kind: .safe, title: "Backed up \(ago(last))",
                detail: "Back up again after new shots come in.", button: "Back Up Again",
                icon: "checkmark.shield")
        }
        let count = snapshot.connectedCount
        let drives = count == 1 ? "1 drive is" : "\(count) drives are"
        return DigiNextStep(kind: .backUp, title: "Ready to back up",
            detail: "\(drives) ready for \(root.lastPathComponent).", button: "Back Up Now",
            icon: "externaldrive.badge.checkmark")
    }

    @MainActor func perform(_ model: WrapModel) {
        switch kind {
        case .openSession: model.chooseRoot()
        case .chooseDrive:
            model.lastTab = 1
            model.discoverExternalBackupFolders()
        case .plugInDrive: model.objectWillChange.send()
        case .backUp, .safe: model.requestStartSync()
        case .backingUp, .paused: model.togglePauseAll()
        }
    }
}

// MARK: Small shared views

struct DigiCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        let t = DigiBrand.theme
        return content
            .padding(padding)
            .background(t.surface, in: RoundedRectangle(cornerRadius: t.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: t.radius, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }
}

extension View {
    func digiCard(padding: CGFloat = 16) -> some View { modifier(DigiCard(padding: padding)) }
}

struct DigiProgressBar: View {
    let fraction: Double
    var color: Color = DigiBrand.theme.accent
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DigiBrand.theme.line)
                Capsule().fill(color).frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

func digiStateColor(_ state: DigiDriveState) -> Color {
    let t = DigiBrand.theme
    switch state {
    case .copying: return t.accent
    case .paused, .queued: return t.warn
    case .done: return t.good
    case .problem: return t.bad
    case .disconnected: return t.subtext
    case .idle: return t.subtext
    }
}

func digiStateIcon(_ state: DigiDriveState) -> String {
    switch state {
    case .copying: return "arrow.triangle.2.circlepath"
    case .paused: return "pause.circle.fill"
    case .queued: return "clock"
    case .done: return "checkmark.circle.fill"
    case .problem: return "exclamationmark.triangle.fill"
    case .disconnected: return "cable.connector.slash"
    case .idle: return "externaldrive"
    }
}

func digiStateWord(_ line: DigiDriveLine) -> String {
    switch line.state {
    case .copying:
        let left = DigiBackupSnapshot.etaText(line.eta)
        let word: String = line.verifying ? "Verifying" : "Copying"
        let percent = word + " \(Int((line.fraction * 100).rounded()))%"
        return left.isEmpty ? percent : percent + " · " + left
    case .paused: return "Paused"
    case .queued: return "Waiting its turn"
    case .done: return "Up to date"
    case .problem:
        if line.status == DigiDestinationLock.busyStatus { return "In use by another app" }
        return line.status.isEmpty ? "Needs attention" : line.status
    case .disconnected: return "Not connected"
    case .idle:
        if let last = line.lastBackup { return "Backed up " + DigiNextStep.ago(last) }
        return "Ready"
    }
}

/// One button that does the most useful thing right now.
struct DigiNextStepButton: View {
    @ObservedObject var model: WrapModel
    var large = false
    var body: some View {
        let step = DigiNextStep.current(model)
        let t = DigiBrand.theme
        return Button { step.perform(model) } label: {
            Label(step.button, systemImage: step.icon)
                .font(DigiBrand.body(large ? 17 : 14, .semibold))
                .padding(.horizontal, large ? 22 : 14)
                .frame(minHeight: large ? 48 : 34)
                .foregroundStyle(t.onAccent)
                .background(t.accent, in: RoundedRectangle(cornerRadius: min(t.radius, 12), style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.driveCheckRunning)
        .help(step.detail)
    }
}

/// Stop is offered next to Pause whenever a backup runs.
struct DigiStopButton: View {
    @ObservedObject var model: WrapModel
    var body: some View {
        let t = DigiBrand.theme
        return Button { model.stopSync() } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(DigiBrand.body(14, .semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .foregroundStyle(t.text)
                .background(t.raised, in: RoundedRectangle(cornerRadius: min(t.radius, 12), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: min(t.radius, 12), style: .continuous).strokeBorder(t.line))
        }
        .buttonStyle(.plain)
        .opacity(model.syncBusy ? 1 : 0)
        .disabled(!model.syncBusy)
    }
}

/// Session name plus a button to change it, used in every shell's header.
struct DigiSessionChip: View {
    @ObservedObject var model: WrapModel
    var body: some View {
        let t = DigiBrand.theme
        return Button { choose() } label: {
            HStack(spacing: 8) {
                Image(systemName: model.root == nil ? "folder.badge.questionmark" : "folder.fill")
                    .foregroundStyle(model.root == nil ? t.subtext : t.accent)
                Text(model.root?.lastPathComponent ?? "No session open")
                    .font(DigiBrand.body(13, .semibold))
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(t.subtext)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(t.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(t.line))
        }
        .buttonStyle(.plain)
        .help(model.syncBusy ? "You can change sessions after the backup finishes." : "Choose a different session folder")
    }

    private func choose() {
        guard model.syncBusy else { model.chooseRoot(); return }
        let alert = NSAlert()
        alert.messageText = "A backup is running"
        alert.informativeText = "You can change sessions after the backup finishes, or after you stop it."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: Tour

/// A coach card that floats over the app, so "Show Me" changes the screen
/// behind it while the tour keeps going.
struct DigiTourCard: View {
    @ObservedObject var model: WrapModel
    @Binding var isShowing: Bool
    /// true: don't show the tour at launch again. false: "Later", show it next launch.
    let onFinish: (Bool) -> Void
    @State private var index = 0

    init(model: WrapModel, isShowing: Binding<Bool>, onFinish: @escaping (Bool) -> Void) {
        self.model = model
        self._isShowing = isShowing
        self.onFinish = onFinish
    }

    var body: some View {
        let pages = DigiBrand.tour
        let page = pages[min(index, pages.count - 1)]
        let t = DigiBrand.theme
        let last = index >= pages.count - 1
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(t.onAccent)
                    .frame(width: 40, height: 40)
                    .background(t.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("\(index + 1) of \(pages.count)")
                    .font(DigiBrand.numbers(12, .medium))
                    .foregroundStyle(t.subtext)
                Spacer()
                Button { finish(dontShowAgain: false) } label: {
                    Text("Later").font(DigiBrand.body(12, .medium)).foregroundStyle(t.subtext)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close the tour. It comes back next time you open \(DigiBrand.name).")
                Button { finish(dontShowAgain: true) } label: {
                    Text("Don't Show Again").font(DigiBrand.body(12, .semibold)).foregroundStyle(t.subtext)
                }
                .buttonStyle(.plain)
                .help("The question mark in the bottom right corner brings it back any time.")
            }
            Text(page.title)
                .font(DigiBrand.display(22))
                .foregroundStyle(t.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(page.body)
                .font(DigiBrand.body(14))
                .foregroundStyle(t.subtext)
                .fixedSize(horizontal: false, vertical: true)
            if let action = page.action {
                Button { run(action) } label: {
                    Label(page.actionTitle, systemImage: "hand.tap")
                        .font(DigiBrand.body(13, .semibold))
                        .foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(pages) { item in
                        Circle()
                            .fill(item.id == index ? t.accent : t.line)
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if index > 0 {
                    Button("Back") { index -= 1 }
                        .buttonStyle(.plain)
                        .font(DigiBrand.body(13, .medium))
                        .foregroundStyle(t.subtext)
                }
                Button { if last { finish(dontShowAgain: true) } else { index += 1 } } label: {
                    Text(last ? "Start Using \(DigiBrand.name)" : "Next")
                        .font(DigiBrand.body(13, .semibold))
                        .foregroundStyle(t.onAccent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 32)
                        .background(t.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(t.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.accent.opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 10)
        .padding(22)
        .environment(\.colorScheme, t.scheme)
    }

    private func run(_ action: DigiTourAction) {
        switch action {
        case .openSession: model.chooseRoot()
        case .showTool(let tool):
            model.lastTab = tool
            NotificationCenter.default.post(name: .digiToolChosen, object: nil)
        }
    }

    private func finish(dontShowAgain: Bool) {
        isShowing = false
        index = 0
        onFinish(dontShowAgain)
    }
}

// MARK: Hiding tools

/// Which tools the person has hidden. Shared with Digi Suite's own tab hiding,
/// so the setting means the same thing everywhere. Home (tool 0) always stays.
enum DigiHiddenTools {
    static let key = "DigiSuite.hiddenTabs.v1"

    static func parse(_ raw: String) -> Set<Int> {
        let numbers = raw.split(separator: ",").compactMap { Int($0) }
        return Set(numbers.filter { $0 > 0 && $0 < 9 })
    }

    static func encode(_ hidden: Set<Int>) -> String {
        hidden.sorted().map(String.init).joined(separator: ",")
    }
}

/// Right-click a tool to hide it, or to bring every hidden tool back.
struct DigiToolMenu: ViewModifier {
    @ObservedObject var model: WrapModel
    let tool: Int
    @AppStorage(DigiHiddenTools.key) private var hiddenRaw = ""

    init(model: WrapModel, tool: Int) {
        self.model = model
        self.tool = tool
    }

    func body(content: Content) -> some View {
        content.contextMenu {
            if tool != 0 {
                Button("Hide \(DigiBrand.toolName(tool))") { hide() }
            }
            if !hiddenRaw.isEmpty {
                Button("Show All Tools") { hiddenRaw = "" }
            }
        }
    }

    private func hide() {
        var hidden = DigiHiddenTools.parse(hiddenRaw)
        hidden.insert(tool)
        hiddenRaw = DigiHiddenTools.encode(hidden)
        if model.lastTab == tool { model.lastTab = 0 }
    }
}

extension View {
    func digiToolMenu(_ model: WrapModel, tool: Int) -> some View {
        modifier(DigiToolMenu(model: model, tool: tool))
    }
}

/// Appears only when something is hidden: one click brings it all back.
struct DigiShowHiddenButton: View {
    @AppStorage(DigiHiddenTools.key) private var hiddenRaw = ""
    var compact = false

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        let count = DigiHiddenTools.parse(hiddenRaw).count
        let t = DigiBrand.theme
        if count > 0 {
            Button { hiddenRaw = "" } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                    if !compact { Text(count == 1 ? "Show 1 hidden tool" : "Show \(count) hidden tools") }
                }
                .font(DigiBrand.body(12, .medium))
                .foregroundStyle(t.subtext)
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Bring back the tools you hid")
        }
    }
}

/// Hides tools (never Home) and leaves a hidden tool if it was open.
@MainActor func digiHideTools(_ model: WrapModel, _ tools: [Int]) {
    let raw = UserDefaults.standard.string(forKey: DigiHiddenTools.key) ?? ""
    var hidden = DigiHiddenTools.parse(raw)
    for tool in tools where tool != 0 { hidden.insert(tool) }
    UserDefaults.standard.set(DigiHiddenTools.encode(hidden), forKey: DigiHiddenTools.key)
    if hidden.contains(model.lastTab) { model.lastTab = 0 }
}

/// v1.12: the order the person arranged the tools in. Saved per app.
enum DigiToolOrder {
    static let key = "DigiBrand.toolOrder.v1"

    static func current() -> [Int] {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        let saved = raw.split(separator: ",").compactMap { Int($0) }
        if saved.count == 9 && Set(saved) == Set(0..<9) { return saved }
        return DigiBrand.defaultToolOrder
    }

    static func save(_ order: [Int]) {
        UserDefaults.standard.set(order.map(String.init).joined(separator: ","), forKey: key)
    }

    /// Moves a tool so it lands at `position` among the tools on screen.
    static func move(_ tool: Int, to position: Int, hidden: Set<Int>) {
        var order = current()
        guard let from = order.firstIndex(of: tool) else { return }
        order.remove(at: from)
        let visible = order.filter { !hidden.contains($0) }
        if position < visible.count {
            let anchor = visible[max(0, position)]
            let index = order.firstIndex(of: anchor) ?? order.count
            order.insert(tool, at: index)
        } else if let last = visible.last, let index = order.firstIndex(of: last) {
            order.insert(tool, at: index + 1)
        } else {
            order.append(tool)
        }
        save(order)
    }
}

/// Drag a tool along its bar to move it; drag it off the bar to remove it in a
/// puff of smoke, like the Dock. Rows move sideways and remove downward; Grip's
/// sidebar moves up and down and removes to the right.
struct DigiArrangeDrag: ViewModifier {
    let index: Int
    let count: Int
    let vertical: Bool
    let removable: Bool
    let onMove: @MainActor (Int) -> Void
    let onRemove: @MainActor () -> Void
    @State private var drag: CGSize = .zero
    @State private var poofing = false
    @State private var itemSize: CGSize = CGSize(width: 100, height: 40)

    init(index: Int, count: Int, vertical: Bool, removable: Bool,
         onMove: @escaping @MainActor (Int) -> Void, onRemove: @escaping @MainActor () -> Void) {
        self.index = index
        self.count = count
        self.vertical = vertical
        self.removable = removable
        self.onMove = onMove
        self.onRemove = onRemove
    }

    private func along(_ size: CGSize) -> CGFloat { vertical ? size.height : size.width }
    private func across(_ size: CGSize) -> CGFloat { vertical ? size.width : size.height }
    /// One slot: the item plus the usual gap between items.
    private var step: CGFloat { max(20, vertical ? itemSize.height : itemSize.width) + 6 }

    /// v1.13: where the landing mark goes, measured from this item's center.
    private func markerOffset(for destination: Int) -> CGFloat {
        let slots = CGFloat(destination - index)
        if destination > index { return slots * step + step / 2 }
        return slots * step - step / 2
    }

    private func target(_ translation: CGSize) -> Int {
        let moved = Int((along(translation) / step).rounded())
        return min(max(0, index + moved), max(0, count - 1))
    }

    func body(content: Content) -> some View {
        let far = removable && across(drag) > 60
        let fade: Double = poofing ? 0 : (far ? 0.4 : 1)
        let destination = drag == .zero ? index : target(drag)
        let showMarker = !far && !poofing && destination != index
        let accent = DigiBrand.theme.accent
        let shift = markerOffset(for: destination)
        return content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { itemSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in itemSize = newSize }
                }
            )
            .offset(drag)
            .opacity(fade)
            .scaleEffect(poofing ? 0.3 : (drag == .zero ? 1 : 1.04))
            .overlay {
                // The landing mark: a bright line between the two tools it will drop between.
                if showMarker {
                    Capsule()
                        .fill(accent)
                        .frame(width: vertical ? itemSize.width : 4, height: vertical ? 4 : itemSize.height)
                        .shadow(color: accent.opacity(0.7), radius: 5)
                        .offset(x: vertical ? 0 : shift, y: vertical ? shift : 0)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if far || poofing {
                    Image(systemName: "smoke.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(DigiBrand.theme.subtext)
                        .scaleEffect(poofing ? 1.8 : 1)
                        .opacity(poofing ? 0 : 0.9)
                        .offset(drag)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(drag == .zero ? 0 : 10)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        let a = along(value.translation)
                        let c = max(0, across(value.translation))
                        drag = vertical ? CGSize(width: c, height: a) : CGSize(width: a, height: c)
                    }
                    .onEnded { value in
                        if removable && across(value.translation) > 60 {
                            withAnimation(.easeOut(duration: 0.25)) { poofing = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                                MainActor.assumeIsolated {
                                    onRemove()
                                    poofing = false
                                    drag = .zero
                                }
                            }
                            return
                        }
                        let destination = target(value.translation)
                        if destination != index {
                            withAnimation(.spring(response: 0.3)) {
                                drag = .zero
                                MainActor.assumeIsolated { onMove(destination) }
                            }
                        } else {
                            withAnimation(.spring(response: 0.25)) { drag = .zero }
                        }
                    }
            )
    }
}

extension View {
    /// Drag to rearrange a tool, or off its bar to remove it (Home never removes).
    func digiArrange(_ model: WrapModel, tool: Int, index: Int, count: Int, vertical: Bool = false) -> some View {
        modifier(DigiArrangeDrag(index: index, count: count, vertical: vertical, removable: tool != 0,
            onMove: { position in
                let raw = UserDefaults.standard.string(forKey: DigiHiddenTools.key) ?? ""
                DigiToolOrder.move(tool, to: position, hidden: DigiHiddenTools.parse(raw))
            },
            onRemove: { digiHideTools(model, [tool]) }))
    }
}

/// A + button at the end of a tool row. Its menu lists the hidden tools;
/// choosing one brings it back and opens it.
struct DigiAddToolMenu: View {
    @ObservedObject var model: WrapModel
    @AppStorage(DigiHiddenTools.key) private var hiddenRaw = ""

    init(model: WrapModel) { self.model = model }

    private func restore(_ tool: Int) {
        var hidden = DigiHiddenTools.parse(hiddenRaw)
        hidden.remove(tool)
        hiddenRaw = DigiHiddenTools.encode(hidden)
        model.lastTab = tool
    }

    var body: some View {
        let hidden = DigiHiddenTools.parse(hiddenRaw)
        let hiddenTools = DigiBrand.toolOrder.filter { hidden.contains($0) }.map { DigiBrand.tools[$0] }
        let t = DigiBrand.theme
        return Menu {
            if hiddenTools.isEmpty {
                Text("All tools are showing")
            }
            ForEach(hiddenTools) { tool in
                Button { restore(tool.id) } label: {
                    Label(tool.name, systemImage: tool.icon)
                }
            }
            if hiddenTools.count > 1 {
                Divider()
                Button("Add All Back") { hiddenRaw = "" }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hiddenTools.isEmpty ? t.subtext.opacity(0.5) : t.text)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(hiddenTools.isEmpty ? "All tools are showing. Drag one off the bar to remove it." : "Add a tool back")
        .accessibilityLabel("Add a tool back")
    }
}

/// Small question mark in the bottom right corner that brings the tour back.
struct DigiTourButton: View {
    var body: some View {
        let t = DigiBrand.theme
        return Button { NotificationCenter.default.post(name: .digiShowTour, object: nil) } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(t.subtext)
                .frame(width: 28, height: 28)
                .background(t.raised, in: Circle())
                .overlay(Circle().strokeBorder(t.line))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .help("Show the tour")
        .accessibilityLabel("Show the tour")
        .padding(10)
    }
}

extension Notification.Name {
    static let digiShowTour = Notification.Name("DigiBrand.showTour")
    /// Posted when a tool is chosen from outside the shell (menu, tour).
    static let digiToolChosen = Notification.Name("DigiBrand.toolChosen")
}

// MARK: Using the title bar strip

/// v1.9: the five apps hide the system title bar. macOS still keeps its strip
/// free by default, which doubled the gap at the top. The apps now draw into
/// that strip themselves: the name sits on the same line as the window buttons,
/// and the controls start right below it.
struct DigiTitleBarSpace: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if DigiBrand.isClassic {
            content
        } else {
            content.ignoresSafeArea(.container, edges: .top)
        }
    }
}

// MARK: Window size memory

/// Remembers the window's size and position between launches, even when macOS
/// is set to close windows on quit. The first launch uses the window's default
/// size, which is big enough to show the whole dashboard.
struct DigiWindowFrameSaver: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView { SaverView(name: name) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class SaverView: NSView {
        let name: String

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = self.window, window.frameAutosaveName.isEmpty else { return }
            _ = window.setFrameAutosaveName(name)
        }
    }
}
