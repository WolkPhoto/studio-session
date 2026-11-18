import Foundation
import SwiftUI
import UIKit
import Combine

/// The paired Mac, how we're reaching it, and its latest status.
@MainActor final class RemoteStore: ObservableObject {
    enum Route: Equatable {
        case none, wifi, tailscale, manual
        var label: String {
            switch self {
            case .none: return "Not connected"
            case .wifi: return "Same Wi-Fi"
            case .tailscale: return "Tailscale"
            case .manual: return "Saved address"
            }
        }
        var icon: String {
            switch self {
            case .none: return "wifi.slash"
            case .wifi: return "wifi"
            case .tailscale: return "antenna.radiowaves.left.and.right"
            case .manual: return "network"
            }
        }
    }

    enum BackupOutcome {
        case started(String)
        case confirm([String])
        case refused(String)
    }

    private static let pairedKey = "remote.pairedMac"
    private static let tokenAccount = "token"

    @Published private(set) var paired: PairedMac? = RemoteStore.loadPaired()
    @Published private(set) var status: RemoteStatus?
    @Published private(set) var route: Route = .none
    @Published private(set) var reachable = false
    @Published private(set) var refreshing = false
    @Published private(set) var lastContact: Date?
    @Published var problem: String?
    @Published var actionRunning = false

    let browser = BonjourBrowser()
    private var pollTask: Task<Void, Never>?
    private var browserWatch: AnyCancellable?

