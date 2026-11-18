import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var store: RemoteStore
    @State private var showSettings = false
    @State private var confirmBackup = false
    @State private var confirmStop = false
    @State private var driveWarnings: [String] = []
    @State private var showWarnings = false
    @State private var alertText: String?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    connectionLine
                    if let problem = store.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.bad)
                            .font(.callout)
                    }
                    if let status = store.status {
                        heroCard(status)
                        sessionCard(status)
                        Text("DRIVES").font(.caption.weight(.semibold)).foregroundStyle(Theme.subtext).padding(.top, 4)
                        if status.drives.isEmpty {
                            Card { Text("No backup drives are set up in Studio Session yet.").foregroundStyle(Theme.subtext) }
                        }
                        ForEach(Array(status.drives.enumerated()), id: \.element.id) { index, drive in
                            DriveCard(drive: drive, color: Theme.drive(index), running: status.running)
                        }
                    } else {
                        Card {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(store.refreshing ? "Connecting to \(store.paired?.macName ?? "the Mac")…" : "Waiting for the Mac…")
                                    .foregroundStyle(Theme.subtext)
                            }
                            Text("Same Wi-Fi works right away. Away from it, Tailscale must be on for this iPhone and the Mac.")
                                .font(.footnote).foregroundStyle(Theme.subtext)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 110)
            }
            .refreshable { await store.refresh() }
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle(store.paired?.macName ?? "Studio Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog(backupQuestion, isPresented: $confirmBackup, titleVisibility: .visible) {
                Button("Back Up Now") { Task { await startBackup(force: false) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Stop the backup?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop Backup", role: .destructive) { Task { await control("stop") } }
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text("Stops after the current file. Everything copied so far stays on the drives.")
            }
            .alert("Check these drives", isPresented: $showWarnings) {
                Button("Back Up Anyway") { Task { await startBackup(force: true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(driveWarnings.joined(separator: "\n\n"))
            }
            .alert(alertText ?? "", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.raised))
                        .overlay(Capsule().stroke(Theme.line))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 6)
                }
            }
        }
    }

    // MARK: Pieces

    private var connectionLine: some View {
        HStack(spacing: 8) {
            Circle().fill(store.reachable ? Theme.good : Theme.bad).frame(width: 8, height: 8)
            Image(systemName: store.route.icon).font(.caption)
            Text(store.reachable ? store.route.label : "Can't reach the Mac")
            if !store.reachable, let last = store.lastContact {
                Text("· last update " + Format.ago(last)).foregroundStyle(Theme.subtext)
            }
            Spacer()
            if store.refreshing { ProgressView().scaleEffect(0.7) }
        }
        .font(.footnote)
        .foregroundStyle(store.reachable ? Theme.text : Theme.bad)
    }

    private func heroCard(_ status: RemoteStatus) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: heroIcon(status))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(heroColor(status))
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.nextTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.text)
                    if !status.nextDetail.isEmpty {
                        Text(status.nextDetail).foregroundStyle(Theme.subtext)
                    }
                }
            }
            if status.running {
                ColorBar(fraction: status.fraction, color: status.paused ? Theme.warn : Theme.accent, height: 10)
                HStack {
                    Text("\(Int((status.fraction * 100).rounded()))%").font(.headline.monospacedDigit())
                    if status.verifying { Text("Reading back").foregroundStyle(Theme.subtext) }
                    Spacer()
                    if status.mbps > 0 && !status.paused {
                        Text(String(format: "%.0f MB/s", status.mbps)).monospacedDigit()
                    }
                    let eta = Format.eta(status.eta)
                    if !eta.isEmpty && !status.paused { Text("· " + eta).foregroundStyle(Theme.subtext) }
                }
                .font(.subheadline)
            }
            if !status.message.isEmpty && (status.running || status.checkingDrives) {
                Text(status.message).font(.footnote).foregroundStyle(Theme.subtext)
            }
        }
        .opacity(store.reachable ? 1 : 0.55)
    }

    private func sessionCard(_ status: RemoteStatus) -> some View {
        Card {
            row("Backing up", status.source ?? "No folder chosen", icon: "folder.fill")
            if let session = status.session, session != status.source {
                row("Session", session, icon: "camera.aperture")
            }
            row("Checking", checkingName(status.checking), icon: "checkmark.shield")
            row("Automatic", status.scheduleOn ? status.scheduleStatus : "Off", icon: "clock.arrow.circlepath")
            if status.scheduleOn, let next = status.nextScheduledRun, next > Date() {
                row("Next run", next.formatted(date: .omitted, time: .shortened), icon: "timer")
            }
        }
        .opacity(store.reachable ? 1 : 0.55)
    }

    private func row(_ label: String, _ value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.subtext).frame(width: 20)
            Text(label).foregroundStyle(Theme.subtext).frame(width: 90, alignment: .leading)
            Text(value).foregroundStyle(Theme.text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }

    @ViewBuilder private var actionBar: some View {
        let status = store.status
        VStack(spacing: 0) {
            Divider().overlay(Theme.line)
            HStack(spacing: 10) {
                if let status, status.running {
                    Button {
                        Task { await control(status.paused ? "resume" : "pause") }
                    } label: {
                        Label(status.paused ? "Resume" : "Pause", systemImage: status.paused ? "play.fill" : "pause.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        confirmStop = true
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        if let status, status.canBackUp {
                            confirmBackup = true
                        } else {
                            alertText = whyNot(status)
                        }
                    } label: {
                        HStack {
                            if store.actionRunning || status?.checkingDrives == true {
                                ProgressView().tint(Theme.onAccent)
                                Text("Checking drives…")
                            } else {
                                Image(systemName: "externaldrive.fill.badge.timemachine")
                                Text("Back Up Now")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(store.actionRunning || !store.reachable || status?.checkingDrives == true)
                }
            }
            .disabled(store.actionRunning)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Actions

    private var backupQuestion: String {
        guard let status = store.status else { return "Back up now?" }
        let count = status.drives.count
        let drives = count == 1 ? "1 drive" : "\(count) drives"
        return "Back up \(status.source ?? "the session") to \(drives) on \(status.macName)?"
    }

    private func whyNot(_ status: RemoteStatus?) -> String {
        guard let status else { return "Not connected to the Mac yet." }
        if status.source == nil { return "No folder is chosen to back up. Open the session in Studio Session on the Mac first." }
        if status.drives.isEmpty { return "No backup drives are set up. Add one in Studio Session's Backups tab on the Mac." }
        if status.checkingDrives { return "The Mac is checking the drives. One moment." }
        return status.nextDetail.isEmpty ? "The Mac can't start a backup right now." : status.nextDetail
    }

    private func startBackup(force: Bool) async {
        let outcome = await store.backUp(force: force)
        switch outcome {
        case .started(let text):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show(text)
        case .confirm(let warnings):
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            driveWarnings = warnings
            showWarnings = true
        case .refused(let text):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            alertText = text
        }
    }

    private func control(_ action: String) async {
        if let text = await store.control(action) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            show(text)
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { if toast == text { toast = nil } }
        }
    }

    // MARK: Helpers

    private func heroIcon(_ status: RemoteStatus) -> String {
        if status.running { return status.paused ? "pause.circle.fill" : "arrow.triangle.2.circlepath.circle.fill" }
        if status.drives.contains(where: { $0.state == "problem" }) { return "exclamationmark.triangle.fill" }
        if status.source == nil { return "folder.badge.questionmark" }
        if status.drives.allSatisfy({ !$0.connected }) && !status.drives.isEmpty { return "externaldrive.badge.xmark" }
        return "checkmark.seal.fill"
    }

    private func heroColor(_ status: RemoteStatus) -> Color {
        if status.running { return status.paused ? Theme.warn : Theme.accent }
        if status.drives.contains(where: { $0.state == "problem" }) { return Theme.bad }
        if status.source == nil || status.drives.isEmpty { return Theme.subtext }
        if status.drives.allSatisfy({ !$0.connected }) { return Theme.warn }
        return Theme.good
    }

    private func checkingName(_ mode: String) -> String {
        switch mode {
        case "full": return "Full verify"
        case "quick": return "Quick"
        case "off": return "Off"
        default: return mode.capitalized
        }
    }
}

struct DriveCard: View {
    var drive: RemoteDrive
    var color: Color
    var running: Bool

    var body: some View {
        Card {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 6, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    Text(statusText).font(.subheadline).foregroundStyle(statusColor).lineLimit(2)
                }
                Spacer()
                if drive.state == "copying" && drive.mbps > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.0f", drive.mbps)).font(.title3.weight(.bold).monospacedDigit())
                        Text("MB/s").font(.caption2).foregroundStyle(Theme.subtext)
                    }
                }
            }
            if ["copying", "paused", "queued"].contains(drive.state) || (running && drive.fraction > 0) {
                ColorBar(fraction: drive.fraction, color: color)
                HStack {
                    Text("\(Int((drive.fraction * 100).rounded()))%").monospacedDigit()
                    if drive.filesTotal > 0 {
                        Text("· \(drive.filesDone.formatted()) of \(drive.filesTotal.formatted()) files").foregroundStyle(Theme.subtext)
                    }
                    Spacer()
                    Text(Format.eta(drive.eta)).foregroundStyle(Theme.subtext)
                }
                .font(.caption)
            }
            if let free = drive.freeBytes, let total = drive.totalBytes, total > 0 {
                let used: Double = 1 - Double(free) / Double(total)
                VStack(alignment: .leading, spacing: 4) {
                    ColorBar(fraction: used, color: used > 0.9 ? Theme.bad : Theme.subtext.opacity(0.6), height: 4)
                    Text("\(Format.bytes(free)) free of \(Format.bytes(total))")
                        .font(.caption).foregroundStyle(Theme.subtext)
                }
            }
            if let last = drive.lastBackup {
                Text(lastText(last)).font(.caption).foregroundStyle(Theme.subtext)
            }
            ForEach(notes, id: \.self) { note in
                Label(note.text, systemImage: note.icon)
                    .font(.caption)
                    .foregroundStyle(note.color)
            }
        }
    }

    private struct Note: Hashable {
        var text: String
        var icon: String
        var colorName: String
        var color: Color { colorName == "bad" ? Theme.bad : Theme.warn }
    }

    private var notes: [Note] {
        var list: [Note] = []
        if drive.heldRemovals > 0 {
            list.append(Note(text: "Held: \(drive.heldRemovals) backed-up files are gone from the source. Review it on the Mac.", icon: "hand.raised.fill", colorName: "warn"))
        }
        if drive.problemFiles > 0 {
            let noun = drive.problemFiles == 1 ? "file" : "files"
            list.append(Note(text: "\(drive.problemFiles) \(noun) couldn't be backed up. See the report on the Mac.", icon: "xmark.octagon.fill", colorName: "bad"))
        }
        if drive.skippedFiles > 0 {
            let noun = drive.skippedFiles == 1 ? "file was" : "files were"
            list.append(Note(text: "\(drive.skippedFiles) \(noun) still being written and skipped. The next backup gets them.", icon: "clock.badge.exclamationmark", colorName: "warn"))
        }
        if drive.errorCount > 0 && drive.state == "problem" {
            let noun = drive.errorCount == 1 ? "error" : "errors"
            list.append(Note(text: "\(drive.errorCount) \(noun)", icon: "exclamationmark.triangle.fill", colorName: "bad"))
        }
        return list
    }

    private var statusText: String {
        switch drive.state {
        case "disconnected": return "Not connected"
        case "copying": return drive.verifying ? "Reading back to check copies" : drive.status
        default: return drive.status
        }
    }

    private var statusColor: Color {
        switch drive.state {
        case "done": return Theme.good
        case "problem": return Theme.bad
        case "disconnected": return Theme.warn
        case "paused": return Theme.warn
        default: return Theme.subtext
        }
    }

    private func lastText(_ date: Date) -> String {
        var text = "Last backup " + Format.ago(date)
        if let files = drive.lastFiles, let bytes = drive.lastBytes, files > 0 {
            text += " · \(files.formatted()) files, \(Format.bytes(bytes))"
        }
        if let mbps = drive.lastMBps, mbps > 0 { text += String(format: " at %.0f MB/s", mbps) }
        return text
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var manualHost = ""
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                if let mac = store.paired {
                    Section("Mac") {
                        LabeledContent("Name", value: mac.macName)
                        if let version = store.status?.appVersion { LabeledContent("Studio Session", value: version) }
                        LabeledContent("Connected by", value: store.reachable ? store.route.label : "Not connected")
                        if let host = mac.lastGoodHost { LabeledContent("Address", value: host) }
                    }
                    Section {
                        LabeledContent("Wi-Fi", value: mac.lan.isEmpty ? "None" : mac.lan.joined(separator: ", "))
                        LabeledContent("Tailscale", value: mac.tailscale.isEmpty ? "Not set up" : mac.tailscale.joined(separator: ", "))
                        TextField("Other address (optional)", text: $manualHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit { store.setManualHost(manualHost) }
                    } header: {
                        Text("Addresses")
                    } footer: {
                        Text("Off the Wi-Fi this app reaches the Mac through Tailscale. Install Tailscale on the Mac and this iPhone, signed in to the same account, and leave it on. The Mac has to be awake.")
                    }
                    Section {
                        Button("Forget This Mac", role: .destructive) { confirmForget = true }
                    } footer: {
                        Text("To also remove this iPhone on the Mac: Studio Session > iPhone Remote… > Remove.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if manualHost != (store.paired?.manualHost ?? "") { store.setManualHost(manualHost) }
                        dismiss()
                    }
                }
            }
            .onAppear { manualHost = store.paired?.manualHost ?? "" }
            .confirmationDialog("Forget \(store.paired?.macName ?? "this Mac")?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    store.forget()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need a new code from the Mac to pair again.")
            }
        }
    }
}
