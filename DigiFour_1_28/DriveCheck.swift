import Foundation

// Version 16: shows how each backup destination is actually connected.
// The USB link speed is chosen when a drive is plugged in, and a drive that
// silently lands on 5 Gb/s or USB 2 caps every copy tool at that rate. This
// file only reads information; it never changes a drive or its contents.
struct DigiDriveStatus: Sendable, Equatable {
    let destinationPath: String
    var volumePath: String?
    var deviceName: String?
    var linkSpeed: String?        // As macOS reports it, e.g. "Up to 10 Gb/s"
    var linkMbps: Double?
    var availableBytes: Int64?
    var totalBytes: Int64?
    var formatName: String?
    var isConnected: Bool = true

    var linkLabel: String {
        guard let linkMbps else { return "Link speed not reported" }
        if linkMbps >= 1000 {
            let gbps: Double = linkMbps / 1000
            if gbps == gbps.rounded() { return "\(Int(gbps)) Gb/s" }
            return String(format: "%.1f Gb/s", gbps)
        }
        return "\(Int(linkMbps)) Mb/s"
    }
    /// A link slower than 10 Gb/s. These drives (T7, X9 Pro) are 10 Gb/s
    /// devices, so a slower link usually means a port, cable or replug issue.
    var isSlowLink: Bool { (linkMbps ?? .infinity) < 10_000 }
    var linkWarning: String? {
        guard let linkMbps, linkMbps < 10_000 else { return nil }
        if linkMbps < 5_000 {
            return "Connected at USB 2 speed (\(linkLabel)). Backups to this drive will run at about 40 MB/s. Unplug it and plug it back in, or try another port or cable."
        }
        return "Connected at \(linkLabel). Backups to this drive will top out around 400 to 450 MB/s. If the drive supports 10 Gb/s, unplug it and plug it back in, or try another port or cable."
    }
    var freeFraction: Double? {
        guard let availableBytes, let totalBytes, totalBytes > 0 else { return nil }
        return Double(availableBytes) / Double(totalBytes)
    }
    var spaceWarning: String? {
        guard let fraction = freeFraction, fraction < 0.10 else { return nil }
        return String(format: "Only %.0f%% free. SSDs write much more slowly when nearly full.", fraction * 100)
    }
    var warnings: [String] { [linkWarning, spaceWarning].compactMap { $0 } }
}

enum DigiDriveCheck {
    /// Parses the plain-text output of `system_profiler SPUSBDataType` and maps
    /// each mount point to the speed of the nearest USB device above it.
    /// Plain text is used because its layout was confirmed on Jeff's Mac
    /// (macOS 15.7.7); indentation encodes the device tree.
    static func parseUSBReport(_ text: String) -> [String: (device: String, speed: String)] {
        parseUSBTree(text, key: "Mount Point")
    }

    /// BSD disk names (disk6, disk6s2) mapped to the nearest USB device speed.
    /// Needed for APFS, whose mounted volumes live on a synthesized disk that
    /// does not appear under the USB device.
    static func parseUSBBSDNames(_ text: String) -> [String: (device: String, speed: String)] {
        parseUSBTree(text, key: "BSD Name")
    }

    /// "disk6s2" -> "disk6"; "disk6" stays "disk6".
    static func wholeDisk(_ name: String) -> String {
        guard name.hasPrefix("disk") else { return name }
        let digits = name.dropFirst(4)
        let number = digits.prefix(while: { $0.isNumber })
        return number.isEmpty ? name : "disk" + number
    }

    /// The physical disks behind a mounted volume. For APFS this asks diskutil
    /// for the container's physical store; for HFS+ it is the volume's own disk.
    static func physicalDisks(forVolume volume: String) -> [String] {
        #if os(macOS)
        var info = statfs()
        guard statfs(volume, &info) == 0 else { return [] }
        let device: String = withUnsafePointer(to: &info.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let bsd: String = device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
        guard bsd.hasPrefix("disk") else { return [] }
        var names: [String] = [bsd, wholeDisk(bsd)]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", bsd]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return names }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let stores = plist["APFSPhysicalStores"] as? [[String: Any]] {
            for store in stores {
                if let name = store["APFSPhysicalStore"] as? String {
                    names.append(name)
                    names.append(wholeDisk(name))
                }
            }
        }
        return names
        #else
        return []
        #endif
    }

