import ServiceManagement
import UserNotifications
import UserNotifications
import SwiftUI
import AppKit
import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ImageIO
import PDFKit

struct SessionStorageCategory: Identifiable {
    let name: String
    let count: Int
    let bytes: Int64
    let formats: [(String, Int, Int64)]
    var id: String { name }
}

struct SessionStorageSummary {
    let categories: [SessionStorageCategory]
    var count: Int { categories.reduce(0) { $0 + $1.count } }
    var bytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    static let empty = SessionStorageSummary(categories: [])

    static func scan(_ root: URL) -> SessionStorageSummary {
        let raw: Set<String> = ["iiq","cr2","cr3","nef","nrw","arw","raf","orf","rw2","dng","3fr","fff","mos","pef","srw","rwl","raw"]
        let otherImages: Set<String> = ["tif","tiff","psd","png","heic","heif","bmp","exr","gif","webp"]
        let videos: Set<String> = ["mov","mp4","m4v","avi","mxf","mts","mpg","mpeg"]
        let session: Set<String> = ["cosessiondb","cocatalogdb","col","costyle","cop","comask","comasks"]
        let fm = FileManager.default
        var stats: [String: [String: (Int, Int64)]] = [:]
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in true }) else { return .empty }
        for case let url as URL in iterator {
            guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]) else { continue }
            if info.isSymbolicLink == true { if info.isDirectory == true { iterator.skipDescendants() }; continue }
            guard info.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let path = url.path.replacingOccurrences(of: "\\", with: "/").lowercased()
            let captureOneData = path.contains("/captureone/") || path.contains("/cache/") || path.contains("/thumbnails/") || path.contains("/proxies/") || path.contains("/settings")
            let category: String
            if ext == "cosessiondb" || ext == "cocatalogdb" { category = "Session Files" }
            else if captureOneData || ["cos","cof","cot","cop","comask","comasks"].contains(ext) { category = "Capture One Data" }
            else if raw.contains(ext) { category = "RAW Images" }
            else if ext == "jpg" || ext == "jpeg" { category = "JPEG Images" }
            else if otherImages.contains(ext) { category = "Other Images" }
            else if videos.contains(ext) { category = "Video" }
            else if session.contains(ext) { category = "Session Files" }
            else { category = "Other Files" }
            let format = ext.isEmpty ? "(no extension)" : ext.uppercased()
            var formats = stats[category] ?? [:]
            let old = formats[format] ?? (0, 0)
            formats[format] = (old.0 + 1, old.1 + Int64(info.fileSize ?? 0))
            stats[category] = formats
        }
        let order = ["RAW Images", "JPEG Images", "Other Images", "Capture One Data", "Session Files", "Video", "Other Files"]
        return SessionStorageSummary(categories: order.compactMap { name in
            guard let formats = stats[name] else { return nil }
            let entries = formats.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.2 > $1.2 }
            return SessionStorageCategory(name: name, count: entries.reduce(0) { $0 + $1.1 }, bytes: entries.reduce(0) { $0 + $1.2 }, formats: entries)
        })
    }
}

struct Asset: Identifiable, Hashable {
    let id: String
    let url: URL
    let size: Int64
    let modified: Date
    var rating: Int? = nil
    var tag: String? = nil
    var metadataSource: String = "Unavailable"
}

struct VariantConflict: Identifiable {
    let id: String
    let filename: String
    let variants: [String]
    let paths: [String]
}

struct UnprocessedFolder: Identifiable {
    let id: String
    let files: [String]
    var count: Int { files.count }
}

struct CheckResult: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let good: Bool
}


struct SyncPreviewDetail: Identifiable, Sendable {
    var id: String { destination }
    let destination: String
    let newFiles: [String]
    let modifiedFiles: [String]
    let removedFiles: [String]
    let unchanged: Int
    let transferBytes: Int64
    let rawNew: Int
    let rawModified: Int
    let rawRemoved: Int
    let error: String?
}



struct ShootWrapProject: Codable {
    var version: Int = 1
    var sessionFolder: String?
    var backupSource: String?
    var backupDestinations: [String]
    var archiveChanged: Bool
    var archiveRemoved: Bool
    var qcCaptureFolder: String?
    var qcExportFolder: String?
    var qcCaptureOverride: Bool? = nil
    var qcExportOverride: Bool? = nil
    var selectedRatings: [Int]
    var selectedTags: [String]
    var matchingRule: String
    var selectsFileType: String
    var outputFormat: String
    var includeExtension: Bool
    var reportName: String
    // Optional for compatibility with projects created by older Shoot Wrap builds.
    var backupFilters: [String: BackupFilter]? = nil
    var lastTab: Int? = nil
    var expectedExtensions: String? = nil
    var minWidth: String? = nil
    var minHeight: String? = nil
    var jobHistory: [String]? = nil
}

