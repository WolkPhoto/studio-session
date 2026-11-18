import Foundation

// Mirrors DigiRemoteStatus / DigiRemoteDrive in the Mac app's DigiRemote.swift.

struct RemoteDrive: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var state: String
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

struct RemoteStatus: Codable, Equatable {
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
    var drives: [RemoteDrive]
    var updatedAt: Date
}

/// What the phone remembers about the Mac it's paired with. The token lives in the Keychain.
struct PairedMac: Codable, Equatable {
    var macName: String
    var deviceID: String
    var port: Int
    var lan: [String]
    var tailscale: [String]
    var manualHost: String?
    var lastGoodHost: String?
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func eta(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 60 { return "under a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        return String(format: "about %dh %02dm left", minutes / 60, minutes % 60)
    }

    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return String(format: "%dm %02ds", minutes, total % 60) }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    static func isTailscale(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
    }
}