    static func parseUSBTree(_ text: String, key wanted: String) -> [String: (device: String, speed: String)] {
        struct Node { let indent: Int; let name: String; var speed: String? }
        var stack: [Node] = []
        var result: [String: (device: String, speed: String)] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            if trimmed.hasSuffix(":") && !trimmed.contains(": ") {
                while let last = stack.last, last.indent >= indent { stack.removeLast() }
                stack.append(Node(indent: indent, name: String(trimmed.dropLast()), speed: nil))
                continue
            }
            guard let separator = trimmed.range(of: ": ") else { continue }
            let key = String(trimmed[..<separator.lowerBound])
            let value = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            // A property belongs to the closest header with a smaller indent.
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            if key == "Speed" || key == "USB Speed" || key == "Link Speed" {
                if !stack.isEmpty { stack[stack.count - 1].speed = value }
            } else if key == wanted, !value.isEmpty {
                if let device = stack.last(where: { $0.speed != nil }), let speed = device.speed {
                    result[value] = (device.name, speed)
                }
            }
        }
        return result
    }

    /// "Up to 10 Gb/s" -> 10000, "Up to 480 Mb/s" -> 480.
    static func megabits(_ speed: String) -> Double? {
        let parts = speed.replacingOccurrences(of: ",", with: ".").split(separator: " ")
        for (index, part) in parts.enumerated() {
            guard let number = Double(part), index + 1 < parts.count else { continue }
            let unit = parts[index + 1].lowercased()
            if unit.hasPrefix("gb") { return number * 1000 }
            if unit.hasPrefix("mb") { return number }
        }
        return nil
    }

    static func volumePath(for destination: URL) -> String? {
        if let volume = try? destination.resourceValues(forKeys: [.volumeURLKey]).volume {
            return volume.standardizedFileURL.path
        }
        let parts = destination.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return "/Volumes/" + parts[2] }
        return nil
    }

    static func freeBytes(_ url: URL) -> Int64? { DigiFastBackupEngine.availableBytes(url) }

    static func inspect(_ requested: URL, usbReport: String?) -> DigiDriveStatus {
        // A fresh URL: Foundation caches resource values (including free
        // space) on a URL instance, which left free space stale after a backup.
        let destination = URL(fileURLWithPath: requested.path)
        var status = DigiDriveStatus(destinationPath: requested.path)
        status.isConnected = DigiFastBackupEngine.availableDirectory(destination)
        guard status.isConnected else { return status }
        status.volumePath = volumePath(for: destination)
        if let values = try? destination.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey]) {
            status.totalBytes = values.volumeTotalCapacity.map { Int64($0) }
            status.formatName = values.volumeLocalizedFormatDescription
        }
        status.availableBytes = freeBytes(destination)
        if let report = usbReport, let volume = status.volumePath {
            var match = parseUSBReport(report)[volume]
            if match == nil {
                // APFS: find the USB device through the container's physical disk.
                let byDisk = parseUSBBSDNames(report)
                for disk in physicalDisks(forVolume: volume) {
                    if let found = byDisk[disk] { match = found; break }
                }
            }
            if let match {
                status.deviceName = match.device
                status.linkSpeed = match.speed
                status.linkMbps = megabits(match.speed)
            }
        }
        return status
    }

    /// Runs `system_profiler SPUSBDataType`. Takes about one to three seconds.
    /// Returns nil if it fails or exceeds the timeout; callers then show
    /// "Link speed not reported" instead of guessing.
    static func runUSBReport(timeout: TimeInterval = 20) -> String? {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPUSBDataType"]
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("digisuite-usb-" + UUID().uuidString + ".txt")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? FileManager.default.removeItem(at: output) }
        // Writing to a file avoids a full pipe blocking system_profiler.
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { try? handle.close(); return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); try? handle.close(); return nil }
        try? handle.close()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: output) else { return nil }
        return String(decoding: data, as: UTF8.self)
        #else
        return nil
        #endif
    }

    static func inspectAll(_ destinations: [URL]) -> [DigiDriveStatus] {
        let report = runUSBReport()
        return destinations.map { inspect($0, usbReport: report) }
    }
}
