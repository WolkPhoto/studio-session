import Foundation
import Network
import CryptoKit
import SwiftUI
import AppKit

// v1.47: iPhone Remote. A small HTTP + JSON server inside Studio Session that the
// Studio Session Remote iPhone app talks to. Off until turned on in the iPhone Remote
// window. Every request but /v1/hello needs a token the phone gets by typing the
// six-digit code the Mac shows. Same Wi-Fi: the phone finds the Mac by Bonjour
// (_studiosession._tcp). Away from the Wi-Fi: through Tailscale (100.x address),
// on the same fixed port.

enum DigiRemoteStartResult {
    case started
    case needsConfirm([String])
    case refused(String)
}

// MARK: - What the phone sees

struct DigiRemoteDrive: Codable {
    var id: String
    var name: String
    var state: String          // idle, copying, paused, queued, done, problem, disconnected
    var status: String
    var fraction: Double
    var mbps: Double
    var eta: Double?
    var verifying: Bool
    var connected: Bool
    var freeBytes: Int64?
    var totalBytes: Int64?
    var lastBackup: Date?
    var lastSeconds: Double?
    var lastMBps: Double?
    var lastFiles: Int?
    var lastBytes: Int64?
    var filesDone: Int
    var filesTotal: Int
    var errorCount: Int
    var skippedFiles: Int
    var problemFiles: Int
    var heldRemovals: Int
}

struct DigiRemoteStatus: Codable {
    var macName: String
    var appVersion: String
    var session: String?
    var source: String?
    var sourcePath: String?
    var running: Bool
    var paused: Bool
    var checkingDrives: Bool
    var verifying: Bool
    var fraction: Double
    var mbps: Double
    var eta: Double?
    var message: String
    var nextTitle: String
    var nextDetail: String
    var canBackUp: Bool
    var checking: String
    var scheduleOn: Bool
    var scheduleStatus: String
    var nextScheduledRun: Date?
    var lastBackup: Date?
    var drives: [DigiRemoteDrive]
    var updatedAt: Date
}

struct DigiRemoteDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var tokenHash: String
    var added: Date
    /// v1.47.7: the phone's own ID (identifierForVendor), so pairing the same phone
    /// again replaces its old entry. Nil for phones paired with 1.47 to 1.47.6.
    var deviceKey: String? = nil
}

// MARK: - Pairing, settings and request handling (main actor)

@MainActor final class DigiRemote: ObservableObject {
    static let shared = DigiRemote()
    static let port: UInt16 = 47820
    static let serviceType = "_studiosession._tcp"