    init() {
        // Views observe the store; pass the Bonjour list's changes through.
        browserWatch = browser.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private var token: String? { Keychain.read(account: Self.tokenAccount) }

    // MARK: Pairing

    func pair(host: String, port: Int, code: String) async throws {
        let digits = code.filter(\.isNumber)
        let result = try await RemoteClient.pair(host: host, port: port, code: digits, deviceName: UIDevice.current.name,
                                                deviceKey: UIDevice.current.identifierForVendor?.uuidString ?? "")
        Keychain.save(result.token, account: Self.tokenAccount)
        let manual: String? = result.lan.contains(host) || result.tailscale.contains(host) ? nil : host
        var mac = PairedMac(macName: result.macName, deviceID: result.deviceID, port: result.port,
                            lan: result.lan, tailscale: result.tailscale, manualHost: manual, lastGoodHost: host)
        if Format.isTailscale(host) && !mac.tailscale.contains(host) { mac.tailscale.append(host) }
        save(mac)
        problem = nil
        await refresh()
        startPolling()
    }

    func forget() {
        stopPolling()
        Keychain.delete(account: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.pairedKey)
        paired = nil
        status = nil
        reachable = false
        route = .none
        problem = nil
    }

    func setManualHost(_ host: String) {
        guard var mac = paired else { return }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        mac.manualHost = trimmed.isEmpty ? nil : trimmed
        save(mac)
        Task { await refresh() }
    }

    private func save(_ mac: PairedMac) {
        paired = mac
        if let data = try? JSONEncoder().encode(mac) { UserDefaults.standard.set(data, forKey: Self.pairedKey) }
    }

    private static func loadPaired() -> PairedMac? {
        guard Keychain.read(account: tokenAccount) != nil,
              let data = UserDefaults.standard.data(forKey: pairedKey) else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    // MARK: Polling

    func startPolling() {
        guard paired != nil else { return }
        browser.start()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let running: Bool = self.status?.running == true || self.status?.checkingDrives == true
                let seconds: Double = self.reachable ? (running ? 1.5 : 4) : 6
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        browser.stop()
    }

    /// Hosts to try, best first: the one that worked last, this Wi-Fi (Bonjour, then the
    /// addresses the Mac gave when pairing), a typed address, then Tailscale.
    private func candidates(_ mac: PairedMac) async -> [String] {
        var list: [String] = []
        func add(_ host: String?) {
            guard let host, !host.isEmpty, !list.contains(host) else { return }
            list.append(host)
        }
        add(mac.lastGoodHost)
        if let found = browser.found.first(where: { $0.name == mac.macName }),
           let resolved = await BonjourBrowser.resolve(found.endpoint) {
            add(resolved.host)
        }
        for host in mac.lan { add(host) }
        add(mac.manualHost)
        for host in mac.tailscale { add(host) }
        return list
    }

    private func route(for host: String, mac: PairedMac) -> Route {
        if Format.isTailscale(host) || host.hasSuffix(".ts.net") { return .tailscale }
        if host == mac.manualHost { return .manual }
        return .wifi
    }

    func refresh() async {
        guard let mac = paired, let token else { return }
        refreshing = true
        defer { refreshing = false }

        // The address that worked last time, on its own first (the usual case).
        if let last = mac.lastGoodHost, await fetch(host: last, mac: mac, token: token) { return }

        let hosts = await candidates(mac).filter { $0 != mac.lastGoodHost }
        guard !hosts.isEmpty else { markUnreachable(); return }
        // Then every other address at once; first answer wins.
        let winner: (String, RemoteStatus)? = await withTaskGroup(of: (String, RemoteStatus)?.self) { group in
            for host in hosts {
                group.addTask {
                    let timeout: TimeInterval = Format.isTailscale(host) ? 8 : 3
                    if let status = try? await RemoteClient.status(host: host, port: mac.port, token: token, timeout: timeout) {
                        return (host, status)
                    }
                    return nil
                }
            }
            for await result in group {
                if let result { group.cancelAll(); return result }
            }
            return nil
        }
        if let (host, status) = winner {
            accept(status, host: host, mac: mac)
        } else {
            // One more pass to tell "unpaired" apart from "unreachable".
            do {
                _ = try await RemoteClient.status(host: hosts[0], port: mac.port, token: token, timeout: 3)
            } catch RemoteClient.ClientError.unpaired(let text) {
                problem = text
            } catch {}
            markUnreachable()
        }
    }

    private func fetch(host: String, mac: PairedMac, token: String) async -> Bool {
        let timeout: TimeInterval = Format.isTailscale(host) ? 8 : 3
        do {
            let status = try await RemoteClient.status(host: host, port: mac.port, token: token, timeout: timeout)
            accept(status, host: host, mac: mac)
            return true
        } catch RemoteClient.ClientError.unpaired(let text) {
            problem = text
            markUnreachable()
            return true
        } catch RemoteClient.ClientError.server(let text) {
            problem = text
            return false
        } catch {
            return false
        }
    }

    private func accept(_ status: RemoteStatus, host: String, mac: PairedMac) {
        self.status = status
        reachable = true
        lastContact = Date()
        route = route(for: host, mac: mac)
        if problem != nil && !actionRunning { problem = nil }
        if mac.lastGoodHost != host || mac.macName != status.macName {
            var updated = mac
            updated.lastGoodHost = host
            updated.macName = status.macName
            save(updated)
        }
    }

    private func markUnreachable() {
        reachable = false
        route = .none
    }

    // MARK: Actions

    private func send(_ path: String, body: [String: Any]? = nil) async throws -> RemoteClient.ActionResult {
        guard let mac = paired, let token, let host = mac.lastGoodHost, reachable else {
            throw RemoteClient.ClientError.unreachable
        }
        return try await RemoteClient.action(host: host, port: mac.port, token: token, path: path, body: body)
    }

    func backUp(force: Bool) async -> BackupOutcome {
        actionRunning = true
        defer { actionRunning = false }
        do {
            let result = try await send("/v1/backup", body: ["force": force])
            await refresh()
            switch result.result {
            case "started":
                return .started(result.message ?? "Backup started.")
            case "confirm":
                return .confirm(result.warnings ?? [])
            default:
                return .refused(result.message ?? "The Mac didn't start the backup.")
            }
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    func control(_ action: String) async -> String? {
        actionRunning = true
        defer { actionRunning = false }
        do {
            let result = try await send("/v1/" + action)
            await refresh()
            return result.message
        } catch {
            return error.localizedDescription
        }
    }
}