@MainActor final class WrapModel: ObservableObject {
    @Published var projectURL: URL?
    @Published var projectStatus = "Unsaved workspace"
    @Published var projectError: String?
    @Published var lastTab = 0
    @Published var savedFingerprint: String? = nil
    var currentProject: ShootWrapProject {
        ShootWrapProject(sessionFolder: root?.path, backupSource: syncSource?.path,
            backupDestinations: backups.map(\.path), archiveChanged: archiveChanged,
            archiveRemoved: archiveRemoved, qcCaptureFolder: qcCaptureFolder?.path,
            qcExportFolder: deliveryFolder?.path, qcCaptureOverride: qcCaptureOverride, qcExportOverride: qcExportOverride, selectedRatings: selectedRatings.sorted(),
            selectedTags: selectedTags.sorted(), matchingRule: matchingRule,
            selectsFileType: selectsFileType, outputFormat: outputFormat,
            includeExtension: includeExtension, reportName: reportName,
            backupFilters: backupFilters, lastTab: lastTab, expectedExtensions: expectedExtensions,
            minWidth: minWidth, minHeight: minHeight, jobHistory: jobHistory)
    }
    var projectFingerprint: String {
        // Stable comparison of persisted workspace settings. Tab navigation alone
        // must not turn a freshly saved workspace back into an unsaved one.
        var project = currentProject
        project.lastTab = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(project) else { return "" }
        return data.base64EncodedString()
    }
    var hasUnsavedChanges: Bool { savedFingerprint != projectFingerprint }
    // Shared default location for both opening and saving Digi Suite workspaces.
    private var defaultWorkspaceDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("DigiSuite", isDirectory: true)
    }
    private func existingWorkspaceDirectory() -> URL {
        let folder = defaultWorkspaceDirectory
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return folder
        }
        return folder.deletingLastPathComponent()
    }
    func saveProject(asNew: Bool = false) {
        guard !syncBusy && !busy else { projectError = "Wait for the active operation to finish before saving."; return }
        var target = asNew ? nil : projectURL
        if target == nil {
            let panel = NSSavePanel()
            panel.title = "Save \(DigiBrand.name) Workspace"
            let projectDirectory = defaultWorkspaceDirectory
            do {
                try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
                panel.directoryURL = projectDirectory
            } catch {
                projectError = "Could not prepare workspace directory: \(error.localizedDescription)"
                return
            }
            panel.nameFieldStringValue = (syncSource ?? root)?.lastPathComponent.appending(".digitools") ?? "Untitled.digitools"
            panel.allowedContentTypes = [UTType(filenameExtension: "digitools") ?? .json, UTType(filenameExtension: "shootwrap") ?? .json]
            guard panel.runModal() == .OK else { return }
            target = panel.url
        }
        guard let target else { return }
        // Save the entire workspace, even if a backup destination has not been chosen yet.
        writeProject(to: target, status: "Saved")
    }
    private func writeProject(to target: URL, status: String) {
        let project = currentProject
        do {
            let data = try JSONEncoder().encode(project)
            try data.write(to: target, options: .atomic)
            projectURL = target
            savedFingerprint = projectFingerprint
            projectStatus = status + ": \(target.lastPathComponent) · \(project.backupDestinations.count) backup destination(s)"
            projectError = nil
        } catch { projectError = "Unable to save workspace: \(error.localizedDescription)" }
    }
    /// Version 18: saves backup-related changes automatically. Uses the open
    /// workspace file; if none, creates ~/Documents/DigiSuite/<session>.digitools
    /// but never overwrites an existing file there.
    func autoSaveWorkspace() {
        guard !syncBusy, !busy, hasUnsavedChanges else { return }
        if let projectURL {
            writeProject(to: projectURL, status: "Auto-saved")
            return
        }
        guard let name = (syncSource ?? root)?.lastPathComponent, !name.isEmpty else { return }
        let folder = defaultWorkspaceDirectory
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return }
        let candidate = folder.appendingPathComponent(name + ".digitools")
        guard !FileManager.default.fileExists(atPath: candidate.path) else { return }
        writeProject(to: candidate, status: "Auto-saved")
    }
    func chooseProject() {
        guard !syncBusy && !busy else { projectError = "Finish the active operation before opening another workspace."; return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.directoryURL = existingWorkspaceDirectory()
        panel.allowedContentTypes = [UTType(filenameExtension: "digitools") ?? .json, UTType(filenameExtension: "shootwrap") ?? .json]
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }
    func openProject(_ url: URL) {
        guard !syncBusy && !busy else { projectError = "Finish the active operation before opening another workspace."; return }
        do {
            let project = try JSONDecoder().decode(ShootWrapProject.self, from: Data(contentsOf: url))
            guard project.version == 1 else { throw NSError(domain: "ShootWrap", code: 10, userInfo: [NSLocalizedDescriptionKey: "Unsupported project version"]) }
            root = project.sessionFolder.map { URL(fileURLWithPath: $0) }
            // Older or incomplete projects may have a Session folder but no separate
            // backup source. Fall back to the Session folder, never to a random drive.
            syncSource = (project.backupSource ?? project.sessionFolder).map { URL(fileURLWithPath: $0) }
            backups = project.backupDestinations.map { URL(fileURLWithPath: $0) }
            backupFilters = project.backupFilters ?? [:]
            archiveChanged = project.archiveChanged; archiveRemoved = project.archiveRemoved
            qcCaptureFolder = project.qcCaptureFolder.map { URL(fileURLWithPath: $0) }
            deliveryFolder = project.qcExportFolder.map { URL(fileURLWithPath: $0) }
            qcCaptureOverride = project.qcCaptureOverride ?? (project.qcCaptureFolder != nil && project.qcCaptureFolder != project.sessionFolder.map { $0 + "/Capture" })
            qcExportOverride = project.qcExportOverride ?? (project.qcExportFolder != nil && project.qcExportFolder != project.sessionFolder.map { $0 + "/Output" })
            configureSessionDefaults()
            selectedRatings = Set(project.selectedRatings); selectedTags = Set(project.selectedTags)
            matchingRule = project.matchingRule; selectsFileType = project.selectsFileType
            outputFormat = project.outputFormat; includeExtension = project.includeExtension
            reportName = project.reportName
            lastTab = min(6, max(0, project.lastTab ?? 0))
            expectedExtensions = project.expectedExtensions ?? "tif,tiff,jpg,jpeg"
            minWidth = project.minWidth ?? ""
            minHeight = project.minHeight ?? ""
            jobHistory = project.jobHistory ?? []
            storageScanID = UUID(); dashboardInventoryRoot = nil; storageSummary = .empty
            assets = []; syncPreview = []; syncPreviewReady = false; syncProgress = []
            qcGroups = []; qcHasRun = false; results = []
            projectURL = url
            savedFingerprint = projectFingerprint
            projectStatus = "Opened: \(url.lastPathComponent) · \(backups.count) backup destination(s)"
            projectError = nil
            let missing = ([root, syncSource, qcCaptureFolder, deliveryFolder].compactMap { $0 } + backups).filter { !FileManager.default.fileExists(atPath: $0.path) }
            if !missing.isEmpty { projectError = "Some saved folders are unavailable. Reconnect the drive or reselect: \(missing.map(\.path).joined(separator: ", "))" }
            if let root, FileManager.default.fileExists(atPath: root.path) {
                scan()
                // Do not probe every mounted removable volume automatically when
                // reopening a workspace. Discovery is an explicit user action.
            }
        } catch { projectError = "Unable to open workspace: \(error.localizedDescription)" }
    }
    @Published var root: URL?
    @Published var assets: [Asset] = []
    @Published var storageSummary: SessionStorageSummary = .empty
    @Published var storageScanning = false
    private var storageScanID = UUID()
    private var dashboardInventoryRoot: URL?
    private var pendingDashboardScan = false
    @Published var backups: [URL] = []
    @Published var backupFilters: [String: BackupFilter] = [:]
    @Published var syncSource: URL?
    @Published var syncProgress: [SyncProgress] = []
    @Published var syncBusy = false
    @Published var scheduleEnabled = UserDefaults.standard.bool(forKey: "DigiSuite.backupSchedule.enabled") {
        didSet { UserDefaults.standard.set(scheduleEnabled, forKey: "DigiSuite.backupSchedule.enabled"); refreshBackupSchedule() }
    }
    @Published var scheduleMinutes = max(1, UserDefaults.standard.integer(forKey: "DigiSuite.backupSchedule.minutes") == 0 ? 10 : UserDefaults.standard.integer(forKey: "DigiSuite.backupSchedule.minutes")) {
        didSet { UserDefaults.standard.set(max(1, min(1440, scheduleMinutes)), forKey: "DigiSuite.backupSchedule.minutes"); refreshBackupSchedule() }
    }
    @Published var scheduleNextRun: Date?
    @Published var backupNotificationsEnabled = UserDefaults.standard.bool(forKey: "DigiSuite.backupNotifications") {
        didSet {
            UserDefaults.standard.set(backupNotificationsEnabled, forKey: "DigiSuite.backupNotifications")
            if backupNotificationsEnabled {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }
    private func notifyBackupResult(_ status: String) {
        guard backupNotificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = status.hasPrefix("Complete") ? "\(DigiBrand.name) backup complete" : "\(DigiBrand.name) backup needs attention"
        content.body = status
        if !status.hasPrefix("Complete") { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    @Published var scheduleLastRun: Date?
    @Published var scheduleLastResults: [String: String] = [:]
    @Published var scheduleStatus = "Automatic backups are off"
    private var scheduleTask: Task<Void, Never>?
    private var scheduleGeneration = 0
    private var scheduleStarted = false
    func startBackupSchedulerIfNeeded() {
        guard !scheduleStarted else { return }
        scheduleStarted = true
        refreshBackupSchedule()
    }
    func refreshBackupSchedule() {
        scheduleGeneration += 1
        scheduleTask?.cancel()
        scheduleTask = nil
        scheduleNextRun = nil
        guard scheduleEnabled else { scheduleStatus = "Automatic backups are off"; return }
        let generation = scheduleGeneration
        scheduleStatus = "Automatic backups armed"
        scheduleNextRun = Date().addingTimeInterval(TimeInterval(scheduleMinutes * 60))
        scheduleTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.scheduleGeneration == generation, self.scheduleEnabled {
                let wait = TimeInterval(max(1, self.scheduleMinutes) * 60)
                do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, self.scheduleGeneration == generation else { return }
                self.scheduleNextRun = Date().addingTimeInterval(wait)
                if self.syncBusy {
                    self.scheduleStatus = "Previous backup still running; next cycle will retry"
                } else {
                    self.startSync(scheduled: true)
                }
            }
        }
    }
    // Shared with the fast-copy engine and its fixture checks.
    nonisolated static func availableBackupDirectory(_ url: URL) -> Bool {
        DigiFastBackupEngine.availableDirectory(url)
    }
    @Published var syncPaused = false
    @Published var syncPreview: [SyncPreviewDetail] = []
    @Published var syncPreviewReady = false
    private var backupControl: BackupControl?
    // Version 16: each destination has its own control, parented to the
    // whole-backup control above. Top-level buttons act on everything.
    private var destinationControls: [String: BackupControl] = [:]
    @Published var pausedDestinations: Set<String> = []
    @Published var stoppingDestinations: Set<String> = []
    @Published var driveStatus: [String: DigiDriveStatus] = [:]
    @Published var driveCheckRunning = false
    private var driveStatusGeneration = 0
    // Version 18: last successful backup per destination, kept across launches.
    @Published var lastBackups: [String: DigiLastBackup] = WrapModel.loadLastBackups()
    @Published var ejectingVolumes: Set<String> = []
    nonisolated static let maxSimultaneousDestinations = 4
    nonisolated static let queuedStatus = "Queued: starts when another drive finishes"
    nonisolated static let lastBackupsKey = "DigiSuite.lastBackups"
    nonisolated static func loadLastBackups() -> [String: DigiLastBackup] {
        guard let data = UserDefaults.standard.data(forKey: lastBackupsKey),
              let decoded = try? JSONDecoder().decode([String: DigiLastBackup].self, from: data) else { return [:] }
        return decoded
    }
    func recordBackup(_ result: SyncProgress) {
        guard result.status == DigiFastBackupEngine.completeStatus else { return }
        let record = DigiLastBackup(date: Date(), seconds: result.elapsedSeconds,
                                    averageMBps: result.bytesPerSecond / 1_000_000,
                                    copiedFiles: result.completedFiles, copiedBytes: result.completedBytes)
        lastBackups[result.destination] = record
        if let data = try? JSONEncoder().encode(lastBackups) {
            UserDefaults.standard.set(data, forKey: Self.lastBackupsKey)
        }
    }
    /// Ejects the external drive holding a destination (all its volumes).
    func ejectDrive(for backup: URL) {
        guard !syncBusy else { return }
        let parts = backup.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else {
            syncMessage = "Only external drives can be ejected."
            return
        }
        let name = parts[2]
        let volume = "/Volumes/" + name
        guard !ejectingVolumes.contains(volume) else { return }
        ejectingVolumes.insert(volume)
        syncMessage = "Ejecting " + name + "…"
        Task.detached(priority: .userInitiated) {
            let outcome = Self.runEject(volume)
            await MainActor.run {
                self.ejectingVolumes.remove(volume)
                if outcome.success {
                    self.syncMessage = name + " ejected. It is safe to unplug."
                } else if !FileManager.default.fileExists(atPath: volume) {
                    // v1.26: it was already unplugged or ejected.
                    self.syncMessage = name + " is already unplugged. Nothing to eject."
                } else {
                    self.syncMessage = "Could not eject " + name + ". " + outcome.message
                }
                self.refreshDriveStatus()
                self.discoverExternalBackupFolders()
            }
        }
    }
    nonisolated static func runEject(_ volume: String) -> (success: Bool, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", volume]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 { return (true, text) }
        return (false, text.isEmpty ? "A file on the drive may still be open." : text)
    }
    func pauseSync() {
        guard syncBusy, !syncPaused, let control = backupControl else { return }
        syncPaused = true
        control.pause()
        syncMessage = "Pausing after the current file…"
    }
    func resumeSync() {
        guard syncBusy, syncPaused || !pausedDestinations.isEmpty, let control = backupControl else { return }
        syncPaused = false
        control.resume()
        // Resume at the top resumes every destination.
        for path in pausedDestinations { destinationControls[path]?.resume() }
        pausedDestinations = []
        syncMessage = "Resuming backup…"
    }
    func stopSync() {
        guard syncBusy, let control = backupControl else { return }
        syncPaused = false
        syncMessage = "Stopping after the current file…"
        control.stop()
    }
    func pauseDestination(_ path: String) {
        guard syncBusy, let control = destinationControls[path], !stoppingDestinations.contains(path) else { return }
        control.pause()
        pausedDestinations.insert(path)
        syncMessage = URL(fileURLWithPath: path).lastPathComponent + ": pausing after the current file…"
    }
    func resumeDestination(_ path: String) {
        guard syncBusy, let control = destinationControls[path] else { return }
        control.resume()
        pausedDestinations.remove(path)
        syncMessage = URL(fileURLWithPath: path).lastPathComponent + ": resuming…"
    }
    func stopDestination(_ path: String) {
        guard syncBusy, let control = destinationControls[path] else { return }
        control.stop()
        pausedDestinations.remove(path)
        stoppingDestinations.insert(path)
        syncMessage = URL(fileURLWithPath: path).lastPathComponent + ": stopping after the current file…"
    }
    /// Drives that are still part of the run: not finished and not queued.
    var runningDestinationPaths: [String] {
        syncProgress.compactMap { item in
            let status = item.status
            let done = status == DigiFastBackupEngine.completeStatus || status.hasPrefix("Stopped") ||
                status.hasPrefix("Error") || status.hasPrefix("Skipped") || status == "Source Unavailable" ||
                status.hasPrefix("Queued")
            return done ? nil : item.destination
        }
    }
    /// Version 18.4: true when everything is paused, whether by Pause All or by
    /// pausing every running drive one at a time.
    var everythingPaused: Bool {
        guard syncBusy else { return false }
        if syncPaused { return true }
        let running = runningDestinationPaths
        return !running.isEmpty && running.allSatisfy { pausedDestinations.contains($0) }
    }
    /// How many running drives are paused individually (for "1 paused").
    var individuallyPausedCount: Int {
        runningDestinationPaths.filter { pausedDestinations.contains($0) }.count
    }
    func togglePauseAll() {
        if everythingPaused { resumeSync() } else { pauseSync() }
    }
    /// True once every drive that is still copying reports "Paused".
    var backupPauseConfirmed: Bool {
        let running = syncProgress.filter { item in
            let status = item.status
            let done = status == DigiFastBackupEngine.completeStatus || status.hasPrefix("Stopped") ||
                status.hasPrefix("Error") || status.hasPrefix("Skipped") || status == "Source Unavailable" ||
                status.hasPrefix("Queued")
            return !done
        }
        return !running.isEmpty && running.allSatisfy { $0.status == "Paused" }
    }
    func destinationIsPaused(_ path: String) -> Bool {
        syncBusy && (syncPaused || pausedDestinations.contains(path)) && !stoppingDestinations.contains(path)
    }
    /// Reads link speed, free space and format for every destination.
    func refreshDriveStatus() {
        let destinations = backups
        guard !destinations.isEmpty else { driveStatus = [:]; return }
        driveStatusGeneration += 1
        let generation = driveStatusGeneration
        Task.detached(priority: .utility) {
            let statuses = DigiDriveCheck.inspectAll(destinations)
            await MainActor.run {
                guard generation == self.driveStatusGeneration else { return }
                self.driveStatus = Dictionary(statuses.map { ($0.destinationPath, $0) }, uniquingKeysWith: { _, new in new })
            }
        }
    }
    /// Manual backups check each drive's connection first. A link below
    /// 10 Gb/s asks before copying; scheduled backups never wait on a prompt.
    func requestStartSync() {
        guard !driveCheckRunning else { return }
        // Let startSync report its usual message when a backup cannot start.
        guard !syncBusy, syncSource != nil, !backups.isEmpty else { startSync(); return }
        let destinations = backups
        driveCheckRunning = true
        syncMessage = "Checking drive connections…"
        Task.detached(priority: .userInitiated) {
            let statuses = DigiDriveCheck.inspectAll(destinations)
            await MainActor.run {
                self.driveCheckRunning = false
                self.driveStatusGeneration += 1
                self.driveStatus = Dictionary(statuses.map { ($0.destinationPath, $0) }, uniquingKeysWith: { _, new in new })
                let slow = statuses.filter { $0.linkWarning != nil }
                // v1.8: warn before backing up to drives that aren't APFS.
                let formatIssues = statuses.filter { Self.formatAdvice(for: $0) != nil }
                guard !slow.isEmpty || !formatIssues.isEmpty else { self.startSync(); return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                if slow.isEmpty {
                    alert.messageText = formatIssues.count == 1 ? "This backup drive isn't formatted as APFS" : "Some backup drives aren't formatted as APFS"
                } else {
                    alert.messageText = slow.count == 1 ? "A backup drive is connected at reduced speed" : "Some backup drives are connected at reduced speed"
                }
                var lines: [String] = []
                for status in slow {
                    let name: String = URL(fileURLWithPath: status.volumePath ?? status.destinationPath).lastPathComponent
                    let warning: String = status.linkWarning ?? ""
                    lines.append(name + ": " + warning)
                }
                for status in formatIssues {
                    let name: String = URL(fileURLWithPath: status.volumePath ?? status.destinationPath).lastPathComponent
                    let advice: String = Self.formatAdvice(for: status) ?? ""
                    lines.append(name + ": " + advice)
                }
                alert.informativeText = lines.joined(separator: "\n\n")
                alert.addButton(withTitle: "Back Up Anyway")
                alert.addButton(withTitle: "Cancel")
                if !formatIssues.isEmpty {
                    alert.showsSuppressionButton = true
                    alert.suppressionButton?.title = formatIssues.count == 1 ? "Don't warn me about this drive's format again" : "Don't warn me about these drives' formats again"
                }
                let answer = alert.runModal()
                if alert.suppressionButton?.state == .on {
                    for status in formatIssues { Self.skipFormatWarning(for: status) }
                }
                if answer == .alertFirstButtonReturn {
                    self.startSync()
                } else {
                    self.syncMessage = slow.isEmpty ? "Backup not started." : "Backup not started. Reconnect the drive, then start the backup again."
                }
            }
        }
    }
    // MARK: Sounds (v1.11)

    nonisolated static let soundsKey = "DigiSuite.sounds"

    /// A chime when every drive is up to date, an alert when anything went wrong,
    /// nothing when the person stopped the backup themselves.
    static func playOutcomeSound(_ outcomes: [String: String]) {
        let enabled = UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? DigiBrand.soundsDefault
        guard enabled, !outcomes.isEmpty else { return }
        let statuses = Array(outcomes.values)
        if statuses.allSatisfy({ $0.hasPrefix("Stopped") }) { return }
        let allGood = statuses.allSatisfy { $0 == DigiFastBackupEngine.completeStatus || $0.hasPrefix("Stopped") }
        NSSound(named: allGood ? "Glass" : "Basso")?.play()
    }

    // MARK: Drive format advice (v1.8)

    nonisolated static let formatWarningSkippedKey = "DigiSuite.formatWarningSkipped"

    private static func volumeName(_ status: DigiDriveStatus) -> String {
        URL(fileURLWithPath: status.volumePath ?? status.destinationPath).lastPathComponent
    }

    /// Plain-language advice for a drive that isn't APFS, or nil when it's fine
    /// (APFS, unknown format, or the person asked not to be warned about it).
    static func formatAdvice(for status: DigiDriveStatus) -> String? {
        guard let format = status.formatName, !format.isEmpty else { return nil }
        let lower = format.lowercased()
        if lower.contains("apfs") { return nil }
        let skipped = UserDefaults.standard.stringArray(forKey: formatWarningSkippedKey) ?? []
        if skipped.contains(volumeName(status)) { return nil }
        let app = DigiBrand.name
        if lower.contains("mac os extended") || lower.contains("hfs") {
            return "Formatted as \(format). Backups work, but this kind of drive slows down over time because macOS can't tell the SSD which space is free. \(app) is optimized for APFS drives; erasing this drive as APFS in Disk Utility (after copying off anything you need) keeps it fast."
        }
        if lower.contains("fat") || lower.contains("ms-dos") {
            return "Formatted as \(format). Backups are slower and less reliable on this format, and FAT32 can't hold a single file over 4 GB. \(app) is optimized for APFS drives; erasing this drive as APFS in Disk Utility (after copying off anything you need) is recommended."
        }
        return "Formatted as \(format). \(app) is optimized for APFS drives and hasn't been tested on this format."
    }

    static func skipFormatWarning(for status: DigiDriveStatus) {
        var skipped = UserDefaults.standard.stringArray(forKey: formatWarningSkippedKey) ?? []
        let name = volumeName(status)
        if !skipped.contains(name) { skipped.append(name) }
        UserDefaults.standard.set(skipped, forKey: formatWarningSkippedKey)
    }

    @Published var archiveChanged = true
    // v1.25: checksum every copy (read back from the drive) and go easy while Capture One is open.
    nonisolated static let verifyCopiesKey = "DigiSuite.verifyCopies"
    nonisolated static let gentleKey = "DigiSuite.gentleWhileCapture"
    nonisolated static let archiveTrimKey = "DigiSuite.archiveAutoTrim"
    nonisolated static let archiveTrimGBKey = "DigiSuite.archiveAutoTrimGB"
    @Published var archiveAutoTrim: Bool = UserDefaults.standard.bool(forKey: "DigiSuite.archiveAutoTrim") {
        didSet { UserDefaults.standard.set(archiveAutoTrim, forKey: Self.archiveTrimKey) }
    }
    @Published var archiveAutoTrimGB: Int = UserDefaults.standard.object(forKey: "DigiSuite.archiveAutoTrimGB") as? Int ?? 100 {
        didSet { UserDefaults.standard.set(archiveAutoTrimGB, forKey: Self.archiveTrimGBKey) }
    }
    /// v1.25: archive size per backup folder (path -> info), measured off the main thread.
    @Published var archiveInfo: [String: DigiArchive.Info] = [:]
    @Published var archiveMeasuring: Set<String> = []

    func refreshArchiveInfo() {
        for destination in backups {
            let path = destination.path
            guard !archiveMeasuring.contains(path), Self.availableBackupDirectory(destination) else { continue }
            archiveMeasuring.insert(path)
            Task.detached(priority: .utility) {
                let info = DigiArchive.measure(destination)
                await MainActor.run {
                    self.archiveInfo[path] = info
                    self.archiveMeasuring.remove(path)
                }
            }
        }
    }

    /// Asks first (Cancel is the default button), then deletes the whole archive on that drive.
    func confirmClearArchive(_ destination: URL) {
        let info = archiveInfo[destination.path] ?? DigiArchive.Info()
        let size = ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permanently delete the archive on " + destination.lastPathComponent + "?"
        alert.informativeText = "This deletes " + size + " of older versions and removed files saved by \(info.runs) earlier backup(s). Your current backup and the session are not touched.\n\nThis can't be undone."
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete Archive")
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        archiveMeasuring.insert(destination.path)
        Task.detached(priority: .userInitiated) {
            var problem: String?
            do { try DigiArchive.clearAll(destination) } catch { problem = error.localizedDescription }
            let failure = problem
            await MainActor.run {
                self.archiveMeasuring.remove(destination.path)
                if let failure {
                    let notice = NSAlert()
                    notice.messageText = "Couldn't clear the whole archive"
                    notice.informativeText = failure
                    notice.runModal()
                }
                self.refreshArchiveInfo()
                self.refreshDriveStatus()
            }
        }
    }
    /// v1.26: "full" (read every copy back), "quick" (checksum originals only) or "off".
    nonisolated static let verifyModeKey = "DigiSuite.verifyMode"
    nonisolated static func storedVerifyMode() -> String {
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: verifyModeKey), ["full", "quick", "off"].contains(mode) { return mode }
        // 1.25 had a single on/off switch.
        if let old = defaults.object(forKey: verifyCopiesKey) as? Bool, old == false { return "off" }
        return "full"
    }
    @Published var verifyMode: String = WrapModel.storedVerifyMode() {
        didSet { UserDefaults.standard.set(verifyMode, forKey: Self.verifyModeKey) }
    }
    var verifyModeTitle: String {
        switch verifyMode {
        case "quick": return "Checksums: Quick"
        case "off": return "Checksums: Off"
        default: return "Checksums: Full verify"
        }
    }
    @Published var gentleWhileCapture: Bool = UserDefaults.standard.object(forKey: "DigiSuite.gentleWhileCapture") as? Bool ?? true {
        didSet { UserDefaults.standard.set(gentleWhileCapture, forKey: Self.gentleKey) }
    }
    @Published var archiveRemoved = true
    @Published var syncMessage = "Choose a source folder and one or more destinations"

    @Published var results: [CheckResult] = []
    @Published var selectedRatings: Set<Int> = []
    @Published var selectedTags: Set<String> = []
    @Published var matchingRule = "OR"
    @Published var outputFormat = ""
    @Published var includeExtension = true
    @Published var selectsFileType = "RAW" // RAW, JPEG, or Both
    @Published var unmatchedVariants = 0
    @Published var ambiguousFiles = 0
    @Published var variantConflicts: [VariantConflict] = []
    @Published var busy = false
    private var captureProcess: Process?
    func cancelCaptureScan() {
        captureProcess?.terminate()
        captureProcess = nil
        busy = false
        progress = "Capture One scan cancelled"
    }
    @Published var progress = "Open a session or choose a folder"
    @Published var reportName = "DigiTools"
    @Published var qcCaptureFolder: URL?
    @Published var deliveryFolder: URL?
    @Published var qcCaptureOverride = false
    @Published var qcExportOverride = false
    @Published var qcGroups: [UnprocessedFolder] = []
    @Published var qcRawCount = 0
    @Published var qcMatchedCount = 0
    @Published var qcJPEGCount = 0
    @Published var qcHasRun = false
    @Published var expectedExtensions = "tif,tiff,jpg,jpeg"
    @Published var minWidth = ""
    @Published var minHeight = ""
    @Published var jobHistory: [String] = UserDefaults.standard.stringArray(forKey: "wrapHistory") ?? []
    let tags = ["Red","Orange","Yellow","Green","Blue","Purple","Pink","None"]
    let rawExtensions: Set<String> = ["iiq","cr2","cr3","nef","nrw","arw","raf","orf","rw2","dng","3fr","fff","mos","pef","srw","rwl","raw"]
    let ignoredFolders: Set<String> = ["CaptureOne","Cache","Thumbnails","Proxies","Settings","Settings100","Settings110","Settings120","Settings130","Settings140","Settings150","Settings160",".Spotlight-V100",".Trashes"]
    var totalBytes: Int64 { assets.reduce(0) { $0 + $1.size } }
    var rawCount: Int { assets.filter { rawExtensions.contains($0.url.pathExtension.lowercased()) }.count }
    var taggedCount: Int { assets.filter { $0.rating != nil || $0.tag != nil }.count }
    var selects: [Asset] {
        let candidates = assets.filter { asset in
            let ext = asset.url.pathExtension.lowercased()
            switch selectsFileType {
            case "RAW": return rawExtensions.contains(ext)
            case "JPEG": return ext == "jpg" || ext == "jpeg"
            default: return rawExtensions.contains(ext) || ext == "jpg" || ext == "jpeg"
            }
        }
        return candidates.filter { asset in
            let ratingActive = !selectedRatings.isEmpty
            let tagActive = !selectedTags.isEmpty
            let r = asset.rating.map { selectedRatings.contains($0) } ?? false
            let t = selectedTags.contains(asset.tag ?? "None")
            if !ratingActive && !tagActive { return true }
            if !ratingActive { return t }
            if !tagActive { return r }
            return matchingRule == "AND" ? (r && t) : (r || t)
        }
    }
    func chooseRoot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { root = url; reportName = url.lastPathComponent; qcCaptureOverride = false; qcExportOverride = false; qcCaptureFolder = nil; deliveryFolder = nil; configureSessionDefaults(); scan(); discoverExternalBackupFolders() }
    }
    struct DiscoveredBackupDrive: Identifiable {
        let volume: URL
        let matchingFolder: URL?
        let suggestedFolder: URL
        var id: String { volume.path }
    }
    @Published var discoveredBackupMessage = "Choose Discover Drives to find backup destinations."
    @Published var discoveredBackupScanning = false
    @Published var discoveredBackupDrives: [DiscoveredBackupDrive] = []

    /// v1.26: backup folders are named after what's being backed up (the backup
    /// source), which can differ from the session open on Home.
    var backupSourceForNaming: URL? { syncSource ?? root }

    func discoverExternalBackupFolders() {
        guard let session = backupSourceForNaming else {
            discoveredBackupMessage = "Open a session before discovering drives."
            return
        }
        let sessionName = session.lastPathComponent
        guard !sessionName.isEmpty, !discoveredBackupScanning else { return }
        discoveredBackupScanning = true
        discoveredBackupMessage = "Looking for matching session folders on mounted drives…"
        let sessionPath = session.resolvingSymlinksInPath().standardizedFileURL.path
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            // macOS mounts most external USB, Thunderbolt, and network drives in /Volumes.
            // Do not require volumeIsRemovable: many external SSDs report false.
            let volumes = (fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey],
                options: [.skipHiddenVolumes]) ?? []).filter {
                    $0.standardizedFileURL.path.hasPrefix("/Volumes/")
                }
            var results: [DiscoveredBackupDrive] = []
            for volume in volumes.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: volume.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let resolvedVolume = volume.resolvingSymlinksInPath().standardizedFileURL.path
                // Skip root, internal Data volume, and the volume holding the active source.
                guard resolvedVolume != "/", resolvedVolume != "/System/Volumes/Data",
                      !sessionPath.hasPrefix(resolvedVolume + "/") else { continue }
                var match: URL?
                let direct = volume.appendingPathComponent(sessionName, isDirectory: true)
                if fm.fileExists(atPath: direct.path, isDirectory: &isDir), isDir.boolValue { match = direct }
                if match == nil {
                    // Check one container directory deep without scanning all image files.
                    let children = (try? fm.contentsOfDirectory(at: volume, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                    for child in children where child.lastPathComponent != sessionName {
                        guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                        let candidate = child.appendingPathComponent(sessionName, isDirectory: true)
                        if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                            match = candidate
                            break
                        }
                    }
                }
                results.append(DiscoveredBackupDrive(volume: volume, matchingFolder: match, suggestedFolder: direct))
            }
            DispatchQueue.main.async {
                guard self.backupSourceForNaming?.resolvingSymlinksInPath().standardizedFileURL.path == sessionPath else {
                    self.discoveredBackupScanning = false
                    return
                }
                self.discoveredBackupDrives = results
                self.discoveredBackupScanning = false
                self.discoveredBackupMessage = results.isEmpty
                    ? "No other mounted drives found. Connect a drive and scan again."
                    : "Found \(results.count) drive(s). Review each destination below."
            }
        }
    }

    func addDiscoveredBackupDestination(_ folder: URL) {
        guard let session = root else { return }
        let candidate = folder.standardizedFileURL
        let sourcePath = (syncSource ?? session).resolvingSymlinksInPath().standardizedFileURL.path
        let targetPath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard targetPath != sourcePath,
              !targetPath.hasPrefix(sourcePath + "/"),
              !sourcePath.hasPrefix(targetPath + "/") else {
            discoveredBackupMessage = "Cannot use the source folder or its parent/child as a destination."
            return
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return }
        // v1.6: offer to fix drive permissions instead of failing later.
        guard DigiDrivePermissions.ensureWritable(candidate) else {
            discoveredBackupMessage = "\(candidate.lastPathComponent) can't be written to, so it wasn't added."
            return
        }
        if !backups.contains(where: { $0.standardizedFileURL == candidate }) {
            backups.append(candidate)
            syncPreviewReady = false
        }
        discoveredBackupMessage = "Added \(candidate.lastPathComponent) as a backup destination."
        if syncBusy { joinRunningBackup(candidate) }
    }

    func createDiscoveredBackupFolder(on volume: URL) {
        guard let session = backupSourceForNaming else { return }
        let target = volume.appendingPathComponent(session.lastPathComponent, isDirectory: true)
        let alert = NSAlert()
        alert.messageText = "Create backup folder?"
        alert.informativeText = "Create \(target.path) and add it as a backup destination? No files will be copied until a backup runs."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create and Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // v1.6: a drive set up on another Mac may block new folders; offer the fix first.
        guard DigiDrivePermissions.ensureWritable(volume) else {
            discoveredBackupMessage = "\(volume.lastPathComponent) can't be written to. No folder was created."
            return
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            addDiscoveredBackupDestination(target)
            discoverExternalBackupFolders()
        } catch {
            discoveredBackupMessage = "Could not create folder: \(error.localizedDescription)"
            let errorAlert = NSAlert()
            errorAlert.messageText = "Could not create backup folder"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.runModal()
        }
    }

    func addBackup() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a backup destination. Use New Folder to create a destination folder here."
        panel.prompt = "Add Destination"
        if panel.runModal() == .OK, let url = panel.url, !backups.contains(url) {
            // v1.6: offer to fix drive permissions before adding the folder.
            guard DigiDrivePermissions.ensureWritable(url) else { return }
            backups.append(url)
            syncPreviewReady = false
            if syncBusy { joinRunningBackup(url) }
        }
    }
    func chooseSyncSource() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            syncSource = url; syncProgress = []; syncPreviewReady = false
            // v1.26: folder suggestions on connected drives follow the new source's name.
            discoverExternalBackupFolders()
        }
    }
    nonisolated static func syncInventory(_ root: URL, filter: BackupFilter = BackupFilter()) throws -> [(String, URL, Int64)] {
        let fm = FileManager.default
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in false }) else { throw NSError(domain: "ShootWrap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to scan source folder"]) }
        var files: [(String, URL, Int64)] = []
        for case let url as URL in iterator {
            if DigiFastBackupEngine.toolFolderNames.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            if !filter.includes(relativePath) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { iterator.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files.append((relative, url, Int64(values.fileSize ?? 0)))
        }
        return files.sorted { $0.0 < $1.0 }
    }
    typealias SyncSourceSnapshot = DigiSyncSourceSnapshot
    nonisolated static func syncSnapshot(_ root: URL, filter: BackupFilter, control: BackupControl? = nil) throws -> SyncSourceSnapshot {
        try DigiFastBackupEngine.snapshot(root, filter: filter, control: control)
    }
    nonisolated static func syncDirectoryInventory(_ root: URL, filter: BackupFilter) throws -> [String] {
        try syncSnapshot(root, filter: filter).directories
    }
    nonisolated static func backupPlan(source: URL, destination: URL, filter: BackupFilter = BackupFilter(), snapshot: SyncSourceSnapshot? = nil) throws -> (changes: [BackupEntry], unchanged: Int, removed: [String], manifest: SyncRecord) {
        try DigiFastBackupEngine.plan(source: source, destination: destination, filter: filter, snapshot: snapshot)
    }
    nonisolated static func syncFolder(source: URL, destination: URL, archiveChanged: Bool, archiveRemoved: Bool, filter: BackupFilter, snapshot: SyncSourceSnapshot? = nil, control: BackupControl, report: @escaping @Sendable (SyncProgress) async -> Void) async -> SyncProgress {
        // v21: one app at a time per backup folder (see DigiDestinationLock).
        let lock = DigiDestinationLock.acquire(destination)
        if case .busy = lock {
            var skipped = SyncProgress(destination: destination.path)
            skipped.status = DigiDestinationLock.busyStatus
            await report(skipped)
            return skipped
        }
        // v1.25: checksums on by default; backups step aside while Capture One is open.
        let defaults = UserDefaults.standard
        let mode: String = WrapModel.storedVerifyMode()
        let verify: Bool = mode != "off"
        let readBack: Bool = mode == "full"
        let gentle: Bool = defaults.object(forKey: WrapModel.gentleKey) as? Bool ?? true
        let gate: DigiCaptureGate? = gentle ? DigiCaptureGate(probe: { CaptureOneTarget.running() != nil }) : nil
        // v1.25: optional clean-up of the oldest archived copies when the drive runs low,
        // before the backup (to make room) and after it (what it archived counts too).
        let trimOn: Bool = defaults.bool(forKey: WrapModel.archiveTrimKey)
        let trimGB: Int = defaults.object(forKey: WrapModel.archiveTrimGBKey) as? Int ?? 100
        let keepFree: Int64 = Int64(max(1, trimGB)) * 1_000_000_000
        var trimmedRuns = 0
        var trimmedBytes: Int64 = 0
        func trim() {
            guard trimOn, let found = try? DigiArchive.trimOldest(destination, keepFree: keepFree) else { return }
            trimmedRuns += found.runs
            trimmedBytes += found.bytes
        }
        trim()
        var result = await DigiStreamEngine.sync(source: source, destination: destination, archiveChanged: archiveChanged,
            archiveRemoved: archiveRemoved, filter: filter, snapshot: snapshot, control: control,
            verify: verify, readBack: readBack, gate: gate, report: report)
        trim()
        if trimmedRuns > 0 {
            let freed = ByteCountFormatter.string(fromByteCount: trimmedBytes, countStyle: .file)
            result.archiveNote = "Cleared the oldest archived copies from \(trimmedRuns) earlier backup(s), freeing " + freed + "."
            await report(result)
        }
        withExtendedLifetime(lock) {}
        return result
    }

    func previewSync() {
        guard !DigiBackupBenchmark.shared.isRunning else {
            syncMessage = "Wait for the speed benchmark to finish before starting a trial sync."
            return
        }
        guard let source = syncSource, !backups.isEmpty, !syncBusy else { return }
        let destinations = backups
        let filters = backupFilters
        syncBusy = true
        syncPreviewReady = false
        syncPreview = []
        syncMessage = "Preparing trial sync…"
        Task.detached {
            var details: [SyncPreviewDetail] = []
            let rawTypes: Set<String> = ["iiq","cr2","cr3","nef","nrw","arw","raf","orf","rw2","dng","3fr","fff","mos","pef","srw","rwl","raw"]
            for dest in destinations {
                do {
                    let plan = try Self.backupPlan(source: source, destination: dest, filter: filters[dest.path] ?? BackupFilter())
                    let fm = FileManager.default
                    let added = plan.changes.filter { !fm.fileExists(atPath: $0.destination.path) }.map(\.relative).sorted()
                    let modified = plan.changes.filter { fm.fileExists(atPath: $0.destination.path) }.map(\.relative).sorted()
                    let removed = plan.removed
                    let bytes = plan.changes.reduce(Int64(0)) { $0 + $1.size }
                    func rawCount(_ files: [String]) -> Int {
                        files.filter { rawTypes.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.count
                    }
                    details.append(SyncPreviewDetail(destination: dest.path, newFiles: added, modifiedFiles: modified, removedFiles: removed, unchanged: plan.unchanged, transferBytes: bytes, rawNew: rawCount(added), rawModified: rawCount(modified), rawRemoved: rawCount(removed), error: nil))
                } catch {
                    details.append(SyncPreviewDetail(destination: dest.path, newFiles: [], modifiedFiles: [], removedFiles: [], unchanged: 0, transferBytes: 0, rawNew: 0, rawModified: 0, rawRemoved: 0, error: error.localizedDescription))
                }
            }
            let previewDetails = details
            await MainActor.run {
                self.syncPreview = previewDetails
                self.syncPreviewReady = true
                self.syncBusy = false
                self.syncMessage = "Preview complete. No destination files were modified."
            }
        }
    }
    func startSync(scheduled: Bool = false) {
        guard !DigiBackupBenchmark.shared.isRunning else {
            if scheduled { scheduleStatus = "Speed benchmark running; next scheduled cycle will retry" }
            else { syncMessage = "Wait for the speed benchmark to finish before starting a backup." }
            return
        }
        guard !syncBusy else { return }
        guard let source = syncSource, !backups.isEmpty else {
            if scheduled { scheduleStatus = "Skipped: source or destinations not configured"; scheduleLastRun = Date() }
            return
        }
        guard Self.availableBackupDirectory(source) else {
            syncMessage = "Source unavailable. No destinations were written."
            if scheduled { scheduleStatus = "Source Unavailable"; scheduleLastRun = Date() }
            return
        }
        let destinations = backups
        let filters = backupFilters
        let changed = archiveChanged, removed = archiveRemoved
        let control = BackupControl()
        backupControl = control
        let childControls = Dictionary(destinations.map { ($0.path, BackupControl(parent: control)) }, uniquingKeysWith: { first, _ in first })
        destinationControls = childControls
        pausedDestinations = []
        stoppingDestinations = []
        if scheduled { refreshDriveStatus() }
        runningBackupJobs = 1
        backupOutcomes = [:]
        syncBusy = true
        syncPaused = false
        syncMessage = "Backing up to \(destinations.count) destination(s)"
        if scheduled { scheduleStatus = "Scheduled backup running" }
        // Version 18.1: up to four drives copy at once; more wait their turn.
        let simultaneous = Self.maxSimultaneousDestinations
        syncProgress = destinations.enumerated().map { index, destination in
            var item = SyncProgress(destination: destination.path)
            item.status = index < simultaneous ? "Starting…" : Self.queuedStatus
            return item
        }
        Task.detached(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Copying \(DigiBrand.name) backups")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            // Scan the source once for each distinct filter configuration, then share
            // immutable snapshots across both destination workers. Destination-specific
            // metadata checks, native copies and archives remain independent.
            var cachedScans: [(BackupFilter, SyncSourceSnapshot)] = []
            var snapshots: [SyncSourceSnapshot?] = []
            for destination in destinations {
                let filter = filters[destination.path] ?? BackupFilter()
                if let match = cachedScans.first(where: { $0.0 == filter }) {
                    snapshots.append(match.1)
                } else {
                    let scanned = try? Self.syncSnapshot(source, filter: filter, control: control)
                    snapshots.append(scanned)
                    if let scanned { cachedScans.append((filter, scanned)) }
                }
            }
            let preparedSnapshots = snapshots
            // Two destinations run independently. A shared control coordinates global
            // pause/resume/stop; each worker owns its own manifest and temp files.
            var outcomes: [String: String] = [:]
            await withTaskGroup(of: (String, String).self) { group in
                var nextIndex = 0
                func enqueueNext() {
                    guard nextIndex < destinations.count else { return }
                    let destination = destinations[nextIndex]
                    let snapshot = preparedSnapshots[nextIndex]
                    nextIndex += 1
                    let destinationControl = childControls[destination.path] ?? control
                    group.addTask {
                        do { try await destinationControl.checkpoint() }
                        catch {
                            await MainActor.run {
                                if let index = self.syncProgress.firstIndex(where: { $0.destination == destination.path }) {
                                    self.syncProgress[index].status = "Stopped safely. Completed files retained."
                                }
                            }
                            return (destination.path, "Stopped safely. Completed files retained.")
                        }
                        guard Self.availableBackupDirectory(source) else {
                            await MainActor.run {
                                if let index = self.syncProgress.firstIndex(where: { $0.destination == destination.path }) {
                                    self.syncProgress[index].status = "Source Unavailable"
                                }
                            }
                            return (destination.path, "Source Unavailable")
                        }
                        guard Self.availableBackupDirectory(destination) else {
                            await MainActor.run {
                                if let index = self.syncProgress.firstIndex(where: { $0.destination == destination.path }) {
                                    self.syncProgress[index].status = "Skipped: Destination Unavailable"
                                }
                            }
                            return (destination.path, "Skipped: Destination Unavailable")
                        }
                        let result = await Self.syncFolder(
                            source: source, destination: destination,
                            archiveChanged: changed, archiveRemoved: removed,
                            filter: filters[destination.path] ?? BackupFilter(), snapshot: snapshot, control: destinationControl
                        ) { update in
                            await MainActor.run {
                                if let index = self.syncProgress.firstIndex(where: { $0.destination == update.destination }) {
                                    self.syncProgress[index] = update
                                }
                            }
                        }
                        await MainActor.run { self.recordBackup(result) }
                        return (destination.path, result.status)
                    }
                }
                // Each drive copies independently; beyond the limit, drives queue.
                for _ in 0..<min(simultaneous, destinations.count) { enqueueNext() }
                while let (path, status) = await group.next() {
                    outcomes[path] = status
                    // Stopping the whole backup launches nothing further. Stopping a
                    // single destination lets the queued destinations continue.
                    if !control.isStopped { enqueueNext() }
                }
            }
            // Snapshot mutable worker results before crossing the actor boundary.
            let completedOutcomes = outcomes
            await MainActor.run {
                for (path, status) in completedOutcomes { self.backupOutcomes[path] = status }
                self.runningBackupJobs -= 1
                self.finishBackupIfIdle()
            }
        }
    }
    // Version 18.2: drives added during a backup run as extra jobs; the backup
    // finishes when the main job and every added drive are done.
    private var runningBackupJobs = 0
    private var backupOutcomes: [String: String] = [:]
    private func finishBackupIfIdle() {
        guard runningBackupJobs <= 0, syncBusy else { return }
        runningBackupJobs = 0
        let completedOutcomes = backupOutcomes
        backupOutcomes = [:]
        syncBusy = false
        syncPaused = false
        backupControl = nil
        destinationControls = [:]
        pausedDestinations = []
        stoppingDestinations = []
        syncPreviewReady = false
        scheduleLastRun = Date()
        scheduleLastResults = completedOutcomes
        let successful = completedOutcomes.values.filter { $0 == "Up to date" }.count
        let unavailable = completedOutcomes.values.filter { $0.contains("Unavailable") }.count
        let stopped = completedOutcomes.values.filter { $0.hasPrefix("Stopped") }.count
        let failures = completedOutcomes.count - successful - unavailable - stopped
        var parts = ["\(successful) up to date"]
        if stopped > 0 { parts.append("\(stopped) stopped") }
        if unavailable > 0 { parts.append("\(unavailable) unavailable") }
        if failures > 0 { parts.append("\(failures) failed") }
        scheduleStatus = successful == completedOutcomes.count ? "Complete: all \(successful) destinations up to date" : "Partial: " + parts.joined(separator: ", ")
        // Free space changed; refresh the destination cards.
        refreshDriveStatus()
        refreshArchiveInfo()
        autoSaveWorkspace()
        syncMessage = "Backup finished. \(scheduleStatus)"
        notifyBackupResult(scheduleStatus)
        Self.playOutcomeSound(completedOutcomes)
    }
    /// Starts one more drive inside the running backup.
    func joinRunningBackup(_ destination: URL) {
        guard syncBusy, let parent = backupControl, !parent.isStopped, let source = syncSource else { return }
        if let existing = syncProgress.firstIndex(where: { $0.destination == destination.path }) {
            let status = syncProgress[existing].status
            let finished = status == DigiFastBackupEngine.completeStatus || status.hasPrefix("Stopped") ||
                status.hasPrefix("Error") || status.hasPrefix("Skipped") || status == "Source Unavailable"
            guard finished else { return }
            syncProgress.remove(at: existing)
        }
        let control = BackupControl(parent: parent)
        destinationControls[destination.path] = control
        stoppingDestinations.remove(destination.path)
        pausedDestinations.remove(destination.path)
        var item = SyncProgress(destination: destination.path)
        item.status = "Starting…"
        syncProgress.append(item)
        runningBackupJobs += 1
        let filter = backupFilters[destination.path] ?? BackupFilter()
        let changed = archiveChanged, removed = archiveRemoved
        syncMessage = "Added " + destination.lastPathComponent + " to the running backup."
        Task.detached(priority: .userInitiated) {
            var status = "Stopped safely. Completed files retained."
            if Self.availableBackupDirectory(source) && Self.availableBackupDirectory(destination) {
                let result = await Self.syncFolder(
                    source: source, destination: destination,
                    archiveChanged: changed, archiveRemoved: removed,
                    filter: filter, snapshot: nil, control: control
                ) { update in
                    await MainActor.run {
                        if let index = self.syncProgress.firstIndex(where: { $0.destination == update.destination }) {
                            self.syncProgress[index] = update
                        }
                    }
                }
                await MainActor.run { self.recordBackup(result) }
                status = result.status
            } else {
                let skipped = "Skipped: Destination Unavailable"
                status = skipped
                await MainActor.run {
                    if let index = self.syncProgress.firstIndex(where: { $0.destination == destination.path }) {
                        self.syncProgress[index].status = skipped
                    }
                }
            }
            let finalStatus = status
            await MainActor.run {
                self.backupOutcomes[destination.path] = finalStatus
                self.runningBackupJobs -= 1
                self.finishBackupIfIdle()
            }
        }
    }
    // Session-aware defaults respect manual selections and accept common naming
    // conventions such as 01Capture, Capture_RAW, 02Output, and OUTPUT-JPG.
    // If multiple equally strong candidates exist, require manual selection.
    func configureSessionDefaults() {
        guard let root else { return }
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let directories = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        func detectedFolder(_ keyword: String) -> URL? {
            let matches: [(URL, Int)] = directories.compactMap { url in
                let name = url.lastPathComponent.lowercased()
                let term = keyword.lowercased()
                guard name.contains(term) else { return nil }
                // Exact names win; numbered-prefix names are next; other
                // keyword-containing names are acceptable when unambiguous.
                let score: Int
                if name == term { score = 0 }
                else if let range = name.range(of: term),
                        !name[..<range.lowerBound].isEmpty,
                        name[..<range.lowerBound].allSatisfy({ $0.isNumber || $0 == "_" || $0 == "-" || $0 == " " }) { score = 1 }
                else { score = 2 }
                return (url, score)
            }
            guard let best = matches.map(\.1).min() else { return nil }
            let winners = matches.filter { $0.1 == best }
            return winners.count == 1 ? winners[0].0 : nil
        }
        if !qcCaptureOverride { qcCaptureFolder = detectedFolder("Capture") }
        if !qcExportOverride { deliveryFolder = detectedFolder("Output") }
        qcHasRun = false
        qcGroups = []
    }
    func resetQCCaptureToDefault() {
        qcCaptureOverride = false
        configureSessionDefaults()
    }
    func resetQCExportToDefault() {
        qcExportOverride = false
        configureSessionDefaults()
    }
    func chooseQCCapture() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            qcCaptureFolder = url; qcCaptureOverride = true; qcHasRun = false; qcGroups = []
        }
    }
    func chooseDelivery() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { deliveryFolder = panel.url; qcExportOverride = true; qcHasRun = false; qcGroups = [] }
    }
    // Keep dashboard inventory tied to the session that produced it. Never show
    // the previous session's counts while a new scan is deferred or underway.
    func refreshDashboardForSessionChange() {
        guard let root else {
            storageScanID = UUID()
            dashboardInventoryRoot = nil
            pendingDashboardScan = false
            assets = []
            storageSummary = .empty
            if storageScanning { busy = false }
            storageScanning = false
            scanningRoot = nil
            return
        }
        let wanted = root.standardizedFileURL
        // Version 19: already showing, or already scanning, this session. The
        // old code discarded a scan that had just started for this same
        // session and left the app stuck in "busy", so the first Open Session
        // or "Use This Session" appeared to do nothing.
        if dashboardInventoryRoot?.standardizedFileURL == wanted { return }
        if storageScanning, scanningRoot?.standardizedFileURL == wanted { return }
        pendingDashboardScan = true
        // A running dashboard scan of another session is superseded by scan().
        if !syncBusy && (!busy || storageScanning) { scan() }
    }
    private var scanningRoot: URL?
    /// Busy only because the Dashboard is scanning files, which a new session
    /// choice may safely replace.
    var busyOnlyWithDashboardScan: Bool { busy && storageScanning }
    func resumeDeferredDashboardScan() {
        guard pendingDashboardScan && !syncBusy && !busy else { return }
        scan()
    }
    func scan() {
        guard let root else { return }
        // Invalidate old inventory immediately, including when backup contention
        // means this session cannot be scanned until the backup completes.
        if dashboardInventoryRoot?.standardizedFileURL != root.standardizedFileURL {
            storageScanID = UUID()
            dashboardInventoryRoot = nil
            assets = []
            storageSummary = .empty
        }
        if DigiBackupBenchmark.shared.isRunning || (DigiPerformanceSettings.shared.deferScansDuringBackup && syncBusy) {
            pendingDashboardScan = true
            storageScanning = false
            progress = "Dashboard scan queued until the backup or benchmark finishes."
            return
        }
        pendingDashboardScan = false
        let priority = DigiPerformanceSettings.shared.scanPriority
        busy = true; progress = "Scanning files…"
        storageScanning = true
        scanningRoot = root
        let scanID = UUID()
        storageScanID = scanID
        let ignored = ignoredFolders
        Task.detached(priority: priority) {
            let files = Self.inventory(root: root, ignored: ignored)
            let storage = SessionStorageSummary.scan(root)
            await MainActor.run {
                // A newer scan owns the busy flag and will clear it.
                guard self.storageScanID == scanID else { return }
                guard self.root?.standardizedFileURL == root.standardizedFileURL else {
                    self.busy = false
                    self.storageScanning = false
                    self.scanningRoot = nil
                    return
                }
                self.scanningRoot = nil
                self.dashboardInventoryRoot = root
                self.storageSummary = storage
                self.storageScanning = false
                self.assets = files
                self.variantConflicts = []
                self.unmatchedVariants = 0
                self.ambiguousFiles = 0
                self.results = []
                self.busy = false
                self.progress = "Scanned \(files.count) image files. Ratings and tags require validated Capture One metadata."
            }
        }
    }
    nonisolated static func inventory(root: URL, ignored: Set<String>) -> [Asset] {
        let fm = FileManager.default
        let extensions: Set<String> = ["iiq","cr2","cr3","nef","nrw","arw","raf","orf","rw2","dng","3fr","fff","mos","pef","srw","rwl","raw","jpg","jpeg","tif","tiff","png","psd","heic","bmp","exr"]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey,.fileSizeKey,.contentModificationDateKey,.isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        var items: [Asset] = []
        for case let url as URL in enumerator {
            if ignored.contains(url.lastPathComponent) {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard extensions.contains(url.pathExtension.lowercased()), let v = try? url.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey,.contentModificationDateKey]), v.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            items.append(Asset(id: relative, url: url, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
        }
        return items.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
    func scanCaptureOne() {
        guard !assets.isEmpty else { progress = "Choose your session folder on \(DigiBrand.toolName(0)) first"; return }
        guard let captureApp = CaptureOneTarget.running(), let target = CaptureOneTarget.reference(captureApp) else {
            progress = "Open Capture One with this session first, then try again."
            return
        }
        busy = true
        progress = "Reading Capture One variants…"
        unmatchedVariants = 0
        ambiguousFiles = 0
        variantConflicts = []
        // Retrieve all variant properties in bulk. Resolve each variant to its
        // original file path, never just the basename (RAW and JPEG may differ).
        let script = """
        if not (\(target) is running) then return ""
        tell \(target)
            set variantFiles to get file of every variant of current document
            set variantRatings to get rating of every variant of current document
            set variantTags to get color tag of every variant of current document
            set variantPicks to get pick of every variant of current document
        end tell
        set outputLines to {}
        repeat with i from 1 to (count of variantFiles)
            try
                set filePath to POSIX path of (item i of variantFiles)
                set end of outputLines to (filePath & (ASCII character 31) & (item i of variantRatings as text) & (ASCII character 31) & (item i of variantTags as text) & (ASCII character 31) & (item i of variantPicks as text))
            end try
        end repeat
        set AppleScript's text item delimiters to (ASCII character 10)
        set resultText to outputLines as text
        set AppleScript's text item delimiters to ""
        return resultText
        """
        let indexedPaths = Set(assets.map { $0.url.standardizedFileURL.path.precomposedStringWithCanonicalMapping })
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            // File-backed output avoids pipe-buffer deadlocks on large sessions.
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".err")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: outputURL); try? FileManager.default.removeItem(at: errorURL) }
            guard let outputHandle = FileHandle(forWritingAtPath: outputURL.path),
                  let errorHandle = FileHandle(forWritingAtPath: errorURL.path) else {
                await MainActor.run { self.busy = false; self.progress = "Cannot create scan output files" }
                return
            }
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            do {
                try process.run()
                await MainActor.run { self.captureProcess = process }
                process.waitUntilExit()
                try? outputHandle.close()
                try? errorHandle.close()
                let data = (try? Data(contentsOf: outputURL)) ?? Data()
                let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
                let cancelled = await MainActor.run { () -> Bool in
                    let wasCancelled = !self.busy
                    self.captureProcess = nil
                    return wasCancelled
                }
                if cancelled { return }
                guard process.terminationStatus == 0 else {
                    let reason = String(data: errorData, encoding: .utf8) ?? "AppleScript failed"
                    await MainActor.run { self.busy = false; self.progress = "Capture One: " + reason }
                    return
                }
                let rows = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: .newlines)
                struct VariantInfo {
                    let rating: Int
                    let tag: Int
                    let picked: Bool
                }
                var values: [String: [VariantInfo]] = [:]
                for row in rows {
                    let fields = row.components(separatedBy: String(UnicodeScalar(31)!))
                    guard fields.count == 4, let rating = Int(fields[1]), let tag = Int(fields[2]) else { continue }
                    let path = URL(fileURLWithPath: fields[0]).standardizedFileURL.path.precomposedStringWithCanonicalMapping
                    values[path, default: []].append(VariantInfo(rating: rating, tag: tag, picked: fields[3].lowercased() == "true"))
                }
                let scannedValues = values
                let scannedCount = scannedValues.values.reduce(0) { $0 + $1.count }
                let missingPaths = scannedValues.keys.filter { !indexedPaths.contains($0) }.count
                await MainActor.run {
                    var updatedAssets = self.assets
                    var matched = 0
                    var conflicts: [VariantConflict] = []
                    for i in updatedAssets.indices {
                        let path = updatedAssets[i].url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
                        guard let variants = scannedValues[path], !variants.isEmpty else { continue }
                        // Only the picked variant controls selects. If multiple
                        // picked variants for the SAME file disagree, flag review.
                        let picked = variants.filter { $0.picked }
                        let controlling = picked.isEmpty ? variants : picked
                        let distinct = Set(controlling.map { "\($0.rating):\($0.tag)" })
                        if distinct.count != 1 {
                            updatedAssets[i].rating = nil
                            updatedAssets[i].tag = nil
                            updatedAssets[i].metadataSource = "Conflict: picked variants disagree"
                            let details = Array(Set(variants.map { "\($0.rating) stars, tag \($0.tag), picked \($0.picked)" })).sorted()
                            conflicts.append(VariantConflict(id: path, filename: updatedAssets[i].url.lastPathComponent, variants: details, paths: [updatedAssets[i].id]))
                            continue
                        }
                        guard let first = controlling.first else { continue }
                        updatedAssets[i].rating = first.rating
                        updatedAssets[i].tag = first.tag == 0 ? "None" : (first.tag == 4 ? "Green" : "Tag \(first.tag)")
                        updatedAssets[i].metadataSource = "Capture One (picked variant)"
                        matched += 1
                    }
                    self.assets = updatedAssets
                    self.variantConflicts = conflicts.sorted { $0.filename < $1.filename }
                    self.unmatchedVariants = missingPaths
                    self.ambiguousFiles = conflicts.count
                    self.busy = false
                    self.progress = "Capture One: \(scannedCount) variants, \(matched) exact-path matches, \(missingPaths) paths outside selected folder" + (conflicts.isEmpty ? "" : ", \(conflicts.count) picked-variant conflicts")
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.busy = false; self.progress = "Unable to launch AppleScript: " + message }
            }
        }
    }
    func importMetadata() {
        guard !assets.isEmpty else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let header = lines.first else { return }
        let delimiter: Character = header.contains("\t") ? "\t" : ","
        let columns = parseRow(header, delimiter: delimiter).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func idx(_ names: [String]) -> Int? { columns.firstIndex { names.contains($0) } }
        guard let fileIndex = idx(["filename","file name","name","path","relative path"]) else { progress = "Metadata CSV needs a filename column"; return }
        let ratingIndex = idx(["rating","stars","star rating"])
        let tagIndex = idx(["color","colour","color tag","colour tag","tag","color label"])
        var byPath: [String:(Int?,String?)] = [:]
        var byName: [String:[(Int?,String?)]] = [:]
        for line in lines.dropFirst() {
            let row = parseRow(line, delimiter: delimiter)
            guard fileIndex < row.count else { continue }
            let name = row[fileIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rating = ratingIndex.flatMap { $0 < row.count ? Int(row[$0].trimmingCharacters(in: .whitespaces)) : nil }
            let tag = tagIndex.flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines).capitalized : nil }
            let value = (rating,tag?.isEmpty == true ? nil : tag)
            byPath[name] = value
            byName[URL(fileURLWithPath: name).lastPathComponent, default: []].append(value)
        }
        var matched = 0
        for i in assets.indices {
            let asset = assets[i]
            let exact = byPath[asset.id] ?? byPath[asset.url.path]
            let unique = byName[asset.url.lastPathComponent].flatMap { $0.count == 1 ? $0.first : nil }
            if let values = exact ?? unique {
                assets[i].rating = values.0
                assets[i].tag = values.1
                assets[i].metadataSource = url.lastPathComponent
                matched += 1
            }
        }
        progress = "Imported ratings/tags for \(matched) of \(assets.count) files from \(url.lastPathComponent)"
    }
    nonisolated static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func verifyBackups() {
        guard let root, !backups.isEmpty, !assets.isEmpty else { progress = "Choose source and at least one backup"; return }
        let source = assets; let destinations = backups; busy = true; progress = "Verifying SHA-256 checksums. This may take a while…"
        Task.detached {
            var outcomes: [CheckResult] = []
            for backup in destinations {
                var missing = 0, mismatch = 0, verified = 0
                for asset in source {
                    let dest = backup.appendingPathComponent(asset.id)
                    guard FileManager.default.fileExists(atPath: dest.path) else { missing += 1; continue }
                    do {
                        if try Self.sha256(asset.url) == Self.sha256(dest) { verified += 1 } else { mismatch += 1 }
                    } catch { mismatch += 1 }
                }
                outcomes.append(CheckResult(label: backup.lastPathComponent, detail: "\(verified) verified · \(missing) missing · \(mismatch) mismatched", good: missing == 0 && mismatch == 0))
            }
            let finishedOutcomes = outcomes
            await MainActor.run { self.results = finishedOutcomes; self.busy = false; self.progress = "Backup verification finished" }
        }
        _ = root
    }
    func qcDelivery() {
        guard let capture = qcCaptureFolder, let export = deliveryFolder else {
            progress = "Choose both Capture and Export folders"; return
        }
        let rawTypes = rawExtensions
        let ignored = ignoredFolders
        busy = true; qcHasRun = false; qcGroups = []
        progress = "Comparing RAW captures to exported JPEGs…"
        Task.detached {
            let captures = Self.inventory(root: capture, ignored: ignored).filter {
                rawTypes.contains($0.url.pathExtension.lowercased())
            }
            let jpegs = Self.inventory(root: export, ignored: ignored).filter {
                ["jpg", "jpeg"].contains($0.url.pathExtension.lowercased())
            }
            // Use case-insensitive stems, not extension, and consume each JPEG
            // once. This avoids a single JPEG satisfying multiple RAW captures
            // that happen to share a filename.
            func stem(_ asset: Asset) -> String {
                asset.url.deletingPathExtension().lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            }
            var available: [String: Int] = [:]
            for jpeg in jpegs { available[stem(jpeg), default: 0] += 1 }
            var missing: [String: [String]] = [:]
            var matched = 0
            for raw in captures {
                let key = stem(raw)
                if available[key, default: 0] > 0 {
                    available[key, default: 0] -= 1
                    matched += 1
                } else {
                    let folder = (raw.id as NSString).deletingLastPathComponent
                    let displayFolder = folder.isEmpty ? "(Capture root)" : folder
                    missing[displayFolder, default: []].append(raw.url.lastPathComponent)
                }
            }
            let groups = missing.map { folder, names in
                UnprocessedFolder(id: folder, files: names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            let total = captures.count
            let jpegCount = jpegs.count
            let matchedCount = matched
            await MainActor.run {
                self.qcRawCount = total
                self.qcJPEGCount = jpegCount
                self.qcMatchedCount = matchedCount
                self.qcGroups = groups
                self.qcHasRun = true
                self.busy = false
                self.progress = "Processing check complete: \(matchedCount) of \(total) RAW files have corresponding JPEGs"
                self.results.append(CheckResult(label: "Processing Completeness", detail: "\(matchedCount)/\(total) RAW files matched; \(total - matchedCount) unprocessed across \(groups.count) folders", good: matchedCount == total))
            }
        }
    }
    func exportSelects() {
        guard !outputFormat.isEmpty else { progress = "Choose CSV, TXT, or Both"; return }
        guard let root else { progress = "Choose a session folder first"; return }
        let sessionName = root.lastPathComponent
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sessionName + "_Selects" + (outputFormat == "CSV" ? ".csv" : ".txt")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let base = panel.url else { return }
        let chosen = selects
        let sorted = chosen.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        let groups: [(String, [Asset])]
        if selectedRatings.isEmpty && selectedTags.isEmpty {
            groups = [("All Matching Files", sorted)]
        } else {
            let ratingGroups: [(String, [Asset])] = selectedRatings.sorted().map { rating in
                (rating == 0 ? "Unrated (0 Stars)" : "\(rating) Stars", sorted.filter { $0.rating == rating })
            }
            let orderedTags = tags.filter { selectedTags.contains($0) } + selectedTags.filter { !tags.contains($0) }.sorted()
            let tagGroups: [(String, [Asset])] = orderedTags.map { tag in
                ("\(tag) Tag", sorted.filter { ($0.tag ?? "None") == tag })
            }
            groups = ratingGroups + tagGroups
        }
        func filename(_ asset: Asset) -> String {
            includeExtension ? asset.url.lastPathComponent : asset.url.deletingPathExtension().lastPathComponent
        }
        let folder = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        var failures: [String] = []
        if outputFormat == "TXT" || outputFormat == "Both" {
            var lines = [sessionName, String(repeating: "=", count: max(12, sessionName.count)), "", "Total Unique Files: \(chosen.count)", ""]
            for (label, files) in groups {
                let heading = "\(label.uppercased()) (\(files.count))"
                lines += [heading, String(repeating: "-", count: heading.count)]
                lines += files.map(filename)
                lines.append("")
            }
            do { try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent(stem + ".txt"), atomically: true, encoding: .utf8) }
            catch { failures.append("TXT: \(error.localizedDescription)") }
        }
        if outputFormat == "CSV" || outputFormat == "Both" {
            func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            var rows = [["Session", "Category", "Filename", "Relative Path", "Rating", "Color Tag", "Metadata Source", "Total Unique Files"].map(quote).joined(separator: ",")]
            for (label, files) in groups {
                for asset in files {
                    rows.append([sessionName, label, filename(asset), asset.id, asset.rating.map(String.init) ?? "", asset.tag ?? "", asset.metadataSource, String(chosen.count)].map(quote).joined(separator: ","))
                }
            }
            do { try (rows.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent(stem + ".csv"), atomically: true, encoding: .utf8) }
            catch { failures.append("CSV: \(error.localizedDescription)") }
        }
        progress = failures.isEmpty ? "Exported \(chosen.count) unique files in \(groups.count) groups for \(sessionName)" : "Export error: " + failures.joined(separator: "; ")
    }
    func exportWrapReport(options: JobReportOptions) {
        guard let root else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(reportName)_Job_Report.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let success = DigiJobReport.export(root: root, assets: assets, reportName: reportName,
                                           results: results, options: options, to: url)
        if success {
            let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
            jobHistory.insert("\(date) · \(reportName) · \(url.path)", at: 0)
            UserDefaults.standard.set(Array(jobHistory.prefix(100)), forKey: "wrapHistory")
            progress = "Saved job report: \(url.lastPathComponent)"
        } else { progress = "Job report export failed" }
    }
    func createJobFolders() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let safe = reportName.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = parent.appendingPathComponent(safe.isEmpty ? "New Shoot" : safe)
        for folder in ["Capture","Selects","Output","Retouching","Deliverables","Reports","Backup"] { try? FileManager.default.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true) }
        progress = "Created job folders at \(base.path)"
    }
    func prepareDelivery() {
        guard let deliveryFolder else { progress = "Choose a delivery folder first"; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let source = deliveryFolder
        busy = true; progress = "Copying delivery package…"
        Task.detached {
            let fm = FileManager.default
            let destination = target.appendingPathComponent("ShootWrap_Delivery_\(Int(Date().timeIntervalSince1970))")
            var message = ""
            do {
                try fm.copyItem(at: source, to: destination)
                let sourceItems = Self.inventory(root: source, ignored: [])
                var mismatch = 0
                for a in sourceItems {
                    let b = destination.appendingPathComponent(a.id)
                    if (try? Self.sha256(a.url)) != (try? Self.sha256(b)) { mismatch += 1 }
                }
                let manifest = sourceItems.map { $0.id }.joined(separator: "\n")
                try manifest.write(to: destination.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
                message = "Package copied: \(sourceItems.count) files, \(mismatch) checksum mismatches"
            } catch { message = "Delivery failed: \(error.localizedDescription)" }
            let finishedMessage = message
            await MainActor.run { self.busy = false; self.progress = finishedMessage }
        }
    }
    private func parseRow(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        let chars = Array(line); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i+1 < chars.count && chars[i+1] == "\"" { current.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if c == delimiter && !quoted { fields.append(current); current = "" }
            else { current.append(c) }
            i += 1
        }
        fields.append(current); return fields
    }
}

// Session discovery is advisory. It never starts a backup or changes folders without approval.
// Advisory only: never changes workspace or starts a backup without user approval.
@MainActor final class CaptureOneSessionMonitor: ObservableObject {
    @Published var candidate: URL?
    @Published var offerID = UUID()
    @Published var matches: [URL] = []
    @Published var status = "Waiting for Capture One"
    @Published var enabled = UserDefaults.standard.object(forKey: "DigiSuite.captureOneAutoDetect") as? Bool ?? true
    private var loop: Task<Void, Never>?
    private var dismissedSignatures: Set<String> = []
    private var lastOfferedSignature = ""
    private var currentSignature = ""
    private var isChecking = false

    func start() {
        guard loop == nil else { return }
        // v1.25: look often while nothing is found, then only every 45 s, so
        // Capture One is left alone while you shoot.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                let settled: Bool = self?.matches.isEmpty == false
                try? await Task.sleep(for: .seconds(settled ? 45 : 12))
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "DigiSuite.captureOneAutoDetect")
        if !value { candidate = nil; matches = []; status = "Automatic detection off" }
    }
    func dismiss() {
        dismissedSignatures.insert(currentSignature)
        candidate = nil
    }
    func accepted() {
        dismissedSignatures.insert(currentSignature)
        candidate = nil
    }

    /// Version 20.7: what a check found, so a manual Detect can tell the user.
    enum DetectOutcome { case notRunning, noSessions, found, skipped }

    @discardableResult
    func check(force: Bool = false) async -> DetectOutcome {
        guard (enabled || force), !isChecking else { return .skipped }
        let captureApps = NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("captureone") ||
            ($0.localizedName ?? "").localizedCaseInsensitiveContains("Capture One")
        }.filter { ($0.executableURL?.lastPathComponent ?? "").localizedCaseInsensitiveContains("Capture One") }
        let processIDs = captureApps.map { Int($0.processIdentifier) }
        let target: String = CaptureOneTarget.running().flatMap { CaptureOneTarget.reference($0) } ?? ""
        guard !processIDs.isEmpty, !target.isEmpty else {
            status = "Capture One is not running"
            matches = []
            return .notRunning
        }
        isChecking = true
        defer { isChecking = false }
        status = "Checking open Capture One sessions…"

        let result = await Task.detached(priority: .utility) { () -> (String?, [URL]) in
            func run(_ executable: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                // v1.25: lowest priority, so these checks never compete with Capture One.
                process.qualityOfService = .background
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                guard (try? process.run()) != nil else { return nil }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                guard process.terminationStatus == 0 else { return nil }
                return String(data: bytes, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // lsof -Fn emits one filename record per open file, prefixed with "n".
            // Unlike Spotlight, this reflects what Capture One has actually opened.
            let fm = FileManager.default
            var found: [URL] = []
            for pid in processIDs {
                guard let output = run("/usr/sbin/lsof", ["-nP", "-Fn", "-p", String(pid)], timeout: 10) else { continue }
                for line in output.components(separatedBy: .newlines) where line.hasPrefix("n/") {
                    let path = String(line.dropFirst())
                    guard path.lowercased().hasSuffix(".cosessiondb") else { continue }
                    let database = URL(fileURLWithPath: path).standardizedFileURL
                    guard fm.fileExists(atPath: database.path) else { continue }
                    found.append(database.deletingLastPathComponent())
                }
            }
            let unique = Dictionary(grouping: found, by: \.path)
                .compactMap { $0.value.first }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

            // AppleScript is only used to preselect the current document.
            // It never adds an unverified Spotlight or backup location.
            let script = """
            if not (\(target) is running) then return ""
            tell \(target)
                try
                    return name of current document as text
                on error
                    return ""
                end try
            end tell
            """
            // v1.25: only ask Capture One when there's a choice to make. With one
            // (or no) open session, nothing is sent to Capture One at all.
            var frontmostName: String?
            if unique.count > 1 {
                frontmostName = run("/usr/bin/osascript", ["-e", script], timeout: 6)
            }
            return (frontmostName, unique)
        }.value

        let urls = result.1
        matches = urls
        if urls.isEmpty {
            status = "No open session databases found. Use Open Session to select manually."
            return .noSessions
        }
        status = "\(urls.count) open session location(s) found"
        // Only notify when the set changes. Keep declined lists quiet until a new session opens.
        let signature = urls.map(\.path).sorted().joined(separator: "\n")
        currentSignature = signature
        if force { dismissedSignatures.remove(signature); lastOfferedSignature = "" }
        guard !dismissedSignatures.contains(signature), lastOfferedSignature != signature else { return .found }
        lastOfferedSignature = signature
        let frontmost = result.0
        candidate = urls.first(where: { url in
            guard let name = frontmost else { return false }
            return FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
        }) ?? urls.first
        offerID = UUID()
        return .found
    }
}

struct ShootWrapView: View {
    @StateObject private var captureOneMonitor = CaptureOneSessionMonitor()
    @ObservedObject private var backupBenchmark = DigiBackupBenchmark.shared
    @State private var showBackupBenchmark = false
    @AppStorage("DigiSuite.showBackupDetails") private var showBackupDetails = false
    @State private var sessionProposal: URL?
    @State private var showSessionProposal = false
    @State private var chosenSessionPath = ""
    @State private var pendingSessionWhileBusy: URL?
    // Five-app build: first-launch tour, shown once per app.
    @State private var showTour = false
    @AppStorage("DigiBrand.tourFinished.v1") private var tourFinished = false
    // v1.8: Proof's Light / Dark / Match System choice.
    @AppStorage(DigiAppearance.key) private var appearance = "light"
    @Environment(\.colorScheme) private var currentScheme

    private var brandColorScheme: ColorScheme? {
        if DigiBrand.isClassic { return nil }
        if DigiBrand.hasAppearanceChoice && appearance == "system" { return nil }
        return DigiBrand.theme.scheme
    }

    /// Changes whenever the colors in use change, so every screen redraws in the new look.
    private var appearanceID: String {
        guard DigiBrand.hasAppearanceChoice else { return "fixed" }
        return appearance + (currentScheme == .dark ? "-dark" : "-light")
    }

    private func considerDetectedSession(_ url: URL?) {
        guard let url else { return }
        if captureOneMonitor.matches.count == 1, url.standardizedFileURL == model.root?.standardizedFileURL { return }
        let blocked: Bool = model.syncBusy || (model.busy && !model.busyOnlyWithDashboardScan) ||
            backupBenchmark.isRunning || showBackupBenchmark
        if blocked {
            pendingSessionWhileBusy = url
            return
        }
        sessionProposal = url
        chosenSessionPath = url.path
        showSessionProposal = true
    }

    /// A manual Detect always answers: a short dialog unless the session
    /// picker is about to appear. Return closes the dialog.
    private func explainDetectOutcome(_ outcome: CaptureOneSessionMonitor.DetectOutcome) {
        var title = ""
        var detail = ""
        switch outcome {
        case .notRunning:
            title = "Capture One isn't open"
            detail = "Open your session in Capture One, then click Detect Session again."
        case .noSessions:
            title = "No session is open in Capture One"
            detail = "Capture One is running, but no session is open in it. Open a session in Capture One, or use Open Session… to choose a folder."
        case .found:
            let matches = captureOneMonitor.matches
            guard matches.count == 1, let only = matches.first,
                  only.standardizedFileURL == model.root?.standardizedFileURL else { return }
            title = only.lastPathComponent + " is already open"
            detail = "This is the session Capture One has open, and \(DigiBrand.name) is already using it."
        case .skipped:
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func acceptDetectedSession() {
        let otherWork: Bool = model.busy && !model.busyOnlyWithDashboardScan
        guard sessionProposal != nil, !chosenSessionPath.isEmpty,
              !model.syncBusy, !otherWork else { return }
        let url = URL(fileURLWithPath: chosenSessionPath)
        model.root = url
        if let name = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .first(where: { $0.lowercased().hasSuffix(".cosessiondb") }) {
            UserDefaults.standard.set(url.appendingPathComponent(name).path,
                forKey: "DigiSuite.captureOneSessionPath.\(name)")
        }
        model.reportName = url.lastPathComponent
        model.qcCaptureOverride = false
        model.qcExportOverride = false
        model.qcCaptureFolder = nil
        model.deliveryFolder = nil
        model.configureSessionDefaults()
        model.scan()
        model.discoverExternalBackupFolders()
        syncDashboardSource()
        captureOneMonitor.accepted()
        sessionProposal = nil
    }

    private var captureOneProposalSheet: some View {
        SessionProposalSheet(
            matches: captureOneMonitor.matches,
            initial: chosenSessionPath,
            canAccept: !(model.syncBusy || (model.busy && !model.busyOnlyWithDashboardScan)),
            onNotNow: {
                captureOneMonitor.dismiss()
                showSessionProposal = false
            },
            onUse: { path in
                chosenSessionPath = path
                acceptDetectedSession()
                showSessionProposal = false
            }
        )
    }

    private var captureOneIntegration: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("Capture One Integration").font(.subheadline.weight(.semibold))
                Text(captureOneMonitor.status).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("Auto-detect", isOn: Binding(
                get: { captureOneMonitor.enabled },
                set: { captureOneMonitor.setEnabled($0) }
            )).toggleStyle(.checkbox)
            Button("Detect Session") {
                Task {
                    let outcome = await captureOneMonitor.check(force: true)
                    explainDetectOutcome(outcome)
                }
            }
        }
        .padding(12)
        .background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 12))
    }

    @State private var editingBackupDestination: String? = nil
    static let sections: [(name: String, icon: String)] = [
        ("Dashboard", "square.grid.2x2"),
        ("Backups", "externaldrive.badge.checkmark"),
        ("Selects List", "star.square"),
        ("Processed Files Check", "checkmark.seal"),
        ("Folder Maker", "folder.badge.plus"),
        ("Reports & Jobs", "doc.text"),
        ("Contact Sheets", "square.grid.3x3"),
        ("Folder Compare", "square.split.3x1"),
        ("Metadata Watcher (BETA)", "tag")
    ]
    @ObservedObject var model: WrapModel
    @State private var pendingBackupSource: URL? = nil
    @AppStorage("DigiTools.tabOrder.v1") private var savedTabOrder = "0,1,2,3,4,5,6,7,8"
    @AppStorage("DigiSuite.hiddenTabs.v1") private var hiddenTabIDs = ""
    @State private var vaporizingTab: Int? = nil
    @State private var draggingTab: Int? = nil
    @State private var proposedTabPosition: Int? = nil
    @State private var tabDragOffset: CGSize = .zero
    private func syncDashboardSource() {
        guard let session = model.root else { return }
        if model.syncBusy {
            pendingBackupSource = session
        } else if model.syncSource != session {
            pendingBackupSource = nil
            model.syncSource = session
            model.syncProgress = []
            model.syncPreviewReady = false
        }
    }
    private var tabOrder: [Int] {
        let ids = savedTabOrder.split(separator: ",").compactMap { Int($0) }
        if ids.count == Self.sections.count && Set(ids) == Set(Self.sections.indices) { return ids }
        if ids.count < Self.sections.count && Set(ids) == Set(0..<ids.count) {
            return ids + Array(ids.count..<Self.sections.count)
        }
        return Array(Self.sections.indices)
    }
    private var hiddenTabs: Set<Int> {
        Set(hiddenTabIDs.split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 && $0 < Self.sections.count })
    }
    private var visibleTabs: [Int] {
        // The five apps step through tools in their own on-screen order.
        let order: [Int] = DigiBrand.isClassic ? tabOrder : DigiBrand.toolOrder
        return order.filter { !hiddenTabs.contains($0) }
    }
    private func hideTab(_ index: Int) {
        guard index != 0 else { return } // Dashboard is the permanent session anchor.
        var hidden = hiddenTabs
        hidden.insert(index)
        hiddenTabIDs = hidden.sorted().map(String.init).joined(separator: ",")
        if model.lastTab == index { model.lastTab = 0 }
    }
    private func restoreTab(_ index: Int) {
        var hidden = hiddenTabs
        hidden.remove(index)
        hiddenTabIDs = hidden.sorted().map(String.init).joined(separator: ",")
        model.lastTab = index
    }
    private func moveTab(_ source: Int, toPosition position: Int) {
        var visible = visibleTabs
        guard let oldPosition = visible.firstIndex(of: source),
              visible.indices.contains(position), oldPosition != position else { return }
        visible.remove(at: oldPosition)
        visible.insert(source, at: position)
        // Keep hidden tools in the saved order for when they are restored.
        var remaining = visible.makeIterator()
        let merged = tabOrder.map { hiddenTabs.contains($0) ? $0 : (remaining.next() ?? $0) }
        savedTabOrder = merged.map(String.init).joined(separator: ",")
    }
    private func tabDropPosition(for source: Int, horizontalDrag: CGFloat, availableWidth: CGFloat) -> Int {
        let ids = visibleTabs
        guard let start = ids.firstIndex(of: source) else { return 0 }
        let slotWidth = max(1, (availableWidth - CGFloat(max(0, ids.count - 1)) * 4) / CGFloat(ids.count) + 4)
        return min(ids.count - 1, max(0, start + Int((horizontalDrag / slotWidth).rounded())))
    }
    private func tabFace(_ index: Int, isDropTarget: Bool) -> some View {
        let section = Self.sections[index]
        let selected = model.lastTab == index
        return HStack(spacing: 7) {
            Image(systemName: section.icon)
            if index == 8 {
                VStack(spacing: 0) {
                    Text("Metadata Watcher").lineLimit(1).minimumScaleFactor(0.65)
                    Text("BETA").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.orange)
                }
            } else {
                Text(section.name).lineLimit(1).minimumScaleFactor(0.65)
            }
        }
        .font(.system(size: 12, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity, minHeight: 39)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? DigiBrand.accent.opacity(0.22) : Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isDropTarget ? DigiBrand.accent :
                        (selected ? DigiBrand.accent.opacity(0.7) : Color.primary.opacity(0.18)),
                    lineWidth: isDropTarget ? 2.5 : (selected ? 1.3 : 1)
                )
        )
        .help("\(section.name) · Command-drag sideways to reorder or down to hide")
        .accessibilityLabel(section.name)
    }
    private func stepTab(_ delta: Int) {
        let ids = visibleTabs
        guard !ids.isEmpty, let current = ids.firstIndex(of: model.lastTab) else { return }
        model.lastTab = ids[(current + delta + ids.count) % ids.count]
    }
    /// Digi Suite's original layout: tabs along the top.
    private var classicWorkspace: some View {
        VStack(spacing: 0) {
            // Chrome-inspired, individually outlined tabs. All tabs share the
            // available width, while the active tab keeps the blue highlight.
            HStack(alignment: .bottom, spacing: 8) {
            GeometryReader { tabGeometry in
                let gap: CGFloat = 4
                let slotWidth = max(1, (tabGeometry.size.width - CGFloat(max(0, visibleTabs.count - 1)) * gap) / CGFloat(max(1, visibleTabs.count)))
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(visibleTabs, id: \.self) { index in
                            tabFace(index, isDropTarget: false)
                                .opacity(draggingTab == index ? 0.15 : 1)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture { if draggingTab == nil { model.lastTab = index } }
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 8)
                                        .onChanged { value in
                                            // Dragging any tab is sufficient; no modifier key required.
                                            draggingTab = index
                                            tabDragOffset = value.translation
                                            proposedTabPosition = (value.translation.height > 70 && index != 0) ? nil : tabDropPosition(
                                                for: index,
                                                horizontalDrag: value.translation.width,
                                                availableWidth: tabGeometry.size.width
                                            )
                                        }
                                        .onEnded { value in
                                            if draggingTab == index {
                                                let destination = tabDropPosition(
                                                    for: index,
                                                    horizontalDrag: value.translation.width,
                                                    availableWidth: tabGeometry.size.width
                                                )
                                                if value.translation.height > 70 && index != 0 {
                                                    vaporizingTab = index
                                                    withAnimation(.easeOut(duration: 0.24)) { hideTab(index) }
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { vaporizingTab = nil }
                                                } else {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        moveTab(index, toPosition: destination)
                                                    }
                                                }
                                            }
                                            draggingTab = nil
                                            proposedTabPosition = nil
                                            tabDragOffset = .zero
                                        }
                                )
                        }
                    }
                    // Show an insertion marker BETWEEN tabs, not a border
                    // around the tab currently under the dragged item.
                    if let source = draggingTab,
                       let sourcePosition = visibleTabs.firstIndex(of: source),
                       let destination = proposedTabPosition,
                       destination != sourcePosition {
                        let boundary = destination + (destination > sourcePosition ? 1 : 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DigiBrand.accent)
                            .frame(width: 4, height: 35)
                            .shadow(color: DigiBrand.accent.opacity(0.55), radius: 4)
                            .offset(x: CGFloat(boundary) * (slotWidth + gap) - gap / 2 - 2,
                                    y: 2)
                            .allowsHitTesting(false)
                            .zIndex(5)
                    }
                    if vaporizingTab != nil {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.secondary.opacity(0.65))
                            .offset(y: 52)
                            .allowsHitTesting(false)
                    }
                    // A real, full-sized tab follows the pointer. Its original
                    // slot remains faintly visible until the drop completes.
                    if let source = draggingTab,
                       let sourcePosition = visibleTabs.firstIndex(of: source) {
                        tabFace(source, isDropTarget: false)
                            .frame(width: slotWidth, height: 39)
                            .opacity(tabDragOffset.height > 70 && source != 0 ? 0.45 : 1)
                            .shadow(color: .black.opacity(0.35), radius: 9, x: 0, y: 5)
                            .scaleEffect(1.04)
                            .offset(
                                x: CGFloat(sourcePosition) * (slotWidth + gap) + tabDragOffset.width,
                                y: tabDragOffset.height - 5
                            )
                            .allowsHitTesting(false)
                            .zIndex(10)
                    }
                }
            }

                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 26)
                    Menu {
                        ForEach(Self.sections.indices.filter { hiddenTabs.contains($0) }, id: \.self) { index in
                            Button { restoreTab(index) } label: {
                                Label(Self.sections[index].name, systemImage: Self.sections[index].icon)
                            }
                        }
                        if !hiddenTabs.isEmpty { Divider() }
                        Button("Restore All Tabs") {
                            hiddenTabIDs = ""
                            model.lastTab = 0
                        }
                        .disabled(hiddenTabs.isEmpty)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 38, height: 39)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.055)))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 42, height: 39)
                    .help("Restore hidden tabs")
            }
            .frame(height: 39)
            .padding(.horizontal, 16)
            .padding(.top, 11)
            .padding(.bottom, 7)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        if let root = model.root {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            Text(root.lastPathComponent).lineLimit(1).font(.caption)
                        } else {
                            Text("No session selected").font(.caption).foregroundStyle(.secondary)
                            Button("Open Session…") { model.chooseRoot() }.buttonStyle(.link)
                        }
                        Spacer()
                        if model.hasUnsavedChanges { Text("Unsaved changes").font(.caption2).foregroundStyle(.orange) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    toolContent
                }
            }
        }
    }

    /// Each app's own navigation around the same nine tools.
    @ViewBuilder private var brandedWorkspace: some View {
        switch DigiBrand.nav {
        case .classic: classicWorkspace
        case .sidebar: GripShell(model: model) { toolContent }
        case .command: WrapShell(model: model) { toolContent }
        case .timeline: ProofShell(model: model) { toolContent }
        case .tiles: CartShell(model: model) { toolContent }
        case .menuBar: TallyShell(model: model) { toolContent }
        }
    }

    /// The nine tools themselves. Shared by every app.
    private var toolContent: some View {
        ZStack {
                FolderCompareView(sessionRoot: model.root, backupDestinations: model.backups, isActive: model.lastTab == 7, autoRefreshAllowed: !model.syncBusy)
                    .onAppear { syncDashboardSource(); model.startBackupSchedulerIfNeeded() }
                    .onChange(of: model.root) { _ in syncDashboardSource(); model.refreshDashboardForSessionChange() }
                    .onChange(of: model.syncBusy) { busy in
                        if !busy { model.resumeDeferredDashboardScan() }
                        if !busy, let pending = pendingBackupSource {
                            pendingBackupSource = nil
                            model.syncSource = pending
                            model.syncProgress = []
                            model.syncPreviewReady = false
                        }
                    }
                    .opacity(model.lastTab == 7 ? 1 : 0)
                    .allowsHitTesting(model.lastTab == 7)
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.lastTab == -1 {
                        HStack {
                            Button("Open Workspace…") { model.chooseProject() }.disabled(model.syncBusy || model.busy)
                            Button("Save Workspace") { model.saveProject() }.disabled(model.syncBusy || model.busy)
                            Button("Save Workspace As…") { model.saveProject(asNew: true) }.disabled(model.syncBusy || model.busy)
                            Spacer()
                            if model.hasUnsavedChanges {
                                Text("Unsaved workspace changes").font(.caption).foregroundStyle(.orange)
                            }
                            Text(model.projectStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let error = model.projectError {
                            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        Divider()
                    }
                    switch model.lastTab {
                    case 0: dashboard
                    case 1: backups
                    case 2: selects
                    case 3: delivery
                    case 4: FolderMakerView(sessionRoot: model.root, captureFolder: model.qcCaptureFolder, outputFolder: model.deliveryFolder)
                    case 6: ContactSheetsView(sessionRoot: model.root)
                    case 7: EmptyView()
                    case 8: MetadataWatcherView()
                    default: reports
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(model.lastTab == 7 ? 0 : 1)
                .allowsHitTesting(model.lastTab != 7)
            }
    }

    private var mainWorkspaceView: some View {
        brandedWorkspace
        .onReceive(NotificationCenter.default.publisher(for: .shootWrapCommand)) { note in
            guard let action = note.object as? String else { return }
            switch action {
            case "next": stepTab(1)
            case "previous": stepTab(-1)
            case "resetTabs": savedTabOrder = "0,1,2,3,4,5,6,7,8"
            case "open": model.chooseProject()
            case "chooseCapture": model.chooseRoot()
            case "dashboard": model.lastTab = 0
            case "backupsTab": model.lastTab = 1
            case "compareTab": model.lastTab = 7
            case "save": model.saveProject()
            case "saveAs": model.saveProject(asNew: true)
            case "backup": model.requestStartSync()
            case "trial": model.previewSync()
            case "pause": model.togglePauseAll()
            case "stop": model.stopSync()
            case "selects": model.exportSelects()
            case "scan": model.scanCaptureOne()
            case "tour": showTour = true
            default:
                // "tool:4" jumps to a tool by number (Command-1 to Command-9).
                if action.hasPrefix("tool:"), let tool = Int(action.dropFirst(5)), (0..<9).contains(tool),
                   !DigiBrand.retiredTools.contains(tool) {
                    model.lastTab = tool
                    NotificationCenter.default.post(name: .digiToolChosen, object: nil)
                }
            }
        }
    }

    /// The app's look (theme, tour card) around the main window.
    private var brandedRoot: some View {
        mainWorkspaceView
        .id(appearanceID)
        .modifier(DigiTitleBarSpace())
        .overlay(alignment: .bottomTrailing) {
            if showTour {
                DigiTourCard(model: model, isShowing: $showTour) { dontShowAgain in
                    guard dontShowAgain else { return }
                    let firstTime = !tourFinished
                    tourFinished = true
                    if firstTime {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated { DigiInstaller.offerAtLaunch() }
                        }
                    }
                }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !DigiBrand.isClassic {
                DigiTourButton()
            }
        }
        .animation(.easeOut(duration: 0.25), value: showTour)
        .tint(DigiBrand.accent)
        .preferredColorScheme(brandColorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .digiShowTour)) { _ in showTour = true }
        .onAppear {
            DigiAppearance.apply(appearance)
            captureOneMonitor.start()
            if !DigiBrand.isClassic && !tourFinished {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { showTour = true }
            }
        }
    }

    var body: some View {
        brandedRoot
        .onChange(of: captureOneMonitor.offerID) { _, _ in
            considerDetectedSession(captureOneMonitor.candidate)
        }
        .onChange(of: model.syncBusy) { _, busy in
            if !busy, !model.busy, let pending = pendingSessionWhileBusy {
                pendingSessionWhileBusy = nil
                considerDetectedSession(pending)
            }
        }
        .onChange(of: model.busy) { _, busy in
            if !busy, !model.syncBusy, let pending = pendingSessionWhileBusy {
                pendingSessionWhileBusy = nil
                considerDetectedSession(pending)
            }
        }
        .sheet(isPresented: $showSessionProposal) { captureOneProposalSheet }
        .sheet(isPresented: $showBackupBenchmark) { BackupBenchmarkView(workspace: model) }
        .onChange(of: showBackupBenchmark) { _, showing in
            if !showing, !backupBenchmark.isRunning, !model.syncBusy, !model.busy,
               let pending = pendingSessionWhileBusy {
                pendingSessionWhileBusy = nil
                considerDetectedSession(pending)
            }
        }
        .onChange(of: backupBenchmark.isRunning) { _, running in
            if !running {
                if !model.syncBusy, !model.busy, let pending = pendingSessionWhileBusy {
                    pendingSessionWhileBusy = nil
                    considerDetectedSession(pending)
                }
                model.resumeDeferredDashboardScan()
            }
        }
        .onOpenURL { url in model.openProject(url) }
        .frame(minWidth: 680, minHeight: 540)
    }
    private func dashboardTile(_ label: String, value: String, detail: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(label.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol).foregroundStyle(tint)
            }
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(17).frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 13))
    }

    private func dashboardAction(_ title: String, subtitle: String, icon: String, tab: Int) -> some View {
        Button { model.lastTab = tab } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.title2).foregroundStyle(DigiBrand.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private var dashboardSessionButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            captureOneIntegration
            HStack(spacing: 9) {
            Button("Open Session…") { model.chooseRoot() }
            Button("Rescan") { model.scan() }.disabled(model.root == nil || model.busy)
            }
        }
    }

    private var dashboardWorkspaceSaveControl: some View {
        Group {
            if model.projectURL != nil && !model.hasUnsavedChanges {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Workspace saved")
            } else {
                Button { model.saveProject() } label: {
                    Label("Save Workspace", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(model.syncBusy || model.busy)
                .help("Save the current \(DigiBrand.name) workspace")
            }
        }
    }

    var dashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if DigiBrand.isClassic {
            VStack(spacing: 2) {
                Image(nsImage: NSImage(contentsOfFile: Bundle.main.path(forResource: "DigiSuiteLogo", ofType: "png") ?? "") ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 330, maxHeight: 48)
                    .accessibilityLabel("\(DigiBrand.name)")
                Text("(because it's sweet...)")
                    .font(.system(size: 11, weight: .medium, design: .rounded).italic())
                    .foregroundStyle(.secondary)
                Text(model.root?.lastPathComponent ?? "Open a session to see its inventory and backup overview")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 7) {
                    Image(systemName: model.root == nil ? "circle.dashed" : "checkmark.circle.fill")
                    Text(model.root == nil ? "No session" : "Session loaded")
                }
                .font(.caption.bold())
                .foregroundStyle(model.root == nil ? Color.secondary : Color.green)
                if model.hasUnsavedChanges { Text("Unsaved workspace changes").font(.caption).foregroundStyle(.orange) }
                Text(model.projectStatus).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            }
            HStack(spacing: 9) {
                dashboardSessionButtons
                Spacer(minLength: 8)
                dashboardWorkspaceSaveControl
            }
            if let error = model.projectError { Text(error).font(.caption).foregroundStyle(.orange) }
            if let root = model.root { Text(root.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2) }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 195, maximum: 450), spacing: 12)], spacing: 12) {
                dashboardTile("Images", value: model.assets.count.formatted(),
                              detail: "Files in session", symbol: "photo.on.rectangle", tint: .blue)
                dashboardTile("RAW files", value: model.rawCount.formatted(),
                              detail: "Camera originals", symbol: "camera.aperture", tint: .purple)
                dashboardTile("Session size", value: ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file),
                              detail: "Image data inventoried", symbol: "internaldrive", tint: .teal)
                dashboardTile("Backup targets", value: "\(model.backups.count)",
                              detail: model.syncBusy ? "Backup in progress" : "Configured destinations", symbol: "externaldrive", tint: .green)
            }

            SessionCompositionView(summary: model.storageSummary, scanning: model.storageScanning)


            Text("Quick actions").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 285, maximum: 650), spacing: 12)], spacing: 12) {
                dashboardAction("Back Up Session", subtitle: "Copy new and changed files", icon: "externaldrive.badge.plus", tab: 1)
                dashboardAction("Build a Selects List", subtitle: "Ratings, colors, and exports", icon: "checklist", tab: 2)
                dashboardAction("Check Processed Files", subtitle: "Compare originals and outputs", icon: "checkmark.seal", tab: 3)
                dashboardAction("Create Contact Sheet", subtitle: "Generate PDF previews", icon: "square.grid.3x3", tab: 6)
            }
            if !model.backups.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Backup destinations").font(.headline); Spacer(); Button("View Backups") { model.lastTab = 1 }.font(.caption) }
                    ForEach(model.backups, id: \.path) { destination in
                        HStack(spacing: 9) {
                            Image(systemName: "externaldrive").foregroundStyle(.secondary)
                            Text(destination.lastPathComponent).font(.subheadline.bold())
                            Text(destination.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let progress = model.syncProgress.first(where: { $0.destination == destination.path }) {
                                Text(progress.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            } else { Text("Configured").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(18).background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 13))
            }
            Text("Capture One ratings and color tags are available from \(DigiBrand.toolName(2)) after scanning the open Capture One document.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()).monospacedDigit() }
    }
    private func backupDropCard(title: String, path: String?, icon: String,
                                emptyText: String, browse: @escaping () -> Void,
                                drop: @escaping ([URL]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Spacer(minLength: 5)
            Image(systemName: icon).font(.system(size: 29)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            if let path {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline).lineLimit(1)
                Text(path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            } else {
                Text(emptyText).font(.headline).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 5)
            Button(path == nil ? "Browse…" : "Change Folder…", action: browse)
                .disabled(model.syncBusy).frame(maxWidth: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 178)
        .background(DigiBrand.cardFill.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard !model.syncBusy else { return false }
            let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            guard !accepted.isEmpty else { return false }
            for provider in accepted {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else { return }
                    DispatchQueue.main.async { drop([url]) }
                }
            }
            return true
        }
    }

    private func backupETA(_ item: SyncProgress) -> String {
        if item.status == "Paused" || item.status == "Pausing…" { return "Paused" }
        if let eta = item.eta, eta.isFinite, eta >= 0 {
            let seconds = Int(min(eta, Double(Int.max / 2)))
            if seconds >= 3600 { return String(format: "ETA %dh %02dm", seconds / 3600, (seconds % 3600) / 60) }
            return String(format: "ETA %dm %02ds", seconds / 60, seconds % 60)
        }
        if item.status == "Up to date" { return "Complete" }
        if item.status == "Paused" { return "Paused" }
        if item.status.hasPrefix("Error") || item.status.hasPrefix("Completed with errors") { return "Error" }
        if item.status.hasPrefix("Stopped") { return "Stopped" }
        return "ETA —"
    }

    private func backupProgressPanel(_ item: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.status).font(.caption).lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 17, alignment: .leading)
                .help(item.status)
            ProgressView(value: item.totalBytes > 0
                         ? min(1, Double(item.completedBytes) / Double(item.totalBytes))
                         : (item.status == "Up to date" ? 1 : 0))
            HStack {
                Text("\(item.completedFiles)/\(item.totalFiles) files")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file))
            }.font(.caption2).monospacedDigit()
            HStack {
                Text(item.status == "Up to date" ? "Complete · Size/date check" :
                     (item.status.hasPrefix("Stopped") ? "Stopped" :
                     (item.status.hasPrefix("Error") || item.status.hasPrefix("Completed with errors")
                      ? "Finished with errors" :
                      (item.bytesPerSecond > 0
                       ? String(format: "%.1f MB/s", item.bytesPerSecond / 1_000_000)
                       : "Calculating speed…"))))
            }.font(.caption2).foregroundStyle(.secondary)
            if item.errorCount > 0 {
                Text("\(item.errorCount) errors").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(height: 112, alignment: .topLeading)
        .background(.quaternary.opacity(0.25))
        .cornerRadius(7)
    }

    // MARK: Version 16 destination detail

    private func destinationFinished(_ item: SyncProgress) -> Bool {
        item.status == DigiFastBackupEngine.completeStatus || item.status.hasPrefix("Stopped") ||
        item.status.hasPrefix("Error") || item.status.hasPrefix("Completed with errors") ||
        item.status.hasPrefix("Skipped") || item.status == "Source Unavailable"
    }

    private func destinationDisplayStatus(_ item: SyncProgress) -> String {
        if destinationFinished(item) { return item.status }
        if model.stoppingDestinations.contains(item.destination) { return "Stopping after the current file…" }
        if item.status == "Paused" { return "Paused" }
        if model.destinationIsPaused(item.destination) || item.status == "Pausing…" {
            return "Pausing… finishing the current file"
        }
        return item.status
    }

    private func mbps(_ value: Double) -> String { String(format: "%.1f MB/s", value) }

    private func currentSpeed(_ item: SyncProgress) -> Double {
        if item.status == "Paused" { return 0 }
        if item.liveMBps > 0 { return item.liveMBps }
        return item.speedSamples.last ?? 0
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    @ViewBuilder private func destinationControlButtons(_ path: String) -> some View {
        if model.stoppingDestinations.contains(path) {
            Label("Stopping…", systemImage: "stop.circle").font(.callout).foregroundStyle(.secondary)
        } else {
            let paused: Bool = model.pausedDestinations.contains(path)
            Button {
                if paused { model.resumeDestination(path) } else { model.pauseDestination(path) }
            } label: {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
            }
            .disabled(model.syncPaused)
            .help(model.syncPaused ? "Everything is paused. Use Resume All at the top." : (paused ? "Resume this drive" : "Pause this drive after the current chunk. Other drives keep going."))
            Button { model.stopDestination(path) } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(.red)
            .help("Stop this drive safely. Copied files are kept; other drives keep going.")
        }
    }

    private func freeSpaceText(_ free: Int64, total: Int64?) -> String {
        var text: String = bytes(free) + " free"
        if let total { text += " of " + bytes(total) }
        return text
    }

    private func driveHelp(_ status: DigiDriveStatus) -> String {
        guard let speed = status.linkSpeed else {
            return "This drive did not appear in the USB device list (it may be Thunderbolt, internal or a network volume)."
        }
        var text = "macOS reports: " + speed
        if let device = status.deviceName { text += " (" + device + ")" }
        return text
    }

    @ViewBuilder private func destinationDriveLine(_ path: String) -> some View {
        if let status = model.driveStatus[path], !status.isConnected {
            Label("Not connected", systemImage: "externaldrive.badge.xmark")
                .font(.caption).foregroundStyle(.secondary)
        } else if let status = model.driveStatus[path] {
            HStack(spacing: 5) {
                Image(systemName: status.isSlowLink ? "exclamationmark.triangle.fill" : "bolt.horizontal.circle")
                    .foregroundStyle(status.isSlowLink ? Color.orange : Color.secondary)
                Text(status.linkMbps == nil ? "Link speed not reported" : "USB " + status.linkLabel)
                if let free = status.availableBytes {
                    Text("·")
                    Text(freeSpaceText(free, total: status.totalBytes))
                }
                if let format = status.formatName {
                    Text("·")
                    Text(format)
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .help(driveHelp(status))
            ForEach(status.warnings, id: \.self) { warning in
                Text(warning).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if model.driveCheckRunning {
            Text("Checking connection…").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func destinationSpeedDetail(_ item: SyncProgress) -> some View {
        if item.totalBytes > 0 || !item.speedSamples.isEmpty {
            let now: Double = currentSpeed(item)
            let remaining: Int64 = max(Int64(0), item.totalBytes - item.completedBytes)
            let running: Bool = model.syncBusy && !destinationFinished(item)
            HStack(spacing: 8) {
                if running { Text("Now " + mbps(now)) }
                Text("Avg " + mbps(item.bytesPerSecond / 1_000_000))
                Text("Peak " + mbps(item.peakMBps))
                Spacer(minLength: 4)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            DigiSpeedSparkline(samples: item.speedSamples, peak: item.peakMBps, height: 70)
            HStack(spacing: 8) {
                Text(bytes(item.completedBytes) + " of " + bytes(item.totalBytes))
                Spacer(minLength: 4)
                Text(bytes(remaining) + " remaining")
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: Version 18 Backups layout

    private func backupSummaryText() -> String {
        let total: Int64 = model.syncProgress.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done: Int64 = model.syncProgress.reduce(Int64(0)) { $0 + $1.completedBytes }
        let files: Int = model.syncProgress.reduce(0) { $0 + $1.completedFiles }
        let totalFiles: Int = model.syncProgress.reduce(0) { $0 + $1.totalFiles }
        let averageBytes: Double = model.syncProgress.reduce(0.0) { $0 + $1.bytesPerSecond }
        let live: Double = model.syncProgress.reduce(0.0) { $0 + $1.liveMBps }
        var parts: [String] = []
        parts.append(bytes(done) + " of " + bytes(total))
        parts.append("\(files) of \(totalFiles) files")
        parts.append(String(format: "Avg %.0f MB/s", averageBytes / 1_000_000))
        if model.syncBusy {
            parts.append(String(format: "Now %.0f MB/s", live))
            parts.append("ETA " + overallBackupETA)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var backupActionButtons: some View {
        if model.syncBusy {
            Button {
                model.togglePauseAll()
            } label: {
                Label(model.everythingPaused ? "Resume All" : "Pause All", systemImage: model.everythingPaused ? "play.fill" : "pause.fill")
            }
            Button { model.stopSync() } label: { Label("Stop All", systemImage: "stop.fill") }
                .tint(.red)
        } else {
            Button("Trial Sync (Preview)") { model.previewSync() }
                .disabled(model.syncSource == nil || model.backups.isEmpty || backupBenchmark.isRunning)
            Button(model.driveCheckRunning ? "Checking Drives…" : "Start Backup") { model.requestStartSync() }
                .disabled(model.syncSource == nil || model.backups.isEmpty || backupBenchmark.isRunning || model.driveCheckRunning)
                .buttonStyle(.borderedProminent)
        }
    }

    /// v1.26: the checksum setting, always visible on the backup screen.
    private var verifyModeMenu: some View {
        Menu {
            Picker("Checksums", selection: $model.verifyMode) {
                Text("Full verify: read every copy back (safest)").tag("full")
                Text("Quick: checksum originals, don't read copies back").tag("quick")
                Text("Off: size and date only").tag("off")
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.verifyModeTitle, systemImage: model.verifyMode == "off" ? "seal" : "checkmark.seal")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.syncBusy)
        .help("How each copy is checked. Change it before a backup starts.")
    }

    private var verifyModePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Checksums", selection: $model.verifyMode) {
                Text("Full verify").tag("full")
                Text("Quick").tag("quick")
                Text("Off").tag("off")
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(model.syncBusy)
            Text(verifyModeExplanation)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var verifyModeExplanation: String {
        switch model.verifyMode {
        case "quick":
            return "Each original gets an xxHash64 checksum while it copies, about as fast as no checksums. Copies aren't read back, so a bad write wouldn't be caught. Report and checksum list go in " + DigiFastBackupEngine.reportsName + " on each drive."
        case "off":
            return "Files are matched by size and date only. No report or checksum list. Use Check > Deep Verify for a content check."
        default:
            return "Each copy is read back from the drive and its xxHash64 checksum compared with the original before it's kept. Slower, the safest. Report and checksum list go in " + DigiFastBackupEngine.reportsName + " on each drive."
        }
    }

    @ViewBuilder private var backupSummaryLine: some View {
        if model.syncProgress.isEmpty {
            Text("Ready to back up your session").foregroundStyle(.secondary)
        } else {
            Text(backupSummaryText())
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var backupOverallFraction: Double {
        let total: Int64 = model.syncProgress.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done: Int64 = model.syncProgress.reduce(Int64(0)) { $0 + $1.completedBytes }
        guard total > 0 else { return 0 }
        return min(1, Double(done) / Double(total))
    }

    private var backupControlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    backupActionButtons
                    backupSummaryLine.padding(.leading, 6)
                    Spacer(minLength: 8)
                    verifyModeMenu
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        backupActionButtons
                        Spacer(minLength: 0)
                    }
                    backupSummaryLine
                }
            }
            if model.syncBusy && !model.syncProgress.isEmpty {
                ProgressView(value: backupOverallFraction).controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backupCardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private var backupSourceRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            Text("SOURCE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(model.syncSource?.lastPathComponent ?? "No source selected")
                .font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(model.syncSource?.path ?? "")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(model.syncSource?.path ?? "")
            Spacer(minLength: 6)
            Button(model.syncSource == nil ? "Choose Source…" : "Change…") { model.chooseSyncSource() }
                .controlSize(.small).disabled(model.syncBusy)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backupCardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var backupDestinationArea: some View {
        if model.backups.isEmpty {
            backupCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No backup destinations").font(.headline)
                    Text("Use Discover Drives or Add below.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if model.backups.count == 1, let only = model.backups.first {
            destinationCard(only)
        } else {
            // Side by side when the window is wide enough; stacked otherwise.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 430), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                ForEach(model.backups, id: \.path) { backup in
                    destinationCard(backup)
                }
            }
            .onAppear { model.refreshArchiveInfo() }
            .onChange(of: model.backups) { _, _ in model.refreshArchiveInfo() }
        }
    }

    /// The drive's name ("WolkPhoto2TB") for a destination folder.
    private func driveTitle(for backup: URL) -> String {
        if let volume = model.driveStatus[backup.path]?.volumePath, volume != "/" {
            return URL(fileURLWithPath: volume).lastPathComponent
        }
        let parts = backup.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return parts[2] }
        return backup.lastPathComponent
    }

    private func destinationProgress(_ backup: URL) -> SyncProgress? {
        model.syncProgress.first(where: { $0.destination == backup.path })
    }

    private func destinationCard(_ backup: URL) -> some View {
        let progress: SyncProgress? = destinationProgress(backup)
        return backupCard {
            VStack(alignment: .leading, spacing: 8) {
                destinationHeader(backup, progress: progress)
                destinationDriveLine(backup.path)
                if let last = model.lastBackups[backup.path], !model.syncBusy || progress == nil {
                    Text(lastBackupText(last)).font(.caption).foregroundStyle(.secondary)
                }
                if let progress {
                    destinationProgressBody(progress)
                }
                archiveLine(backup, copying: driveIsCopying(backup))
            }
        }
    }

    /// v1.25: how much the archive on this drive holds, with a Clear button.
    @ViewBuilder private func archiveLine(_ backup: URL, copying: Bool) -> some View {
        let measuring: Bool = model.archiveMeasuring.contains(backup.path)
        if let info = model.archiveInfo[backup.path], !info.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                Text("Archive: " + bytes(info.bytes) + " of older versions from \(info.runs) backup(s)")
                    .lineLimit(1)
                    .help("Earlier versions of changed files and files removed from the session, in " + DigiFastBackupEngine.archiveName + " on this drive.")
                Spacer(minLength: 4)
                if measuring {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Clear…") { model.confirmClearArchive(backup) }
                        .disabled(copying)
                        .help("Delete the archive on this drive. You'll be asked to confirm.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if measuring {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Measuring the archive…")
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60) }
        return String(format: "%dm %02ds", total / 60, total % 60)
    }

    private func lastBackupText(_ last: DigiLastBackup) -> String {
        let calendar = Calendar.current
        let time: String = last.date.formatted(date: .omitted, time: .shortened)
        let when: String
        if calendar.isDateInToday(last.date) { when = "today " + time }
        else if calendar.isDateInYesterday(last.date) { when = "yesterday " + time }
        else { when = last.date.formatted(date: .abbreviated, time: .shortened) }
        var text: String = "Last backup: " + when
        if last.copiedFiles > 0 {
            text += " · \(last.copiedFiles) files, " + bytes(last.copiedBytes) + " in " + durationText(last.seconds)
            if last.averageMBps > 1 { text += String(format: " at %.0f MB/s", last.averageMBps) }
        } else {
            text += " · already up to date"
        }
        return text
    }

    private func isExternal(_ backup: URL) -> Bool {
        let parts = backup.standardizedFileURL.pathComponents
        return parts.count >= 3 && parts[1] == "Volumes"
    }

    private func isEjecting(_ backup: URL) -> Bool {
        let parts = backup.standardizedFileURL.pathComponents
        guard parts.count >= 3 else { return false }
        return model.ejectingVolumes.contains("/Volumes/" + parts[2])
    }

    @ViewBuilder private func destinationHeader(_ backup: URL, progress: SyncProgress?) -> some View {
        let title: String = driveTitle(for: backup)
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "externaldrive.fill").font(.title3).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                Text(backup.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(backup.path)
            }
            Spacer(minLength: 6)
            if let progress, model.syncBusy, !destinationFinished(progress) {
                destinationControlButtons(backup.path)
            } else {
                if isExternal(backup) && model.driveStatus[backup.path]?.isConnected != false {
                    if isEjecting(backup) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { model.ejectDrive(for: backup) } label: {
                            Label("Eject", systemImage: "eject.fill")
                        }
                        .disabled(model.syncBusy)
                        .help("Eject this drive so it is safe to unplug")
                    }
                }
                Button { editingBackupDestination = backup.path } label: {
                    Image(systemName: "slider.horizontal.3")
                }.buttonStyle(.borderless).disabled(model.syncBusy).help("Destination exclusions")
                Button { model.backups.removeAll { $0 == backup }; model.syncPreviewReady = false } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.borderless).disabled(driveIsCopying(backup)).help("Remove destination (nothing on the drive is deleted)")
            }
        }
    }

    private func progressFraction(_ item: SyncProgress) -> Double {
        if item.totalBytes > 0 { return min(1, Double(item.completedBytes) / Double(item.totalBytes)) }
        return item.status == DigiFastBackupEngine.completeStatus ? 1 : 0
    }

    @ViewBuilder private func destinationProgressBody(_ progress: SyncProgress) -> some View {
        let paused: Bool = model.destinationIsPaused(progress.destination)
        ProgressView(value: progressFraction(progress))
            .tint(paused ? Color.orange : DigiBrand.accent)
        HStack(spacing: 8) {
            if progress.status.hasPrefix("Error") {
                Text(progress.status).foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(destinationDisplayStatus(progress))
                    .foregroundStyle(paused && progress.status != "Paused" ? Color.orange : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(progress.status)
            }
            Spacer(minLength: 4)
            Text(backupETA(progress)).monospacedDigit()
        }
        .font(.caption).foregroundStyle(.secondary)
        destinationSpeedDetail(progress)
        HStack {
            if progress.verifyOn {
                let word: String = progress.readBackOn ? "verified" : "checksummed"
                Label("\(progress.verifiedFiles) of \(progress.completedFiles) copied " + word + " · \(progress.unchangedFiles) unchanged", systemImage: "checkmark.seal")
                    .help(progress.readBackOn ? "Each copy is read back from the drive and its xxHash64 checksum compared with the original." : "Quick: each original's xxHash64 checksum was recorded while it copied. Copies weren't read back.")
            } else {
                Text("\(progress.completedFiles) copied · \(progress.unchangedFiles) unchanged")
            }
            Spacer(minLength: 4)
            Text(String(format: "Elapsed %dm %02ds", Int(progress.elapsedSeconds) / 60, Int(progress.elapsedSeconds) % 60))
                .monospacedDigit()
            Button(showBackupDetails ? "Hide Details" : "Details") { showBackupDetails.toggle() }
                .buttonStyle(.borderless).font(.caption)
        }
        .font(.caption).foregroundStyle(.secondary)
        if showBackupDetails && progress.elapsedSeconds > 0 {
            Text(String(format: "Total %.1fs · Copy wait %.1fs · Checks %.1fs · Finalize %.1fs · Plan %.1fs · UI %.1fs", progress.elapsedSeconds, progress.copySeconds, progress.validationSeconds, progress.finalizeSeconds, progress.planSeconds, progress.reportSeconds))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if showBackupDetails && !progress.engineNote.isEmpty {
            Text(progress.engineNote)
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if progress.errorCount > 0 {
            Text("\(progress.errorCount) errors").font(.caption2).foregroundStyle(.orange)
        }
        if !progress.archiveNote.isEmpty {
            Text(progress.archiveNote).font(.caption).foregroundStyle(.secondary)
        }
        if !progress.reportPath.isEmpty {
            HStack(spacing: 8) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: progress.reportPath)) } label: {
                    Label("Open Backup Report", systemImage: "doc.text")
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: progress.reportPath)])
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
    }

    // MARK: Connected drives (version 18)

    private func destinationOnDrive(_ drive: WrapModel.DiscoveredBackupDrive) -> URL? {
        let volumePath: String = drive.volume.standardizedFileURL.path
        return model.backups.first { $0.standardizedFileURL.path.hasPrefix(volumePath + "/") }
    }

    private func driveIsCopying(_ destination: URL) -> Bool {
        guard model.syncBusy, let progress = destinationProgress(destination) else { return false }
        return !destinationFinished(progress)
    }

    private func connectedDriveSubtitle(_ drive: WrapModel.DiscoveredBackupDrive, inUse: URL?) -> String {
        if let inUse { return "Backing up to " + inUse.lastPathComponent }
        if let match = drive.matchingFolder { return "Session folder found: " + match.lastPathComponent }
        return "A folder named " + drive.suggestedFolder.lastPathComponent + " will be created on this drive"
    }

    @ViewBuilder private func connectedDriveRow(_ drive: WrapModel.DiscoveredBackupDrive) -> some View {
        let inUse: URL? = destinationOnDrive(drive)
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(inUse == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.volume.lastPathComponent).font(.subheadline.weight(.semibold))
                Text(connectedDriveSubtitle(drive, inUse: inUse)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let inUse {
                Label("In use", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                Button("Stop Using") {
                    model.backups.removeAll { $0 == inUse }
                    model.syncPreviewReady = false
                }
                .disabled(driveIsCopying(inUse))
                .help(driveIsCopying(inUse) ? "This drive is copying. Use Stop on its card first." : "Removes this drive from the backup. Nothing on the drive is deleted.")
            } else {
                Button("Use This Drive") {
                    if let match = drive.matchingFolder { model.addDiscoveredBackupDestination(match) }
                    else { model.createDiscoveredBackupFolder(on: drive.volume) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.syncBusy && model.syncSource == nil)
                .help(model.syncBusy ? "Adds this drive and starts copying to it right away." : "Adds this drive to the backup.")
            }
        }
        .padding(.vertical, 2)
    }

    private var connectedDrivesCard: some View {
        backupCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Connected Drives").font(.headline)
                    Spacer()
                    Button { model.discoverExternalBackupFolders() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.disabled(model.discoveredBackupScanning)
                    Button { model.addBackup() } label: { Label("Add Folder…", systemImage: "folder.badge.plus") }
                }
                if model.discoveredBackupScanning {
                    ProgressView("Looking for drives…").controlSize(.small)
                } else if model.discoveredBackupDrives.isEmpty {
                    Text(model.discoveredBackupMessage).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.discoveredBackupDrives) { drive in
                    connectedDriveRow(drive)
                    if drive.id != model.discoveredBackupDrives.last?.id { Divider() }
                }
            }
        }
    }

    private var backupHeaderStatus: String {
        if model.everythingPaused { return model.backupPauseConfirmed ? "Paused" : "Pausing…" }
        let paused: Int = model.individuallyPausedCount
        if paused > 0 { return "Backing up · \(paused) paused" }
        return "Backing up"
    }

    private var overallBackupETA: String {
        guard model.syncBusy else { return "Not running" }
        // Queued or starting drives have no estimate yet; leave them out.
        let active = model.syncProgress.filter {
            $0.status != "Up to date" && !$0.status.hasPrefix("Stopped") &&
            !$0.status.hasPrefix("Error") && !$0.status.hasPrefix("Completed with errors") &&
            !$0.status.hasPrefix("Queued") && $0.status != "Starting…" && !$0.status.hasPrefix("Skipped") &&
            $0.status != "Source Unavailable"
        }
        if model.everythingPaused { return model.backupPauseConfirmed ? "Paused" : "Pausing…" }
        if active.isEmpty { return "Finishing…" }
        let estimates = active.compactMap { $0.eta }.filter { $0.isFinite && $0 >= 0 }
        guard estimates.count == active.count, let longest = estimates.max() else { return "Calculating…" }
        let seconds = Int(min(longest, Double(Int.max / 2)))
        if seconds >= 3600 { return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60) }
        return String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }

    private func compactBackupFolder(title: String, path: String?, icon: String,
                                     browse: @escaping () -> Void,
                                     drop: @escaping ([URL]) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
                Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose or drop a folder")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if let path { Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(path) }
            }
            Spacer(minLength: 6)
            Button(path == nil ? "Choose…" : "Change…", action: browse)
                .disabled(model.syncBusy).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DigiBrand.cardFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5])))
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard !model.syncBusy else { return false }
            let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            guard !accepted.isEmpty else { return false }
            for provider in accepted {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return }
                    DispatchQueue.main.async { drop([url]) }
                }
            }
            return true
        }
    }

    private var backupCardBackground: Color { DigiBrand.cardFill.opacity(0.55) }

    private func backupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backupCardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    var backups: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Backup Sync").font(.title2.bold())
                    if let source = model.syncSource {
                        Text(source.lastPathComponent).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.syncBusy {
                    Label(backupHeaderStatus, systemImage: model.everythingPaused ? "pause.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(model.everythingPaused ? .orange : .green)
                        .font(.subheadline.weight(.semibold))
                }
            }

            // Version 18 layout: slim control bar, slim source row, and the
            // space goes to one large card per destination drive.
            backupControlBar
            backupSourceRow
            backupDestinationArea

            connectedDrivesCard

            backupCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Automatic Backups").font(.headline)
                            Text(model.scheduleEnabled ? "Every \(model.scheduleMinutes) minutes · While \(DigiBrand.name) is open" : "Not scheduled")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Enabled", isOn: $model.scheduleEnabled).labelsHidden()
                        Text(model.scheduleEnabled ? "Enabled" : "Disabled")
                            .font(.caption.weight(.medium)).foregroundStyle(model.scheduleEnabled ? .green : .secondary)
                    }
                    Divider()
                    HStack {
                        Text("Archive changed and removed files").font(.subheadline)
                        Spacer()
                        Text(model.archiveChanged && model.archiveRemoved ? "Enabled" : (model.archiveChanged || model.archiveRemoved ? "Partial" : "Disabled"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Configure schedule and archive options") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Run every")
                                TextField("Minutes", value: $model.scheduleMinutes, format: .number)
                                    .frame(width: 58).textFieldStyle(.roundedBorder)
                                Text("minutes")
                                Spacer()
                                Button("Back Up Now") { model.requestStartSync() }
                                    .disabled(model.syncBusy || model.driveCheckRunning || model.syncSource == nil || model.backups.isEmpty)
                            }.disabled(!model.scheduleEnabled)
                            Text(model.scheduleStatus).font(.caption).foregroundStyle(.secondary)
                            if let next = model.scheduleNextRun, model.scheduleEnabled {
                                Text("Next run: \(next.formatted(date: .omitted, time: .shortened))").font(.caption)
                            }
                            if let last = model.scheduleLastRun {
                                Text("Last run: \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                            }
                            ForEach(model.backups, id: \.path) { destination in
                                if let result = model.scheduleLastResults[destination.path] {
                                    HStack {
                                        Text(destination.lastPathComponent).lineLimit(1)
                                        Spacer()
                                        Text(result).lineLimit(1)
                                    }.font(.caption2)
                                }
                            }
                            Toggle("Archive previous version when a source file changes", isOn: $model.archiveChanged).disabled(model.syncBusy)
                            Toggle("Archive tracked files removed from the source", isOn: $model.archiveRemoved).disabled(model.syncBusy)
                            HStack(spacing: 6) {
                                Toggle("Clear the oldest archived copies when a drive has less than", isOn: $model.archiveAutoTrim)
                                TextField("GB", value: $model.archiveAutoTrimGB, format: .number)
                                    .frame(width: 54).textFieldStyle(.roundedBorder)
                                    .disabled(!model.archiveAutoTrim)
                                Text("GB free")
                            }
                            .disabled(model.syncBusy)
                            Text("Runs before and after each backup. Deletes the oldest backup's archived copies first, one backup at a time, only until the drive has that much free. Your current backup is never touched.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                            verifyModePicker
                            Toggle("Go easy on the disk while Capture One is open", isOn: $model.gentleWhileCapture).disabled(model.syncBusy)
                            Text("Backups give Capture One first turn at the disk so captures keep landing fast. Backups may run slower while Capture One is open.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("New and changed files are staged before replacement. Full content checks any time: \(DigiBrand.toolName(7)) > Deep Verify.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                }
            }
            .sheet(item: Binding<BackupDestinationSheet?>(
                get: { editingBackupDestination.map { BackupDestinationSheet(path: $0) } },
                set: { editingBackupDestination = $0?.path }
            )) { item in
                BackupFilterEditor(source: model.syncSource, destination: item.path,
                    filter: Binding(get: { model.backupFilters[item.path] ?? BackupFilter() },
                                    set: { model.backupFilters[item.path] = $0; model.syncPreviewReady = false }),
                    copyToAll: { filter in
                        for dest in model.backups { model.backupFilters[dest.path] = filter }
                        model.syncPreviewReady = false
                    })
            }
            Divider()
            if model.syncPreviewReady {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Trial Sync Results").font(.headline)
                    ForEach(model.syncPreview) { preview in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(URL(fileURLWithPath: preview.destination).lastPathComponent).font(.headline)
                            if let error = preview.error {
                                Text("Preview error: " + error).foregroundStyle(.red)
                            } else {
                                Text("\(preview.newFiles.count) new, \(preview.modifiedFiles.count) modified, \(preview.removedFiles.count) removed from source, \(preview.unchanged) unchanged · " + ByteCountFormatter.string(fromByteCount: preview.transferBytes, countStyle: .file) + " to transfer")
                                    .font(.caption).textSelection(.enabled)
                                Text("RAW images: \(preview.rawNew) new · \(preview.rawModified) modified · \(preview.rawRemoved) removed (other changes may be Capture One settings, previews, or database files)")
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("New files (\(preview.newFiles.count))") {
                                    ForEach(preview.newFiles, id: \.self) { file in Text(file).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                }
                                DisclosureGroup("Modified files (\(preview.modifiedFiles.count))" + (model.archiveChanged ? " · previous versions archived" : "")) {
                                    ForEach(preview.modifiedFiles, id: \.self) { file in Text(file).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                }
                                DisclosureGroup("Removed from source (\(preview.removedFiles.count))" + (model.archiveRemoved ? " · to archive" : " · kept on destination")) {
                                    ForEach(preview.removedFiles, id: \.self) { file in Text(file).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                }
                                DisclosureGroup("Unchanged (\(preview.unchanged))") {
                                    Text("Unchanged files are skipped during sync. Their names are omitted to keep this preview fast.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.25))
                        .cornerRadius(8)
                    }
                }
            }
            Text(model.syncMessage).font(.caption).foregroundStyle(.secondary)

        }
        .onAppear {
            if !model.syncBusy && !model.driveCheckRunning { model.refreshDriveStatus() }
            if model.discoveredBackupDrives.isEmpty && !model.discoveredBackupScanning && !model.syncBusy {
                model.discoverExternalBackupFolders()
            }
        }
        .onChange(of: model.backups) { _, _ in
            model.refreshDriveStatus()
            model.autoSaveWorkspace()
        }
        .onChange(of: model.backupFilters) { _, _ in model.autoSaveWorkspace() }
        .onChange(of: model.archiveChanged) { _, _ in model.autoSaveWorkspace() }
        .onChange(of: model.archiveRemoved) { _, _ in model.autoSaveWorkspace() }
    }
    var selects: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Selects File List").font(.title2.bold())
            Text("Choose any parent folder on \(DigiBrand.toolName(0)). Subfolders are scanned recursively, regardless of Capture One folder names.").foregroundStyle(.secondary)
            Picker("Files to include", selection: $model.selectsFileType) { Text("RAW only").tag("RAW"); Text("JPEG only").tag("JPEG"); Text("RAW + JPEG").tag("Both") }.pickerStyle(.segmented)
            Text("RAW: ARW, RAF, CR3, IIQ, NEF, DNG and more. JPEG: JPG and JPEG. Capture One caches and settings are ignored.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Scan Open Capture One Session") { model.scanCaptureOne() }.disabled(model.assets.isEmpty || model.busy)
                if model.busy { Button("Cancel Scan") { model.cancelCaptureScan() } }
            }
            Button("Import Ratings & Color Tags CSV / TSV") { model.importMetadata() }.disabled(model.assets.isEmpty)
            Text("Capture One metadata is matched by exact file path. Picked variants determine ratings and tags. Green = 4; unknown colors display as Tag N.").font(.caption).foregroundStyle(.secondary)
            Text("Star ratings").font(.headline)
            HStack { ForEach(0...5, id: \.self) { n in Toggle(n == 0 ? "0" : "\(n) ★", isOn: Binding(get: { model.selectedRatings.contains(n) }, set: { if $0 { model.selectedRatings.insert(n) } else { model.selectedRatings.remove(n) } })).toggleStyle(.button) } }
            Text("Color tags").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(model.tags + Array(Set(model.assets.compactMap { $0.tag }.filter { $0.hasPrefix("Tag ") })).sorted(), id: \.self) { tag in
                    Toggle(tag, isOn: Binding(get: { model.selectedTags.contains(tag) }, set: { if $0 { model.selectedTags.insert(tag) } else { model.selectedTags.remove(tag) } })).toggleStyle(.button)
                }
            }
            Picker("Combine filters", selection: $model.matchingRule) { Text("AND").tag("AND"); Text("OR").tag("OR") }.pickerStyle(.segmented)
            Picker("Export format", selection: $model.outputFormat) { Text("Choose format").tag(""); Text("CSV").tag("CSV"); Text("TXT").tag("TXT"); Text("Both").tag("Both") }.pickerStyle(.segmented)
            Toggle("Include filename extension", isOn: $model.includeExtension)
            HStack { Text("Matching files: \(model.selects.count)").bold(); Spacer(); Button("Clear Filters") { model.selectedRatings = []; model.selectedTags = []; model.matchingRule = "OR"; model.outputFormat = "" }; Button("Export File List") { model.exportSelects() }.disabled(model.assets.isEmpty || model.outputFormat.isEmpty) }
            if model.unmatchedVariants > 0 || model.ambiguousFiles > 0 { Text("Scan diagnostics: \(model.unmatchedVariants) Capture One paths outside the selected folder; \(model.ambiguousFiles) files have conflicting picked-variant metadata. Review before delivery.").foregroundStyle(.orange).font(.caption) }
            if !model.variantConflicts.isEmpty {
                DisclosureGroup("Review \(model.variantConflicts.count) picked-variant conflicts (excluded from selects)") {
                    ForEach(model.variantConflicts) { conflict in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conflict.filename).font(.subheadline.bold()).textSelection(.enabled)
                            Text("Variants: " + conflict.variants.joined(separator: " | ")).font(.caption).textSelection(.enabled)
                            ForEach(conflict.paths, id: \.self) { path in
                                Text(path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }
            if model.taggedCount == 0 && (!model.selectedRatings.isEmpty || !model.selectedTags.isEmpty) { Text("No rating/color metadata has been scanned or imported. Filtered lists may be empty or incomplete.").foregroundStyle(.orange).font(.caption) }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Matching File Preview").font(.headline)
                Text("Grouped by selected ratings and colors. A file may appear in more than one group, but is exported only once.").font(.caption).foregroundStyle(.secondary)
                if model.assets.isEmpty {
                    Text("Choose a folder and scan Capture One to preview filenames.").foregroundStyle(.secondary)
                } else if model.selects.isEmpty {
                    Text("No files match the current filters.").foregroundStyle(.secondary)
                } else {
                    if model.selectedRatings.isEmpty && model.selectedTags.isEmpty {
                        previewGroup("All matching files", files: model.selects)
                    } else {
                        ForEach(model.selectedRatings.sorted(), id: \.self) { rating in
                            previewGroup(rating == 0 ? "Unrated (0 stars)" : "\(rating) Stars", files: model.selects.filter { $0.rating == rating })
                        }
                        ForEach(model.tags.filter { model.selectedTags.contains($0) } + model.selectedTags.filter { !model.tags.contains($0) }.sorted(), id: \.self) { tag in
                            previewGroup("\(tag) Tag", files: model.selects.filter { ($0.tag ?? "None") == tag })
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder
    func previewGroup(_ title: String, files: [Asset]) -> some View {
        DisclosureGroup("\(title) (\(files.count))") {
            if files.isEmpty {
                Text("No matching files in this group.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }) { asset in
                        Text(model.includeExtension ? asset.url.lastPathComponent : asset.url.deletingPathExtension().lastPathComponent)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .help(asset.url.path)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    // v1.7: the five apps use their own card color, so the light theme (Proof)
    // no longer shows dark cards with dark text.
    private var processingCardColor: Color {
        DigiBrand.isClassic ? Color(red: 0.115, green: 0.115, blue: 0.12) : DigiBrand.cardFill
    }

    private func processingFolderCard(title: String, path: URL?, isCustom: Bool, change: @escaping () -> Void, reset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: title == "Capture Folder" ? "camera.aperture" : "folder.badge.gearshape")
                    .foregroundStyle(.blue)
                Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // v1.7: a clear badge saying whether the app picked this folder.
                Label(isCustom ? "Chosen by you" : "Auto-selected", systemImage: isCustom ? "hand.point.up.left" : "wand.and.stars")
                    .font(.caption.bold())
                    .foregroundStyle(isCustom ? Color.orange : Color.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background((isCustom ? Color.orange : Color.green).opacity(0.15), in: Capsule())
            }
            HStack(spacing: 8) {
                Image(systemName: path == nil ? "questionmark.folder" : "folder.fill")
                    .font(.title3)
                    .foregroundStyle(path == nil ? Color.orange : DigiBrand.accent)
                Text(path?.lastPathComponent ?? "Folder not found")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
            }
            Text(path?.path ?? "Choose a folder to continue")
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Change Folder…", action: change).buttonStyle(.bordered)
                if isCustom {
                    Button("Use Default", action: reset).buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(processingCardColor, in: RoundedRectangle(cornerRadius: 16))
    }

    private func processingMetric(_ label: String, value: Int, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value.formatted()).font(.system(size: 29, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var delivery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Processing Completeness").font(.title.bold())
                    Text("Compare camera originals in Capture against JPEGs in Output. Folder paths are automatically selected from the active session.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        processingFolderCard(title: "Capture Folder", path: model.qcCaptureFolder, isCustom: model.qcCaptureOverride, change: { model.chooseQCCapture() }, reset: { model.resetQCCaptureToDefault() })
                        processingFolderCard(title: "Output Folder", path: model.deliveryFolder, isCustom: model.qcExportOverride, change: { model.chooseDelivery() }, reset: { model.resetQCExportToDefault() })
                    }
                    VStack(spacing: 14) {
                        processingFolderCard(title: "Capture Folder", path: model.qcCaptureFolder, isCustom: model.qcCaptureOverride, change: { model.chooseQCCapture() }, reset: { model.resetQCCaptureToDefault() })
                        processingFolderCard(title: "Output Folder", path: model.deliveryFolder, isCustom: model.qcExportOverride, change: { model.chooseDelivery() }, reset: { model.resetQCExportToDefault() })
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        model.qcDelivery()
                    } label: {
                        Label("Check Processing Completeness", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.qcCaptureFolder == nil || model.deliveryFolder == nil || model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }

                if model.qcHasRun {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack {
                            Text("Processing Results").font(.title3.bold())
                            Spacer()
                            Label(model.qcMatchedCount == model.qcRawCount ? "All matched" : "\(model.qcRawCount - model.qcMatchedCount) missing",
                                  systemImage: model.qcMatchedCount == model.qcRawCount ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(model.qcMatchedCount == model.qcRawCount ? .green : .orange)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            processingMetric("RAW Files", value: model.qcRawCount)
                            processingMetric("Matched", value: model.qcMatchedCount)
                            processingMetric("Missing JPEGs", value: max(0, model.qcRawCount - model.qcMatchedCount), tint: model.qcRawCount == model.qcMatchedCount ? .green : .orange)
                            processingMetric("JPEGs Scanned", value: model.qcJPEGCount)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.orange.opacity(0.65))
                                Capsule().fill(Color.green)
                                    .frame(width: geometry.size.width * (model.qcRawCount > 0 ? CGFloat(model.qcMatchedCount) / CGFloat(model.qcRawCount) : 0))
                            }
                        }
                        .frame(height: 9)
                        if model.qcGroups.isEmpty {
                            Label("No folders contain unprocessed RAW files.", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        } else {
                            Text("Folders with unprocessed images (\(model.qcGroups.count))").font(.headline)
                            ForEach(model.qcGroups) { group in
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ForEach(group.files, id: \.self) { name in
                                            Text(name).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        }
                                    }.padding(.vertical, 7)
                                } label: {
                                    HStack {
                                        Text(group.id).font(.subheadline.bold()).textSelection(.enabled)
                                        Spacer()
                                        Text("\(group.count) unprocessed").font(.caption.bold()).foregroundStyle(.orange)
                                    }
                                }
                                Divider().opacity(0.25)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(processingCardColor, in: RoundedRectangle(cornerRadius: 16))
                }

                Text("Read-only check. JPEGs are matched to RAW files by base filename. This does not verify image quality or distinguish identical filenames in different subfolders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
    @State private var reportOptions = JobReportOptions()
    var reports: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("Job Report Builder").font(.title2.bold())
                Text("Create a customizable PDF report for your current Session.")
                    .foregroundStyle(.secondary)
                TextField("Job / Report name", text: $model.reportName)
                GroupBox("Report appearance") {
                    HStack {
                        Text("Font")
                        Picker("Font", selection: $reportOptions.fontName) {
                            ForEach(["Helvetica", "Arial", "Avenir", "Futura", "Menlo", "Times New Roman"], id: \.self) { font in
                                Text(font).tag(font)
                            }
                        }.frame(maxWidth: 250)
                        Spacer()
                    }.padding(6)
                }
                GroupBox("Report contents") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Always included: Session name, date and time, source path")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Total number of images", isOn: $reportOptions.images)
                        Toggle("RAW file count", isOn: $reportOptions.raw)
                        Toggle("JPEG file count", isOn: $reportOptions.jpeg)
                        Toggle("Total session image size", isOn: $reportOptions.size)
                        Toggle("Audit results", isOn: $reportOptions.audits)
                        Toggle("Capture folder listing", isOn: $reportOptions.folders)
                        Toggle("Include a representative thumbnail for each folder", isOn: $reportOptions.thumbnails)
                            .disabled(!reportOptions.folders)
                        Text("Thumbnails use the middle image by filename in each folder. If it cannot be read, a nearby image is used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                HStack {
                    Button("Generate PDF Job Report…") { model.exportWrapReport(options: reportOptions) }
                        .disabled(model.root == nil)
                        .buttonStyle(.borderedProminent)
                    if model.root == nil { Text("Choose a session on \(DigiBrand.toolName(0)) first").foregroundStyle(.secondary) }
                }
                Divider()
                Text("Report History").font(.headline)
                ForEach(model.jobHistory, id: \.self) { entry in
                    Text(entry).font(.caption).textSelection(.enabled)
                }
            }.padding(4)
        }
    }

}

extension Notification.Name {
    static let shootWrapCommand = Notification.Name("ShootWrapCommand")
}

// Keyboard shortcuts are stored separately from saved workspaces so each user
// can maintain one personalized set across all Capture One sessions.
struct DigiShortcut: Identifiable {
    let id: String
    let title: String
    let group: String
    let key: String
    let flags: NSEvent.ModifierFlags
}

@MainActor final class DigiShortcutStore: ObservableObject {
    static let shared = DigiShortcutStore()
    static let definitions: [DigiShortcut] = [
        .init(id: "open", title: "Open Workspace", group: "Workspace", key: "o", flags: [.command]),
        .init(id: "save", title: "Save Workspace", group: "Workspace", key: "s", flags: [.command]),
        .init(id: "saveAs", title: "Save Workspace As", group: "Workspace", key: "s", flags: [.command, .shift]),
        .init(id: "chooseCapture", title: "Open Session", group: "Sessions", key: "o", flags: [.command, .shift]),
        .init(id: "dashboard", title: "Show Dashboard", group: "Navigation", key: "1", flags: [.command]),
        .init(id: "backupsTab", title: "Show Backups", group: "Navigation", key: "2", flags: [.command]),
        .init(id: "compareTab", title: "Show Folder Compare", group: "Navigation", key: "3", flags: [.command]),
        .init(id: "previous", title: "Previous Tab", group: "Navigation", key: "left", flags: [.command, .option]),
        .init(id: "next", title: "Next Tab", group: "Navigation", key: "right", flags: [.command, .option]),
        .init(id: "backup", title: "Start Backup", group: "Backups", key: "b", flags: [.command, .shift]),
        .init(id: "trial", title: "Trial Sync", group: "Backups", key: "b", flags: [.command, .option]),
        .init(id: "pause", title: "Pause / Resume Backup", group: "Backups", key: "p", flags: [.command, .option]),
        .init(id: "stop", title: "Stop Backup", group: "Backups", key: ".", flags: [.command, .option]),
        .init(id: "scan", title: "Scan Capture One", group: "Capture One", key: "r", flags: [.command, .shift]),
        .init(id: "selects", title: "Export Selects List", group: "Selects List", key: "e", flags: [.command, .shift])
    ]
    @Published private(set) var bindings: [String: String] = [:]
    private let storageKey = "DigiSuite.customShortcuts.v1"
    private init() { bindings = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:] }
    func encoded(_ id: String) -> String? {
        if let custom = bindings[id] { return custom.isEmpty ? nil : custom }
        guard let def = Self.definitions.first(where: { $0.id == id }) else { return nil }
        return Self.encode(def.key, def.flags)
    }
    static func encode(_ key: String, _ flags: NSEvent.ModifierFlags) -> String {
        let bits = (flags.contains(.command) ? "C" : "") + (flags.contains(.option) ? "O" : "") + (flags.contains(.control) ? "K" : "") + (flags.contains(.shift) ? "S" : "")
        return bits + ":" + key.lowercased()
    }
    static func decode(_ value: String) -> (KeyEquivalent, EventModifiers)? {
        let pieces = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { return nil }
        var modifiers: EventModifiers = []
        if pieces[0].contains("C") { modifiers.insert(.command) }
        if pieces[0].contains("O") { modifiers.insert(.option) }
        if pieces[0].contains("K") { modifiers.insert(.control) }
        if pieces[0].contains("S") { modifiers.insert(.shift) }
        let key: KeyEquivalent
        switch pieces[1] {
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        case "up": key = .upArrow
        case "down": key = .downArrow
        default:
            guard let character = pieces[1].first else { return nil }
            key = KeyEquivalent(character)
        }
        return (key, modifiers)
    }
    func label(_ id: String) -> String {
        guard let value = encoded(id) else { return "Unassigned" }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "Unassigned" }
        let flags = parts[0]
        let name = ["left":"←", "right":"→", "up":"↑", "down":"↓"][parts[1]] ?? parts[1].uppercased()
        return (flags.contains("K") ? "⌃" : "") + (flags.contains("O") ? "⌥" : "") + (flags.contains("S") ? "⇧" : "") + (flags.contains("C") ? "⌘" : "") + name
    }
    func conflict(_ id: String, _ encoded: String) -> String? {
        Self.definitions.first(where: { $0.id != id && self.encoded($0.id) == encoded })?.title
    }
    func assign(_ id: String, _ encoded: String?) {
        bindings[id] = encoded ?? ""
        UserDefaults.standard.set(bindings, forKey: storageKey)
    }
    func reset(_ id: String) {
        bindings.removeValue(forKey: id)
        UserDefaults.standard.set(bindings, forKey: storageKey)
    }
    func resetAll() {
        bindings = [:]
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

// An AppKit key-capture field avoids relying on typed shortcut strings.
struct DigiKeyRecorder: NSViewRepresentable {
    let onRecord: (String) -> Void
    final class Recorder: NSView {
        var onRecord: ((String) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { NSSound.beep(); return }
            let key: String
            switch event.keyCode {
            case 123: key = "left"
            case 124: key = "right"
            case 125: key = "down"
            case 126: key = "up"
            default:
                guard let char = event.charactersIgnoringModifiers?.lowercased().first,
                      !char.isNewline, !char.isWhitespace else { return }
                key = String(char)
            }
            onRecord?(DigiShortcutStore.encode(key, flags))
        }
    }
    func makeNSView(context: Context) -> Recorder {
        let view = Recorder(frame: .zero)
        view.onRecord = onRecord
        return view
    }
    func updateNSView(_ view: Recorder, context: Context) { view.onRecord = onRecord }
}

// Performance preferences are shared by all windows and persist between launches.
@MainActor final class DigiPerformanceSettings: ObservableObject {
    static let shared = DigiPerformanceSettings()
    @Published var preset: String { didSet { UserDefaults.standard.set(preset, forKey: "DigiSuite.performance.preset") } }
    @Published var deferScansDuringBackup: Bool { didSet { UserDefaults.standard.set(deferScansDuringBackup, forKey: "DigiSuite.performance.deferScans") } }
    private init() {
        preset = UserDefaults.standard.string(forKey: "DigiSuite.performance.preset") ?? "Balanced"
        deferScansDuringBackup = UserDefaults.standard.object(forKey: "DigiSuite.performance.deferScans") as? Bool ?? true
    }
    var scanPriority: TaskPriority {
        switch preset {
        case "Quiet": return .background
        case "Maximum": return .userInitiated
        default: return .utility
        }
    }
}

struct DigiPerformanceSettingsView: View {
    @ObservedObject private var settings = DigiPerformanceSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Performance").font(.title2.bold())
            Text("Control how \(DigiBrand.name) schedules file inventory and storage scans. Settings are saved automatically.")
                .foregroundStyle(.secondary)
            Picker("Scan priority", selection: $settings.preset) {
                Text("Quiet").tag("Quiet")
                Text("Balanced").tag("Balanced")
                Text("Maximum Performance").tag("Maximum")
            }.pickerStyle(.segmented)
            Text(settings.preset == "Quiet" ? "Background priority, minimizing interference with other apps." : settings.preset == "Maximum" ? "Prioritize scanning speed when you need results quickly." : "Utility priority, suitable for everyday use.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Prevent new scans while a backup is running", isOn: $settings.deferScansDuringBackup)
            Text("This avoids starting a disk-intensive inventory during an active backup. Existing scans are not interrupted.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Backup integrity").font(.headline)
            Label("Backups copy new and changed files. Content checks are available in \(DigiBrand.toolName(7)) > Deep Verify.", systemImage: "checkmark.shield")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    settings.preset = "Balanced"
                    settings.deferScansDuringBackup = true
                }
            }
        }.padding(22).frame(width: 600, height: 360)
    }
}

@MainActor
final class DigiLoginSettings: ObservableObject {
    static let shared = DigiLoginSettings()
    @Published var enabled = false
    @Published var errorMessage: String?
    private init() { refresh() }

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ shouldEnable: Bool) {
        do {
            if shouldEnable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}

struct DigiGeneralSettingsView: View {
    @ObservedObject private var login = DigiLoginSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General").font(.title2.bold())
            Toggle("Open \(DigiBrand.name) at login", isOn: Binding(
                get: { login.enabled },
                set: { login.setEnabled($0) }
            ))
            Text("Automatically launch \(DigiBrand.name) when you sign in to your Mac. You can also manage login items in System Settings.")
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
        }
        .padding(22)
        .frame(width: 600, height: 360)
        .onAppear { login.refresh() }
        .alert("Couldn't update login setting", isPresented: Binding(
            get: { login.errorMessage != nil },
            set: { if !$0 { login.errorMessage = nil } }
        )) {
            Button("OK") { login.errorMessage = nil }
        } message: {
            Text(login.errorMessage ?? "")
        }
    }
}

struct DigiSuiteSettingsView: View {
    var body: some View {
        TabView {
            DigiGeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            ShootWrapShortcutSettings().tabItem { Label("Keyboard Shortcuts", systemImage: "keyboard") }
            DigiPerformanceSettingsView().tabItem { Label("Performance", systemImage: "gauge") }
        }
    }
}

struct ShootWrapShortcutSettings: View {
    @ObservedObject private var store = DigiShortcutStore.shared
    @State private var search = ""
    @State private var recording: String? = nil
    @State private var warning: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.bold())
                Spacer()
                Button("Restore All Defaults") { store.resetAll(); recording = nil; warning = nil }
            }
            TextField("Search actions", text: $search)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(DigiShortcutStore.definitions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }) { action in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                            Text(action.group).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if recording == action.id {
                            Text("Press shortcut…").foregroundStyle(.orange)
                            DigiKeyRecorder { value in
                                if let duplicate = store.conflict(action.id, value) {
                                    warning = "Already assigned to \(duplicate). Clear or change that shortcut first."
                                } else if ["C:q", "C:w", "C:h", "C:m", "C:,"].contains(value) {
                                    warning = "This shortcut is reserved by macOS or \(DigiBrand.name)."
                                } else {
                                    store.assign(action.id, value)
                                    recording = nil
                                    warning = nil
                                }
                            }.frame(width: 2, height: 20)
                            Button("Cancel") { recording = nil; warning = nil }
                        } else {
                            Button(store.label(action.id)) { recording = action.id; warning = nil }
                                .monospaced()
                            Button("Clear") { store.assign(action.id, nil) }
                            Button("Reset") { store.reset(action.id) }
                        }
                    }.padding(.vertical, 3)
                }
            }
            if let warning { Text(warning).foregroundStyle(.red).font(.caption) }
            Text("Click a shortcut, then press a combination containing ⌘, ⌥, or ⌃. Changes apply immediately and are saved across launches. Hiding tabs does not disable their shortcuts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 670, height: 610)
    }
}


@MainActor
private struct DigiMenuBarView: View {
    @ObservedObject var model: WrapModel
    @ObservedObject private var watcher = MetadataWatcherModel.shared
    @AppStorage(WrapModel.soundsKey) private var sounds = DigiBrand.soundsDefault

    init(model: WrapModel) { self.model = model }

    private func showApp(tab: Int? = nil) {
        if let tab {
            model.lastTab = tab
            NotificationCenter.default.post(name: .digiToolChosen, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == DigiBrand.name && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }

    private var statusLine: String {
        let step = DigiNextStep.current(model)
        return step.title
    }

    var body: some View {
        let step = DigiNextStep.current(model)
        let canBackUp = step.kind == .backUp || step.kind == .safe
        return VStack(alignment: .leading, spacing: 9) {
            Text(DigiBrand.name + ": " + statusLine)
            Text(model.root?.lastPathComponent ?? "No session open")
            Divider()
            if model.syncBusy {
                Button(model.everythingPaused ? "Resume Backup" : "Pause Backup") { model.togglePauseAll() }
                Button("Stop Backup") { model.stopSync() }
            } else if canBackUp {
                Button("Back Up Now") { model.requestStartSync() }
                    .disabled(model.driveCheckRunning)
            } else {
                // Not ready to back up yet: offer the step that gets there.
                Button(step.button) {
                    showApp()
                    step.perform(model)
                }
            }
            if watcher.watching {
                Button("Stop Watching Metadata Folder") { watcher.stop() }
            }
            Divider()
            Button("Backup Schedule…") { showApp(tab: 1) }
            Toggle("Scheduled Backups", isOn: $model.scheduleEnabled)
            Toggle("Backup Notifications", isOn: $model.backupNotificationsEnabled)
            Toggle("Sounds", isOn: $sounds)
            Divider()
            Button("Open \(DigiBrand.name)") { showApp() }
            Button("Quit \(DigiBrand.name)") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(minWidth: 280)
    }
}

// Keep weak references to each open workspace so Cmd+Q can protect active transfers.
@MainActor final class DigiBackupQuitRegistry {
    static let shared = DigiBackupQuitRegistry()
    private final class WeakModel {
        weak var value: WrapModel?
        init(_ value: WrapModel) { self.value = value }
    }
    private var models: [WeakModel] = []
    func register(_ model: WrapModel) {
        models.removeAll { $0.value == nil }
        guard !models.contains(where: { $0.value === model }) else { return }
        models.append(WeakModel(model))
    }
    var activeBackups: [WrapModel] {
        models.compactMap(\.value).filter { $0.syncBusy }
    }
    var hasActiveDiskOperations: Bool {
        models.compactMap(\.value).contains { $0.syncBusy || $0.busy || $0.storageScanning || $0.discoveredBackupScanning }
    }
}

@MainActor private final class DigiQuitDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Version 20.11: offer to install in Applications and the Dock.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated { DigiInstaller.offerAtLaunch() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = DigiBackupQuitRegistry.shared.activeBackups
        let benchmarking = DigiBackupBenchmark.shared.isRunning
        guard !active.isEmpty || benchmarking else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = benchmarking ? "A speed benchmark is still in progress" : (active.count == 1 ? "A backup is still in progress" : "Backups are still in progress")
        alert.informativeText = benchmarking ? "Use Stop Benchmark to finish cleanup before quitting. Quitting now may leave temporary test folders on the destinations." : "Quitting \(DigiBrand.name) will interrupt active or paused backup transfers. The destinations may be incomplete. Do you want to keep \(DigiBrand.name) open?"
        alert.addButton(withTitle: benchmarking ? "Keep Running" : "Keep Backing Up")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// v1.16: the "Capture One Sessions Detected" dialog keeps its own selection, so
/// clicking a session redraws only the dialog (it used to redraw the whole app
/// window behind it, which took seconds). Rows are big click targets.
private struct SessionProposalSheet: View {
    let matches: [URL]
    let initial: String
    let canAccept: Bool
    let onNotNow: () -> Void
    let onUse: (String) -> Void
    @State private var selected = ""

    init(matches: [URL], initial: String, canAccept: Bool, onNotNow: @escaping () -> Void, onUse: @escaping (String) -> Void) {
        self.matches = matches
        self.initial = initial
        self.canAccept = canAccept
        self.onNotNow = onNotNow
        self.onUse = onUse
        var start = initial
        if start.isEmpty || !matches.contains(where: { $0.path == initial }) {
            start = matches.first?.path ?? ""
        }
        self._selected = State(initialValue: start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Capture One Sessions Detected", systemImage: "camera.aperture")
                .font(.title3.weight(.semibold))
            Text("Choose which open Capture One session to use as your \(DigiBrand.name) workspace. No backups will start automatically.")
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(matches, id: \.path) { url in
                    sessionRow(url)
                }
            }
            HStack {
                Spacer()
                Button("Not Now") { onNotNow() }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Session") { onUse(selected) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAccept || selected.isEmpty)
            }
        }
        .padding(22)
        .frame(minWidth: 560)
    }

    /// A plain row; only the circle turns blue when chosen (v1.17).
    private func sessionRow(_ url: URL) -> some View {
        let isSelected = selected == url.path
        return Button { selected = url.path } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                Text(url.lastPathComponent).font(.body.weight(.medium))
                Text("•").foregroundStyle(.secondary)
                Text(url.path).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The first window shares its workspace with the menu bar, so the menu bar
/// always shows and controls the backups you see. Extra windows get their own.
@MainActor enum DigiPrimaryModel {
    static let shared = WrapModel()
    private static var claimed = false
    static func claim() -> WrapModel {
        if claimed { return WrapModel() }
        claimed = true
        return shared
    }
    /// A closed window hands the shared workspace back, so reopening the
    /// window (for example from Tally's menu bar panel) shows the same session.
    static func release(_ model: WrapModel) {
        if model === shared { claimed = false }
    }
}

private struct DigiWorkspaceWindow: View {
    @StateObject private var model = DigiPrimaryModel.claim()
    var body: some View {
        ShootWrapView(model: model)
            .background(DigiWindowFrameSaver(name: DigiBrand.name + " Main Window"))
            .onAppear {
                DigiBackupQuitRegistry.shared.register(model)
                // v1.25: once a day, quietly; speaks up only when there's a new version.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    MainActor.assumeIsolated { DigiUpdater.checkInBackgroundIfDue() }
                }
            }
            .onDisappear { DigiPrimaryModel.release(model) }
    }
}

@main struct ShootWrapApp: App {
    @NSApplicationDelegateAdaptor(DigiQuitDelegate.self) private var quitDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var shortcuts = DigiShortcutStore.shared
    @StateObject private var model = DigiPrimaryModel.shared
    @AppStorage(DigiHiddenTools.key) private var hiddenToolsRaw = ""
    @AppStorage(DigiToolOrder.key) private var toolOrderRaw = ""
    private func command(_ name: String) { NotificationCenter.default.post(name: .shootWrapCommand, object: name) }
    @ViewBuilder private func shortcutButton(_ title: String, _ id: String) -> some View {
        if let value = shortcuts.encoded(id), let (key, modifiers) = DigiShortcutStore.decode(value) {
            Button(title) { command(id) }.keyboardShortcut(key, modifiers: modifiers)
        } else {
            Button(title) { command(id) }
        }
    }
    var body: some Scene {
        WindowGroup(DigiBrand.name, id: "workspace") { DigiWorkspaceWindow() }
            // First launch opens big enough to show the whole dashboard; after
            // that macOS reopens the window at the size it was left.
            .defaultSize(width: 1360, height: 1040)
#if BRAND_GRIP || BRAND_WRAP || BRAND_PROOF || BRAND_TECHCART || BRAND_TALLY
            .windowStyle(.hiddenTitleBar)
#endif
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { DigiUpdater.checkNow() }
                    Toggle("Check for Updates Automatically", isOn: Binding(
                        get: { DigiUpdater.autoCheck },
                        set: { DigiUpdater.autoCheck = $0 }
                    ))
                    Divider()
                    Button("Install in Applications / Dock…") { DigiInstaller.offerFromMenu() }
                }
                CommandGroup(replacing: .newItem) {
                    // SwiftUI WindowGroup supplies a separate model for each new window.
                    Button("New Workspace") { openWindow(id: "workspace") }
                        .keyboardShortcut("n", modifiers: .command)
                    shortcutButton("Open Workspace…", "open")
                    shortcutButton("Save Workspace", "save")
                    shortcutButton("Save Workspace As…", "saveAs")
                }
                CommandMenu("Navigate") {
                    shortcutButton("Open Session…", "chooseCapture")
                    if DigiBrand.isClassic {
                        shortcutButton("Show Dashboard", "dashboard")
                        shortcutButton("Show Backups", "backupsTab")
                        shortcutButton("Show Folder Compare", "compareTab")
                        Button("Reset Tab Order") { command("resetTabs") }
                    } else {
                        Divider()
                        ForEach(Array(DigiBrand.visibleTools(hidden: DigiHiddenTools.parse(hiddenToolsRaw)).enumerated()), id: \.element.id) { position, tool in
                            if position < 9 {
                                Button(tool.name) { command("tool:\(tool.id)") }
                                    .keyboardShortcut(KeyEquivalent(Character("\(position + 1)")), modifiers: .command)
                            } else {
                                Button(tool.name) { command("tool:\(tool.id)") }
                            }
                        }
                        if !hiddenToolsRaw.isEmpty {
                            Divider()
                            Button("Show All Tools") { hiddenToolsRaw = "" }
                        }
                        Button("Reset Tool Order") { toolOrderRaw = "" }
                            .disabled(toolOrderRaw.isEmpty)
                    }
                    Divider()
                    shortcutButton("Previous Tab", "previous")
                    shortcutButton("Next Tab", "next")
                }
                CommandMenu("Actions") {
                    shortcutButton("Start Backup to All Destinations", "backup")
                    shortcutButton("Trial Sync", "trial")
                    shortcutButton("Pause / Resume Backup", "pause")
                    shortcutButton("Stop Backup", "stop")
                    Divider()
                    shortcutButton("Scan Capture One", "scan")
                    shortcutButton("Export Selects List", "selects")
                }
                CommandGroup(replacing: .help) {
                    Button("Show the \(DigiBrand.name) Tour") { command("tour") }
                }
            }
#if BRAND_TALLY
        MenuBarExtra {
            TallyMenuPanel(model: model)
        } label: {
            Image(systemName: TallyState.current(model).symbol)
        }
        .menuBarExtraStyle(.window)
#else
        MenuBarExtra {
            DigiMenuBarView(model: model).onAppear { DigiBackupQuitRegistry.shared.register(model) }
        } label: {
            Image(systemName: model.syncBusy ? "arrow.triangle.2.circlepath.circle.fill" :
                model.scheduleLastResults.values.contains(where: { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("fail") }) ?
                "exclamationmark.triangle.fill" : DigiBrand.menuBarSymbol)
        }
#endif
        Settings { DigiSuiteSettingsView() }
    }
}

private struct BackupDestinationSheet: Identifiable {
    let path: String
    var id: String { path }
}

private struct BackupFilterEditor: View {
    let source: URL?
    let destination: String
    @Binding var filter: BackupFilter
    let copyToAll: (BackupFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String] = []
    @State private var expandedFolders: Set<String> = []
    @State private var customName = ""
    @State private var customExtension = ""
    private let commonExtensions = ["jpg", "jpeg", "tif", "tiff", "psd", "png", "pdf", "mp4", "mov", "tmp",
        "3fr", "ari", "arw", "bay", "cap", "cr2", "cr3", "crw", "data", "dcs", "dcr", "dng", "drf", "eip", "erf", "fff", "iiq", "k25", "kdc", "mdc", "mef", "mos", "mrw", "nef", "nrw", "obm", "orf", "pef", "ptx", "pxn", "qtk", "raf", "raw", "rdc", "rw2", "rwl", "rwz", "sr2", "srf", "srw", "sti", "x3f"]
    private func ancestorExcluded(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return false }
        return (1..<parts.count).contains { filter.excludedFolders.contains(parts.prefix($0).joined(separator: "/")) }
    }
    private func hasChildren(_ path: String) -> Bool { folders.contains { $0.hasPrefix(path + "/") } }
    private var visibleFolders: [String] {
        folders.filter { path in
            let parts = path.split(separator: "/")
            guard parts.count > 1 else { return true }
            return (1..<parts.count).allSatisfy { expandedFolders.contains(parts.prefix($0).joined(separator: "/")) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backup Selection").font(.title2.bold())
            Text("Destination: " + destination).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("Unchecked folders and extensions are skipped. Existing excluded files on the destination are never archived as removed.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Include hidden files", isOn: $filter.includeHidden)
            Divider()
            Text("Folders in source").font(.headline)
            HStack(spacing: 12) {
                Button("Expand All") { expandedFolders = Set(folders) }.font(.caption)
                Button("Collapse All") { expandedFolders.removeAll() }.font(.caption)
                Spacer()
                Text("Unchecking a folder skips its contents").font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(visibleFolders, id: \.self) { folder in
                        let depth = folder.split(separator: "/").count - 1
                        let disabledByParent = ancestorExcluded(folder)
                        HStack(spacing: 7) {
                            if hasChildren(folder) {
                                Button {
                                    if expandedFolders.contains(folder) { expandedFolders.remove(folder) }
                                    else { expandedFolders.insert(folder) }
                                } label: {
                                    Image(systemName: expandedFolders.contains(folder) ? "chevron.down" : "chevron.right")
                                        .frame(width: 14)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Color.clear.frame(width: 14, height: 14)
                            }
                            Toggle(isOn: Binding(get: {
                                !disabledByParent && !filter.excludedFolders.contains(folder)
                            }, set: { value in
                                if value { filter.excludedFolders.remove(folder) }
                                else { filter.excludedFolders.insert(folder) }
                            })) {
                                Label(String(folder.split(separator: "/").last ?? ""), systemImage: "folder")
                                    .font(.callout)
                            }
                            .disabled(disabledByParent)
                        }
                        .padding(.leading, CGFloat(depth) * 19)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 250)
            Divider()
            Text("File extensions").font(.headline)
            Text("Common files and camera RAW formats (uncheck to exclude)")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 9) {
                    ForEach(commonExtensions, id: \.self) { ext in
                        Toggle("." + ext, isOn: Binding(get: { !filter.excludedExtensions.contains(ext) }, set: { value in
                            if value { filter.excludedExtensions.remove(ext) } else { filter.excludedExtensions.insert(ext) }
                        }))
                    }
                }
            }
            HStack {
                TextField("Additional extension (e.g. xmp)", text: $customExtension)
                Button("Exclude Extension") {
                    let value = customExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if !value.isEmpty { filter.excludedExtensions.insert(value); customExtension = "" }
                }
            }
            if !filter.excludedExtensions.isEmpty {
                Text("Excluded extensions: " + filter.excludedExtensions.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Exclude file/folder name (exact match)", text: $customName)
                Button("Add Name") {
                    let value = customName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !value.isEmpty { filter.excludedNames.insert(value); customName = "" }
                }
            }
            ForEach(filter.excludedNames.sorted(), id: \.self) { name in
                HStack { Text(name).font(.caption); Button("Remove") { filter.excludedNames.remove(name) }.font(.caption) }
            }
            Divider()
            HStack {
                Button("Copy Settings to All Destinations") { copyToAll(filter) }
                Spacer()
                Button("Include Everything") { filter = BackupFilter(includeHidden: true) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 650)
        .onAppear { loadFolders() }
    }
    private func loadFolders() {
        guard let source else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var found: [String] = []
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let relative = String(url.path.dropFirst(source.path.count + 1))
                found.append(relative)
                if found.count >= 2000 { break }
            }
            DispatchQueue.main.async {
                folders = found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                expandedFolders = Set(found.filter { $0.split(separator: "/").count == 1 })
            }
        }
    }
}


extension Notification.Name {
    static let digiSuiteContactFolder = Notification.Name("DigiSuite.ContactFolder")
}

// Shared workspace folder browser: folders are draggable and clickable for Contact Sheets.
struct WorkspaceFolderTree: View {
    let root: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WORKSPACE FOLDERS").font(.caption2.bold()).foregroundStyle(.secondary)
            if let root {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        WorkspaceFolderNode(url: root, depth: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Click or drag a folder into Contact Sheets to add its images.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Open a session to browse its folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

struct WorkspaceFolderNode: View {
    let url: URL
    let depth: Int
    @State private var expanded = false
    private var children: [URL] {
        guard depth < 12 else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }.buttonStyle(.plain)
                Image(systemName: expanded ? "folder.open" : "folder").foregroundStyle(.secondary)
                Button {
                    NotificationCenter.default.post(name: .digiSuiteContactFolder, object: url)
                } label: {
                    Text(url.lastPathComponent).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Add this folder to Contact Sheets: " + url.path)
                .onDrag { NSItemProvider(object: url as NSURL) }
                Spacer(minLength: 0)
            }.font(.caption).padding(.leading, CGFloat(depth * 12))
            if expanded {
                ForEach(children, id: \.path) { child in
                    WorkspaceFolderNode(url: child, depth: depth + 1)
                }
            }
        }
    }
}

// Version 16: speed history graph for one destination. Shows dips and
// recovery over the whole run; samples come from the backup engine.
struct DigiSpeedSparkline: View {
    let samples: [Double]
    let peak: Double
    var height: CGFloat = 40

    private func points(in size: CGSize) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let highestSample: Double = samples.max() ?? 0
        let top: Double = max(max(peak, highestSample), 1)
        let step: CGFloat = size.width / CGFloat(samples.count - 1)
        let usableHeight: CGFloat = size.height - 2
        var result: [CGPoint] = []
        result.reserveCapacity(samples.count)
        for (index, value) in samples.enumerated() {
            let fraction: CGFloat = CGFloat(min(value, top) / top)
            let x: CGFloat = CGFloat(index) * step
            let y: CGFloat = size.height - fraction * usableHeight - 1
            result.append(CGPoint(x: x, y: y))
        }
        return result
    }
    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: height))
        for point in points { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.closeSubpath()
        return path
    }
    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    var body: some View {
        GeometryReader { geometry in
            let plotted = points(in: geometry.size)
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08))
                if plotted.isEmpty {
                    Text("Speed graph appears once copying starts")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    area(plotted, height: geometry.size.height)
                        .fill(LinearGradient(colors: [DigiBrand.accent.opacity(0.35), DigiBrand.accent.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom))
                    line(plotted)
                        .stroke(DigiBrand.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Transfer speed graph")
    }
}

// Version 18: last successful backup for one destination.
struct DigiLastBackup: Codable, Equatable {
    let date: Date
    let seconds: Double
    let averageMBps: Double
    let copiedFiles: Int
    let copiedBytes: Int64
}


/// v1.24: talk only to the Capture One that is already running. `tell application
/// "Capture One"` makes macOS pick an app by name, and with an older Capture One
/// installed it could launch that one. Scripts now name the running copy by its
/// path and stop if it isn't running, so they never open Capture One.
enum CaptureOneTarget {
    static func running() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            let name = app.executableURL?.lastPathComponent ?? ""
            return name.localizedCaseInsensitiveContains("Capture One") && !app.isTerminated
        }
        return apps.sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }.first
    }

    /// `application "/Applications/Capture One.app"` for that exact copy.
    static func reference(_ app: NSRunningApplication) -> String? {
        guard let path = app.bundleURL?.path else { return nil }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "application \"" + escaped + "\""
    }
}