    /// v1.47.4: the workspace the phone shows. A running backup wins; otherwise the
    /// window you used last; otherwise the first window. (1.47 always used the first
    /// window, so switching sessions in another window never reached the phone.)
    private weak var focusedModel: WrapModel?
    func noteFocused(_ model: WrapModel) { focusedModel = model }
    func noteClosed(_ model: WrapModel) {
        if focusedModel === model { focusedModel = nil }
    }
    private var shownModel: WrapModel {
        if let running = DigiBackupQuitRegistry.shared.activeBackups.first { return running }
        if let focused = focusedModel { return focused }
        return DigiPrimaryModel.shared
    }
    private static let enabledKey = "DigiSuite.remote.enabled"
    private static let devicesKey = "DigiSuite.remote.devices"

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: DigiRemote.enabledKey)
    @Published private(set) var devices: [DigiRemoteDevice] = DigiRemote.loadDevices()
    @Published private(set) var serverState = "Off"
    @Published private(set) var serverProblem: String?
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpires: Date?
    @Published private(set) var lastSeen: [String: Date] = [:]
    @Published private(set) var lastEvent = ""
    @Published private(set) var addresses = DigiNetworkAddresses(lan: [], tailscale: [])

    private var server: DigiRemoteServer?
    private var failedCodeAttempts = 0

    var macName: String { Host.current().localizedName ?? "Mac" }

    /// iPhone Remote is finished but held for a later release. While this is
    /// false every button and menu item for it is hidden and it never starts.
    /// Saved pairing and settings are kept. Set to true to ship it.
    nonisolated static let isAvailable = false

    func startIfEnabled() {
        guard Self.isAvailable else { return }
        if enabled && server == nil { startServer() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { startServer() } else { stopServer() }
    }

    private func startServer() {
        stopServer()
        serverProblem = nil
        serverState = "Starting…"
        refreshAddresses()
        let server = DigiRemoteServer(port: Self.port, serviceName: macName, serviceType: Self.serviceType)
        server.onState = { [weak self] state, problem in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.serverState = state
                    self.serverProblem = problem
                    self.refreshAddresses()
                }
            }
        }
        server.onRequest = { request, respond in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DigiRemote.shared.handle(request, respond: respond)
                }
            }
        }
        self.server = server
        server.start()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        serverState = "Off"
    }

    func refreshAddresses() {
        addresses = DigiNetworkAddresses.current()
    }

    // Pairing

    func newPairingCode() {
        let number = Int.random(in: 0...999_999)
        pairingCode = String(format: "%06d", number)
        pairingExpires = Date().addingTimeInterval(10 * 60)
        failedCodeAttempts = 0
    }

    func cancelPairing() {
        pairingCode = nil
        pairingExpires = nil
    }

    func remove(_ device: DigiRemoteDevice) {
        devices.removeAll { $0.id == device.id }
        saveDevices()
        lastEvent = device.name + " removed. It can't see or start backups any more."
    }

    private static func loadDevices() -> [DigiRemoteDevice] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey) else { return [] }
        return (try? JSONDecoder().decode([DigiRemoteDevice].self, from: data)) ?? []
    }

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.devicesKey)
        }
    }

    static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func device(for request: DigiHTTPRequest) -> DigiRemoteDevice? {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        let hashed = Self.hash(token)
        return devices.first { $0.tokenHash == hashed }
    }

    // Requests

    private func handle(_ request: DigiHTTPRequest, respond: @escaping (DigiHTTPResponse) -> Void) {
        let route = request.method + " " + request.path
        if route == "GET /v1/hello" {
            respond(.json(["app": "Studio Session", "macName": macName, "version": Self.appVersion,
                           "pairing": pairingCode != nil ? "open" : "closed"]))
            return
        }
        if route == "POST /v1/pair" {
            respond(pair(request))
            return
        }
        guard let device = device(for: request) else {
            respond(.error(401, "This iPhone isn't paired with Studio Session on \(macName) any more. Pair it again."))
            return
        }
        lastSeen[device.id] = Date()
        let model = shownModel
        switch route {
        case "GET /v1/status":
            respond(.encodable(status(model)))
        case "POST /v1/backup":
            let force = request.jsonBody?["force"] as? Bool ?? false
            lastEvent = device.name + " asked for a backup"
            model.requestRemoteStart(force: force, from: device.name) { result in
                switch result {
                case .started:
                    DigiRemote.shared.lastEvent = "Backup started from " + device.name
                    respond(.json(["result": "started", "message": "Backup started."]))
                case .needsConfirm(let warnings):
                    respond(.json(["result": "confirm", "message": "Check these drives before backing up.", "warnings": warnings]))
                case .refused(let reason):
                    respond(.json(["result": "refused", "message": reason]))
                }
            }
        case "POST /v1/pause":
            if model.syncBusy && !model.everythingPaused { model.pauseSync() }
            respond(.json(["result": "ok", "message": model.syncBusy ? "Pausing after the current file." : "No backup is running."]))
        case "POST /v1/resume":
            if model.syncBusy { model.resumeSync() }
            respond(.json(["result": "ok", "message": model.syncBusy ? "Resuming." : "No backup is running."]))
        case "POST /v1/stop":
            if model.syncBusy {
                model.stopSync()
                lastEvent = "Backup stopped from " + device.name
            }
            respond(.json(["result": "ok", "message": model.syncBusy ? "Stopping after the current file." : "No backup is running."]))
        default:
            respond(.error(404, "Unknown request " + route))
        }
    }

    private func pair(_ request: DigiHTTPRequest) -> DigiHTTPResponse {
        guard let code = pairingCode, let expires = pairingExpires, expires > Date() else {
            cancelPairing()
            return .error(403, "Pairing isn't open. On the Mac, choose Studio Session > iPhone Remote… and click Pair an iPhone.")
        }
        let typed = (request.jsonBody?["code"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard typed == code else {
            failedCodeAttempts += 1
            if failedCodeAttempts >= 5 {
                cancelPairing()
                lastEvent = "Pairing closed after 5 wrong codes. Click Pair an iPhone for a new code."
                return .error(403, "Too many wrong codes. Get a new code on the Mac.")
            }
            return .error(403, "That code doesn't match the one on the Mac.")
        }
        let rawName = request.jsonBody?["deviceName"] as? String ?? "iPhone"
        let name = String(rawName.prefix(60))
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
        let rawKey = request.jsonBody?["deviceKey"] as? String ?? ""
        let key: String? = rawKey.isEmpty ? nil : String(rawKey.prefix(64))
        let device = DigiRemoteDevice(id: UUID().uuidString, name: name, tokenHash: Self.hash(token), added: Date(), deviceKey: key)
        if let key {
            // Same phone paired again: its old entry (and old token) goes.
            devices.removeAll { $0.deviceKey == key }
        }
        devices.append(device)
        saveDevices()
        cancelPairing()
        refreshAddresses()
        lastEvent = name + " paired"
        return .json(["token": token, "deviceID": device.id, "macName": macName, "port": Int(Self.port),
                      "lan": addresses.lan, "tailscale": addresses.tailscale])
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private func status(_ model: WrapModel) -> DigiRemoteStatus {
        let snapshot = DigiBackupSnapshot.from(model)
        let next = DigiNextStep.current(model)
        var drives: [DigiRemoteDrive] = []
        for line in snapshot.drives {
            let progress = model.syncProgress.first { $0.destination == line.id }
            let last = model.lastBackups[line.id]
            let url = URL(fileURLWithPath: line.id)
            var free: Int64? = nil
            var total: Int64? = nil
            let connected: Bool = line.state != .disconnected
            if connected, let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
                if let available = values.volumeAvailableCapacity { free = Int64(available) }
                if let capacity = values.volumeTotalCapacity { total = Int64(capacity) }
            }
            var drive = DigiRemoteDrive(id: line.id, name: line.name, state: Self.stateName(line.state), status: line.status,
                                        fraction: line.fraction, mbps: line.mbps, eta: line.eta, verifying: line.verifying,
                                        connected: connected, freeBytes: free, totalBytes: total,
                                        lastBackup: last?.date, lastSeconds: last?.seconds, lastMBps: last?.averageMBps,
                                        lastFiles: last?.copiedFiles, lastBytes: last?.copiedBytes,
                                        filesDone: 0, filesTotal: 0, errorCount: 0, skippedFiles: 0, problemFiles: 0, heldRemovals: 0)
            if let progress {
                drive.filesDone = progress.completedFiles
                drive.filesTotal = progress.totalFiles
                drive.errorCount = progress.errorCount
                drive.skippedFiles = progress.skippedFiles
                drive.problemFiles = progress.problemFiles
                drive.heldRemovals = progress.heldRemovals
            }
            drives.append(drive)
        }
        let busyWithBackup: Bool = model.syncBusy && !model.previewRunning
        let canBackUp: Bool = !model.syncBusy && !model.driveCheckRunning && model.syncSource != nil && !model.backups.isEmpty
        return DigiRemoteStatus(
            macName: macName, appVersion: Self.appVersion,
            session: model.root?.lastPathComponent,
            source: model.syncSource?.lastPathComponent, sourcePath: model.syncSource?.path,
            running: busyWithBackup, paused: snapshot.paused, checkingDrives: model.driveCheckRunning,
            verifying: snapshot.verifying, fraction: snapshot.fraction, mbps: snapshot.mbps, eta: snapshot.eta,
            message: model.syncMessage, nextTitle: next.title, nextDetail: next.detail,
            canBackUp: canBackUp, checking: model.verifyMode,
            scheduleOn: model.scheduleEnabled, scheduleStatus: model.scheduleStatus, nextScheduledRun: model.scheduleNextRun,
            lastBackup: snapshot.lastBackup, drives: drives, updatedAt: Date())
    }

    private static func stateName(_ state: DigiDriveState) -> String {
        switch state {
        case .idle: return "idle"
        case .copying: return "copying"
        case .paused: return "paused"
        case .queued: return "queued"
        case .done: return "done"
        case .problem: return "problem"
        case .disconnected: return "disconnected"
        }
    }
}

// MARK: - Addresses (Wi-Fi / Ethernet and Tailscale)

struct DigiNetworkAddresses: Equatable {
    var lan: [String]
    var tailscale: [String]

    /// IPv4 addresses of this Mac. Tailscale hands out 100.64.0.0/10.
    static func current() -> DigiNetworkAddresses {
        var lan: [String] = []
        var tailscale: [String] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return DigiNetworkAddresses(lan: [], tailscale: []) }
        defer { freeifaddrs(first) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = start
        while let item = pointer {
            defer { pointer = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            let parts = text.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { continue }
            if parts[0] == 169 && parts[1] == 254 { continue }
            if parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127 {
                if !tailscale.contains(text) { tailscale.append(text) }
            } else {
                if !lan.contains(text) { lan.append(text) }
            }
        }
        return DigiNetworkAddresses(lan: lan, tailscale: tailscale)
    }
}

// MARK: - A small HTTP/1.1 server on Network.framework

struct DigiHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    var jsonBody: [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

struct DigiHTTPResponse {
    var status: Int
    var body: Data

    static func json(_ object: [String: Any]) -> DigiHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return DigiHTTPResponse(status: 200, body: data)
    }

    static func encodable<T: Encodable>(_ value: T) -> DigiHTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return DigiHTTPResponse(status: 200, body: data)
    }

    static func error(_ status: Int, _ message: String) -> DigiHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return DigiHTTPResponse(status: status, body: data)
    }

    func encoded() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

final class DigiRemoteServer: @unchecked Sendable {
    var onState: ((String, String?) -> Void)?
    var onRequest: ((DigiHTTPRequest, @escaping (DigiHTTPResponse) -> Void) -> Void)?

    private let port: UInt16
    private let serviceName: String
    private let serviceType: String
    private let queue = DispatchQueue(label: "com.digitools.remote.server")
    private var listener: NWListener?
    private static let maxRequestBytes = 64 * 1024

    init(port: UInt16, serviceName: String, serviceType: String) {
        self.port = port
        self.serviceName = serviceName
        self.serviceType = serviceType
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener = try NWListener(using: parameters, on: endpointPort)
            listener.service = NWListener.Service(name: serviceName, type: serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onState?("On", nil)
                case .failed(let error):
                    let text: String
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        text = "Port \(self.port) is already in use (is another copy of Studio Session running?)."
                    } else {
                        text = error.localizedDescription
                    }
                    self.onState?("Stopped", text)
                    listener.cancel()
                case .cancelled:
                    break
                case .waiting(let error):
                    self.onState?("Waiting for the network", error.localizedDescription)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onState?("Stopped", error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A phone that connects and then says nothing is dropped after 15 s.
        queue.asyncAfter(deadline: .now() + 15) { [weak connection] in
            connection?.cancel()
        }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestBytes {
                self.send(DigiHTTPResponse.error(413, "Request too large"), on: connection)
                return
            }
            if let request = Self.parse(buffer) {
                guard let onRequest = self.onRequest else { connection.cancel(); return }
                onRequest(request) { response in
                    self.queue.async { self.send(response, on: connection) }
                }
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func send(_ response: DigiHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.encoded(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Returns a request once the headers and the whole body have arrived.
    static func parse(_ buffer: Data) -> DigiHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        let available = buffer.count - (bodyStart - buffer.startIndex)
        guard available >= length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        var path = String(requestLine[1])
        if let question = path.firstIndex(of: "?") { path = String(path[path.startIndex..<question]) }
        return DigiHTTPRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body)
    }
}

// MARK: - The iPhone Remote window

struct DigiRemoteView: View {
    @ObservedObject private var remote = DigiRemote.shared
    @State private var confirmRemove: DigiRemoteDevice?
    var onDone: (() -> Void)? = nil

    /// v1.47.8: fixed size, scrolls if needed. 1.47.7 let the panel resize itself to
    /// its content, and that crashed while the sheet slid open (AppKit layout loop).
    static let panelSize = NSSize(width: 540, height: 600)

    var body: some View {
        ScrollView {
            content
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 26))
                    .foregroundStyle(DigiBrand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone Remote").font(.title2.weight(.semibold))
                    Text("See this Mac's backups on your iPhone and start one from there. Optional: leave it off and nothing changes.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let onDone {
                    Button("Done") { onDone() }
                        .keyboardShortcut(.defaultAction)
                }
            }

            HStack {
                Text("Let paired iPhones see backups and start them").font(.headline)
                Spacer()
                Picker("iPhone Remote", selection: Binding(get: { remote.enabled }, set: { remote.setEnabled($0) })) {
                    Text("Off").tag(false)
                    Text("On").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }

            if remote.enabled {
                connectionCard
                pairingCard
                devicesCard
            } else {
                Text("Off. Nothing on this Mac is reachable from the network, and paired iPhones can't see or start backups. Turn it on again any time; paired iPhones keep working without pairing again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !remote.lastEvent.isEmpty {
                Text(remote.lastEvent).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            remote.startIfEnabled()
            remote.refreshAddresses()
        }
        .alert("Remove \(confirmRemove?.name ?? "this iPhone")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Cancel", role: .cancel) { confirmRemove = nil }
            Button("Remove", role: .destructive) {
                if let device = confirmRemove { remote.remove(device) }
                confirmRemove = nil
            }
        } message: {
            Text("It won't be able to see or start backups until you pair it again.")
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(remote.serverState == "On" ? Color.green : Color.orange).frame(width: 9, height: 9)
                Text(remote.serverState == "On" ? "On, port \(DigiRemote.port)" : remote.serverState).font(.headline)
                Spacer()
                Button("Refresh") { remote.refreshAddresses() }
            }
            if let problem = remote.serverProblem {
                Text(problem).foregroundStyle(.orange)
            }
            row("Same Wi-Fi", remote.addresses.lan.isEmpty ? "No Wi-Fi or Ethernet address" : remote.addresses.lan.joined(separator: ", "))
            row("Cellular (Tailscale)", remote.addresses.tailscale.isEmpty
                ? "Not set up. Install Tailscale on this Mac and the iPhone, signed in to the same account."
                : remote.addresses.tailscale.joined(separator: ", "))
            Text("The Mac has to be awake for the iPhone to reach it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let code = remote.pairingCode, let expires = remote.pairingExpires {
                Text("Type this code in Studio Session Remote on the iPhone:").font(.headline)
                Text(code.prefix(3) + " " + code.suffix(3))
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundStyle(DigiBrand.accent)
                    .textSelection(.enabled)
                HStack {
                    Text("Works once, until " + expires.formatted(date: .omitted, time: .shortened) + ".")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { remote.cancelPairing() }
                }
            } else {
                HStack {
                    Text("Pair a new iPhone").font(.headline)
                    Spacer()
                    Button("Pair an iPhone") { remote.newPairingCode() }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired iPhones").font(.headline)
            if remote.devices.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            }
            ForEach(remote.devices) { device in
                HStack {
                    Image(systemName: "iphone")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                        Text(seenText(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove…") { confirmRemove = device }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func seenText(_ device: DigiRemoteDevice) -> String {
        let paired: String = "Paired " + device.added.formatted(date: .abbreviated, time: .shortened)
        if let seen = remote.lastSeen[device.id] {
            return paired + ". Last connected " + seen.formatted(date: .omitted, time: .shortened) + "."
        }
        return paired + ". Not connected since Studio Session opened."
    }
}

/// iPhone Remote's window. v1.47.6: it opens as a sheet on the Studio Session window
/// in front, so it shows up even when that window is full screen (1.47.3-1.47.5 opened a
/// separate window, which macOS put on the desktop Space, out of sight). With no
/// Studio Session window open it falls back to its own window on the current Space.
/// Never restored at launch.
@MainActor enum DigiRemoteWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DigiRemoteView(onDone: { DigiRemoteWindow.close() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let panel = NSWindow(contentViewController: host)
        panel.setContentSize(DigiRemoteView.panelSize)
        panel.title = "iPhone Remote"
        panel.styleMask = [.titled, .closable]
        panel.isRestorable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        if let parent = workspaceWindow() {
            parent.makeKeyAndOrderFront(nil)
            parent.beginSheet(panel) { _ in }
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    static func close() {
        guard let panel = window else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.close()
        }
        window = nil
    }

    /// The Studio Session window to attach to: the one in front, else any open one.
    private static func workspaceWindow() -> NSWindow? {
        func usable(_ w: NSWindow) -> Bool {
            let normal: Bool = w.level == .normal && !(w is NSPanel)
            return w.isVisible && normal && w.canBecomeMain && w.attachedSheet == nil && w.sheetParent == nil
        }
        if let main = NSApp.mainWindow, usable(main) { return main }
        if let key = NSApp.keyWindow, usable(key) { return key }
        return NSApp.orderedWindows.first(where: usable)
    }
}

/// v1.47.6: round iPhone button beside the tour button, bottom right of the main window.
struct DigiRemoteButton: View {
    @ObservedObject private var remote = DigiRemote.shared
    var body: some View {
        let t = DigiBrand.theme
        let tint: Color = remote.enabled ? DigiBrand.accent : t.subtext
        return Button { DigiRemoteWindow.show() } label: {
            Image(systemName: "iphone")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(t.raised, in: Circle())
                .overlay(Circle().strokeBorder(t.line))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .help(remote.enabled ? "iPhone Remote (on)" : "iPhone Remote (off)")
        .accessibilityLabel("iPhone Remote")
        .padding(.vertical, 10)
    }
}
