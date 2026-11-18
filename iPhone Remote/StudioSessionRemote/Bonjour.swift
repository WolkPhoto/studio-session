import Foundation
import Network

/// Finds Macs running Studio Session's iPhone Remote on this Wi-Fi.
@MainActor final class BonjourBrowser: ObservableObject {
    struct Found: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var endpoint: NWEndpoint
        static func == (a: Found, b: Found) -> Bool { a.name == b.name }
    }

    @Published private(set) var found: [Found] = []
    /// True when iOS won't let the app look on this Wi-Fi (Local Network is off for it).
    @Published private(set) var blocked = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_studiosession._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let list: [Found] = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint {
                    return Found(name: name, endpoint: result.endpoint)
                }
                return nil
            }
            Task { @MainActor in
                self.found = list.sorted { $0.name < $1.name }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .ready = state {
                Task { @MainActor in self.blocked = false }
            }
            if case .waiting(let error) = state {
                // iOS reports a refused Local Network permission as a DNS policy error.
                let denied: Bool
                if case .dns(let code) = error, code == -65570 { denied = true } else { denied = false }
                Task { @MainActor in self.blocked = denied }
            }
            if case .failed = state {
                Task { @MainActor in
                    self.browser?.cancel()
                    self.browser = nil
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Turns a Bonjour service into an IPv4 address and port that URLSession can use.
    nonisolated static func resolve(_ endpoint: NWEndpoint) async -> (host: String, port: Int)? {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let once = Once()
            @Sendable func finish(_ value: (String, Int)?) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        var text: String
                        switch host {
                        case .ipv4(let address): text = "\(address)"
                        case .ipv6(let address): text = "\(address)"
                        case .name(let name, _): text = name
                        @unknown default: text = "\(host)"
                        }
                        if let percent = text.firstIndex(of: "%") { text = String(text[text.startIndex..<percent]) }
                        finish((text, Int(port.rawValue)))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }
}

/// Lets the first of several callbacks win.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
