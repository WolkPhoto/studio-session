import SwiftUI

struct PairView: View {
    @EnvironmentObject private var store: RemoteStore
    @State private var selected: String?
    @State private var manualHost = ""
    @State private var code = ""
    @State private var working = false
    @State private var message: String?
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pair with Studio Session")
                            .font(.title.weight(.bold))
                            .foregroundStyle(Theme.text)
                        Text("On the Mac, choose Studio Session > iPhone Remote…, turn it on and click Pair an iPhone. A six-digit code appears.")
                            .foregroundStyle(Theme.subtext)
                    }

                    Card {
                        Text("1. Pick your Mac").font(.headline).foregroundStyle(Theme.text)
                        if store.browser.blocked {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("iPhone isn't letting this app look on your Wi-Fi.", systemImage: "wifi.exclamationmark")
                                    .foregroundStyle(Theme.warn)
                                Text("Turn on Local Network for SS Remote, then come back here. Your Mac will show up to tap.")
                                    .font(.footnote).foregroundStyle(Theme.subtext)
                                Button("Open Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                                }
                                .buttonStyle(.bordered)
                            }
                        } else if store.browser.found.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Looking for Macs on this Wi-Fi…").foregroundStyle(Theme.subtext)
                            }
                        }
                        ForEach(store.browser.found) { mac in
                            Button {
                                selected = mac.name
                                manualHost = ""
                            } label: {
                                HStack {
                                    Image(systemName: selected == mac.name ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selected == mac.name ? Theme.accent : Theme.subtext)
                                    Image(systemName: "desktopcomputer")
                                    Text(mac.name).foregroundStyle(Theme.text)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Divider().overlay(Theme.line)
                        Text("Mac not listed? Type its address instead. Studio Session's iPhone Remote window shows it (Same Wi-Fi, or Tailscale when you're away).")
                            .font(.footnote).foregroundStyle(Theme.subtext)
                        TextField("Mac address, e.g. 192.168.0.215", text: $manualHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                            .onChange(of: manualHost) { _, value in
                                if !value.isEmpty { selected = nil }
                            }
                    }

                    Card {
                        Text("2. Type the code from the Mac").font(.headline).foregroundStyle(Theme.text)
                        TextField("000000", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                            .focused($codeFocused)
                            .onChange(of: code) { _, value in
                                let digits = String(value.filter(\.isNumber).prefix(6))
                                if digits != value { code = digits }
                            }
                    }

                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.bad)
                    }

                    Button {
                        Task { await pair() }
                    } label: {
                        HStack {
                            if working { ProgressView().tint(Theme.onAccent) }
                            Text(working ? "Pairing…" : "Pair").font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(working)
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Studio Session Remote")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                store.browser.start()
                if selected == nil, store.browser.found.count == 1 { selected = store.browser.found[0].name }
            }
            .onChange(of: store.browser.found) { _, found in
                if selected == nil, manualHost.isEmpty, found.count == 1 { selected = found[0].name }
            }
        }
    }

    private func pair() async {
        working = true
        message = nil
        codeFocused = false
        defer { working = false }
        var host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        var port = RemoteClient.defaultPort
        if selected == nil && host.isEmpty {
            message = store.browser.found.isEmpty
                ? "No Mac found on this Wi-Fi. Type the Mac's address above, or turn on Settings > Privacy & Security > Local Network > SS Remote."
                : "Pick your Mac first."
            return
        }
        if code.count != 6 {
            message = "Type the six-digit code from the Mac."
            return
        }
        if host.isEmpty {
            guard let name = selected, let mac = store.browser.found.first(where: { $0.name == name }) else {
                message = "Pick your Mac first."
                return
            }
            guard let resolved = await BonjourBrowser.resolve(mac.endpoint) else {
                message = "Found \(name) but couldn't connect. Check the iPhone is on the same Wi-Fi, and that Local Network is on for this app in Settings."
                return
            }
            host = resolved.host
            port = resolved.port
        } else if let colon = host.lastIndex(of: ":"), let typedPort = Int(host[host.index(after: colon)...]) {
            port = typedPort
            host = String(host[host.startIndex..<colon])
        }
        do {
            try await store.pair(host: host, port: port, code: code)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if case RemoteClient.ClientError.unreachable = error {
                message = "Can't reach \(host). Check the address, that iPhone Remote is on in Studio Session, and the Mac is awake."
            } else {
                message = error.localizedDescription
            }
        }
    }
}
