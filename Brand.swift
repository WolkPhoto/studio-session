import SwiftUI
import AppKit

// One codebase, five apps. build_<App>.command passes -D BRAND_<APP>;
// with no flag the build is the classic Digi Suite. Everything below the
// interface (Digi Stream, drive checks, Folder Compare, Folder Maker engine,
// every safety rule) is shared, so all five behave and perform the same.

enum DigiNavStyle: Equatable {
    case classic   // Digi Suite: top tabs
    case sidebar   // Grip
    case command   // Wrap
    case timeline  // Proof
    case tiles     // Tech Cart
    case menuBar   // Tally
}

struct DigiTheme {
    let scheme: ColorScheme
    let background: Color
    let surface: Color
    let raised: Color
    let line: Color
    let text: Color
    let subtext: Color
    let accent: Color
    let onAccent: Color
    let good: Color
    let warn: Color
    let bad: Color
    let design: Font.Design
    let width: Font.Width
    let radius: CGFloat
}

extension Color {
    init(digiHex value: UInt32) {
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// The nine tools, in the order the app has always numbered them.
/// 0 Session, 1 Backups, 2 Selects, 3 Exports check, 4 Folders,
/// 5 Report, 6 Contact Sheets, 7 Compare, 8 Metadata.
struct DigiTool: Identifiable {
    let id: Int
    let name: String
    let icon: String
    let blurb: String
}

enum DigiTourAction: Equatable {
    case openSession
    case showTool(Int)
}

struct DigiTourPage: Identifiable {
    let id: Int
    let icon: String
    let title: String
    let body: String
    let action: DigiTourAction?
    let actionTitle: String
}

enum DigiBrand {
    static let toolIcons: [String] = [
        "house", "externaldrive.badge.checkmark", "star", "checkmark.seal",
        "folder.badge.plus", "doc.text", "square.grid.3x3", "square.split.2x1", "tag"
    ]
    static let toolBlurbs: [String] = [
        "Your session at a glance, and what to do next.",
        "Copy the session to your drives. Only new and changed files are copied.",
        "Make a list of starred and color-tagged images.",
        "Make sure every selected image was exported.",
        "Make folders from a list, a spreadsheet or a number sequence.",
        "Write up the day: what was shot, backed up and delivered.",
        "Lay out images on printable contact sheet pages.",
        "Compare the session with your backups, file by file.",
        "Add your IPTC info to every raw as a sidecar .xmp. Capture One loads it."
    ]

#if BRAND_GRIP
    static let name = "Studio Session"
    static let tagline = "Every frame, twice."
    static let nav = DigiNavStyle.sidebar
    static let toolNames = ["Home", "Backups", "Selects Report", "Export Check", "Folder Maker", "Job Report", "Contact Sheets", "Folder Checker", "Metadata"]
    static let fixedTheme = DigiTheme(scheme: .dark,
        background: Color(digiHex: 0x0E0F10), surface: Color(digiHex: 0x17191B), raised: Color(digiHex: 0x1E2124),
        line: Color(digiHex: 0x2A2D31), text: Color(digiHex: 0xECEAE4), subtext: Color(digiHex: 0x9A9EA4),
        accent: Color(digiHex: 0xF2A93B), onAccent: Color(digiHex: 0x0E0F10),
        good: Color(digiHex: 0x5BD08A), warn: Color(digiHex: 0xF5D061), bad: Color(digiHex: 0xFF6B5E),
        design: .default, width: .expanded, radius: 12)
#elseif BRAND_WRAP
    static let name = "Wrap"
    static let tagline = "Shoot it. Save it. Wrap it."
    static let nav = DigiNavStyle.command
    static let toolNames = ["Home", "Back Up", "Picks", "Exports", "Folders", "Wrap Report", "Contact Sheets", "Compare", "Metadata"]
    static let fixedTheme = DigiTheme(scheme: .dark,
        background: Color(digiHex: 0x2E2E2E), surface: Color(digiHex: 0x3A3A3A), raised: Color(digiHex: 0x454545),
        line: Color(digiHex: 0x555555), text: Color(digiHex: 0xF4F4F2), subtext: Color(digiHex: 0xC8C8C4),
        accent: Color(digiHex: 0xE0A32E), onAccent: Color(digiHex: 0x1A1A1A),
        good: Color(digiHex: 0x9DBC40), warn: Color(digiHex: 0xE0A32E), bad: Color(digiHex: 0xE0686F),
        design: .default, width: .condensed, radius: 6)
#elseif BRAND_PROOF
    static let name = "Proof"
    static let tagline = "Proof it's all there."
    static let nav = DigiNavStyle.timeline
    static let toolNames = ["Dashboard", "Backup", "Selects", "Export Check", "Folders", "Report", "Contact Sheets", "Verify", "Metadata"]
    static let fixedTheme = DigiTheme(scheme: .light,
        background: Color(digiHex: 0xF7F7F5), surface: Color(digiHex: 0xFFFFFF), raised: Color(digiHex: 0xEFEFEC),
        line: Color(digiHex: 0xDCDCD8), text: Color(digiHex: 0x0B0B0C), subtext: Color(digiHex: 0x55575C),
        accent: Color(digiHex: 0x2D5BFF), onAccent: Color(digiHex: 0xFFFFFF),
        good: Color(digiHex: 0x1F8A4C), warn: Color(digiHex: 0xA86A00), bad: Color(digiHex: 0xC8322B),
        design: .default, width: .standard, radius: 10)
    /// v1.8: Proof's dark look, chosen from its appearance menu.
    static let darkTheme = DigiTheme(scheme: .dark,
        background: Color(digiHex: 0x111214), surface: Color(digiHex: 0x1A1B1E), raised: Color(digiHex: 0x232428),
        line: Color(digiHex: 0x303236), text: Color(digiHex: 0xF2F2F0), subtext: Color(digiHex: 0xA6A8AD),
        accent: Color(digiHex: 0x4F78FF), onAccent: Color(digiHex: 0xFFFFFF),
        good: Color(digiHex: 0x3DBE74), warn: Color(digiHex: 0xE0A93A), bad: Color(digiHex: 0xF0605A),
        design: .default, width: .standard, radius: 10)
#elseif BRAND_TECHCART
    static let name = "Tech Cart"
    static let tagline = "Read it from across the set."
    static let nav = DigiNavStyle.tiles
    static let toolNames = ["Session", "Backup", "Selects", "Exports", "Folders", "Report", "Sheets", "Compare", "Metadata"]
    static let fixedTheme = DigiTheme(scheme: .dark,
        background: Color(digiHex: 0x000000), surface: Color(digiHex: 0x121212), raised: Color(digiHex: 0x1C1C1C),
        line: Color(digiHex: 0x333333), text: Color(digiHex: 0xFFFFFF), subtext: Color(digiHex: 0xB8B8B8),
        accent: Color(digiHex: 0xC6FF3D), onAccent: Color(digiHex: 0x000000),
        good: Color(digiHex: 0x3DDC84), warn: Color(digiHex: 0xFFC83D), bad: Color(digiHex: 0xFF4D4D),
        design: .default, width: .expanded, radius: 18)
#elseif BRAND_TALLY
    static let name = "Tally"
    static let tagline = "Quiet until it matters."
    static let nav = DigiNavStyle.menuBar
    static let toolNames = ["Status", "Backups", "Selects", "Exports", "Folders", "Report", "Contact Sheets", "Compare", "Metadata"]
    static let fixedTheme = DigiTheme(scheme: .dark,
        background: Color(digiHex: 0x111318), surface: Color(digiHex: 0x1A1D24), raised: Color(digiHex: 0x232733),
        line: Color(digiHex: 0x2E3340), text: Color(digiHex: 0xF1F3F7), subtext: Color(digiHex: 0xA3A9B6),
        accent: Color(digiHex: 0xFF4B4B), onAccent: Color(digiHex: 0xFFFFFF),
        good: Color(digiHex: 0x45D483), warn: Color(digiHex: 0xF7C948), bad: Color(digiHex: 0xFF8A3D),
        design: .rounded, width: .standard, radius: 14)
#else
    static let name = "Digi Suite"
    static let tagline = "(because it's sweet...)"
    static let nav = DigiNavStyle.classic
    static let toolNames = ["Dashboard", "Backups", "Selects List", "Processed Files Check", "Folder Maker", "Reports & Jobs", "Contact Sheets", "Folder Compare", "Metadata Watcher (BETA)"]
    static let fixedTheme = DigiTheme(scheme: .dark,
        background: Color(nsColor: .windowBackgroundColor), surface: Color(nsColor: .controlBackgroundColor), raised: Color(nsColor: .controlBackgroundColor),
        line: Color.primary.opacity(0.15), text: Color.primary, subtext: Color.secondary,
        accent: Color.accentColor, onAccent: Color.white,
        good: Color.green, warn: Color.yellow, bad: Color.red,
        design: .default, width: .standard, radius: 12)
#endif

    /// Color checker patches, one per tool (Wrap uses them as its tool colors).
    static let patches: [Color] = [
        Color(digiHex: 0x8E8E8E), Color(digiHex: 0xD67E2C), Color(digiHex: 0xE0A32E), Color(digiHex: 0x9DBC40),
        Color(digiHex: 0x67BDAA), Color(digiHex: 0x8580B1), Color(digiHex: 0xC15A63), Color(digiHex: 0x627A9D),
        Color(digiHex: 0xC29682)
    ]

#if BRAND_PROOF
    /// Proof lists its tools in shoot-day order, so Command-1 to Command-9
    /// follow the screen from left to right.
    static let defaultToolOrder: [Int] = [0, 4, 1, 7, 6, 3, 2, 8, 5]
#else
    /// v1.14: Jeff's order. Home/Status, Folders, Backups, Compare, Contact Sheets,
    /// Exports, Selects, Report, Metadata.
    static let defaultToolOrder: [Int] = [0, 4, 1, 7, 6, 3, 2, 5, 8]
#endif

    /// v1.25: tools switched off in this app for now. v1.42: Studio Session's
    /// Metadata tab is back (sidecar .xmp writer), so nothing is retired.
    static let retiredTools: Set<Int> = []

    /// v1.12: the person's own order (drag to rearrange), else the default.
    static var toolOrder: [Int] { DigiToolOrder.current().filter { !retiredTools.contains($0) } }

    /// Tools in on-screen order, leaving out any the person has hidden.
    static func visibleTools(hidden: Set<Int>) -> [DigiTool] {
        let all = tools
        return toolOrder.filter { !hidden.contains($0) }.map { all[$0] }
    }

    /// The Command-number for a tool: its place among the visible tools.
    static func shortcutNumber(_ tool: Int, hidden: Set<Int>) -> Int? {
        let order = toolOrder.filter { !hidden.contains($0) }
        guard let position = order.firstIndex(of: tool), position < 9 else { return nil }
        return position + 1
    }

    /// Menu bar icon when nothing is running, so you can tell the apps apart.
    static var menuBarSymbol: String {
        switch nav {
        case .sidebar: return "viewfinder"
        case .command: return "square.grid.3x2"
        case .timeline: return "scope"
        case .tiles: return "square.grid.2x2"
        case .menuBar: return "record.circle"
        case .classic: return "externaldrive.badge.checkmark"
        }
    }

    /// Tally plays sounds by default; the others start quiet. Everyone can switch it.
    static var soundsDefault: Bool { nav == .menuBar }

    static var isClassic: Bool { nav == .classic }

    /// The colors in use right now. Only Proof has a choice (Light, Dark, or
    /// Match System); every other app always uses its one look.
    static var theme: DigiTheme {
#if BRAND_PROOF
        return DigiAppearance.isDark ? darkTheme : fixedTheme
#else
        return fixedTheme
#endif
    }

    /// Proof is the only app with an appearance menu.
    static var hasAppearanceChoice: Bool { nav == .timeline }
    /// The five apps hide the system title bar; their top rows leave this
    /// much room for the window buttons.
    static var titleBarInset: CGFloat { isClassic ? 0 : 28 }
    static var tools: [DigiTool] {
        (0..<9).map { DigiTool(id: $0, name: toolNames[$0], icon: toolIcons[$0], blurb: toolBlurbs[$0]) }
    }
    static func toolName(_ index: Int) -> String {
        toolNames.indices.contains(index) ? toolNames[index] : ""
    }
    /// Card color used inside every tool. Classic keeps the system color.
    static var cardFill: Color { theme.surface }
    static var accent: Color { theme.accent }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        Font.system(size: size, weight: weight, design: theme.design).width(theme.width)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: theme.design)
    }
    static func numbers(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: First-launch tour

    static var tour: [DigiTourPage] {
        var pages: [DigiTourPage] = []
        pages.append(DigiTourPage(id: 0, icon: "sparkles", title: "Welcome to \(name)",
            body: welcomeLine, action: nil, actionTitle: ""))
        pages.append(DigiTourPage(id: 1, icon: "folder", title: "Start with your session",
            body: "Pick the folder you're shooting into, usually your Capture One session. \(name) looks through it and shows what's there. Nothing is moved or changed.",
            action: .openSession, actionTitle: "Choose Session Folder…"))
        pages.append(DigiTourPage(id: 2, icon: "externaldrive.badge.checkmark", title: "Back up to your drives",
            body: "Plug in one or more drives and pick them in \(toolName(1)). \(name) copies the whole session the first time, then only new and changed files. Up to four drives copy at the same time.",
            action: .showTool(1), actionTitle: "Show Me \(toolName(1))"))
        pages.append(DigiTourPage(id: 3, icon: "checkmark.shield", title: "Prove the copies match",
            body: "\(toolName(7)) lines up the session and every backup side by side. Green means it matches. Yellow means it's different. Red means it's missing.",
            action: .showTool(7), actionTitle: "Show Me \(toolName(7))"))
        pages.append(DigiTourPage(id: 4, icon: "folder.badge.plus", title: "Make folders in seconds",
            body: "Got a shot list in an email or a spreadsheet? Paste it or import it in \(toolName(4)) and every line becomes a folder. You see the folders before anything is made.",
            action: .showTool(4), actionTitle: "Show Me \(toolName(4))"))
        pages.append(DigiTourPage(id: 5, icon: "star", title: "Selects, sheets and the report",
            body: "\(toolName(2)) builds a list of the picks. \(toolName(6)) lays out pages to print or send. \(toolName(5)) writes up the day when you wrap.",
            action: nil, actionTitle: ""))
        pages.append(DigiTourPage(id: 6, icon: "hand.point.up.left", title: navTitle,
            body: navBody, action: nil, actionTitle: ""))
        pages.append(DigiTourPage(id: 7, icon: "checkmark.circle", title: "You're ready",
            body: "The question mark in the bottom right corner brings this tour back any time.",
            action: nil, actionTitle: ""))
        return pages
    }

#if BRAND_GRIP
    static let welcomeLine = "Studio Session keeps a shoot's files safe and organized, from the first frame to the wrap. This takes about a minute."
    static let navTitle = "Getting around"
    static let navBody = "Every tool is a tab across the top. Press Command and a number to jump: Command-1 is the first tab, Command-2 the next, and so on. Drag a tab sideways to rearrange, or off the bar to remove it. Add a removed tool back with the + at the end of the tabs."
#elseif BRAND_WRAP
    static let welcomeLine = "Wrap gets your shoot from first frame to that's-a-wrap without losing a file. Quick tour, promise."
    static let navTitle = "Every tool, one click"
    static let navBody = "The color patches across the top open every tool. Command-1 to Command-9 jump straight to them. Drag a patch sideways to rearrange, or down off the bar to remove it."
#elseif BRAND_PROOF
    static let welcomeLine = "Proof lays out a shoot day from left to right: dashboard, folders, back up, verify, selects, deliver, report. This takes about a minute."
    static let navTitle = "Follow the day"
    static let navBody = "The sections across the top follow the shape of a shoot. Click one to work in it, in any order. A check mark appears when Proof can confirm something is done. Drag a section sideways to rearrange, or down off the bar to remove it."
#elseif BRAND_TECHCART
    static let welcomeLine = "Tech Cart is built for the cart monitor: big buttons, big numbers, readable from across the set. This takes about a minute."
    static let navTitle = "Big buttons along the bottom"
    static let navBody = "Every tool is a big button along the bottom, each showing its live status. Click one to switch. The bar across the top always shows your backup, big enough to read from across the set."
#elseif BRAND_TALLY
    static let welcomeLine = "Tally lives in your menu bar and stays out of the way. When something needs you, it says so. This takes about a minute."
    static let navTitle = "Look up at the menu bar"
    static let navBody = "The Tally icon at the top of your screen shows your backups at a glance. Click it to start, pause or check a backup without opening a window. When a backup finishes you hear a chime; if something goes wrong you hear an alert. Turn sounds off from the menu bar icon. Drag a tool sideways to rearrange, or down off the bar to remove it."
#else
    static let welcomeLine = "Digi Suite keeps a shoot's files safe and organized."
    static let navTitle = "Getting around"
    static let navBody = "Every tool has a tab along the top."
#endif
}


/// v1.8: Proof's appearance setting: "light", "dark" or "system".
enum DigiAppearance {
    static let key = "Proof.appearance"

    static var setting: String {
        UserDefaults.standard.string(forKey: key) ?? "light"
    }

    /// v1.10: switch the whole app's look right away, before anything redraws,
    /// so standard controls never get drawn in the old look. Proof follows its
    /// setting; the other apps are always dark; classic Digi Suite follows the Mac.
    @MainActor static func apply(_ value: String) {
        let name: NSAppearance.Name?
        switch DigiBrand.nav {
        case .classic: name = nil
        case .timeline:
            if value == "dark" { name = .darkAqua } else if value == "light" { name = .aqua } else { name = nil }
        default: name = .darkAqua
        }
        if let name {
            NSApp.appearance = NSAppearance(named: name)
        } else {
            NSApp.appearance = nil
        }
    }

    static var isDark: Bool {
        switch setting {
        case "dark": return true
        case "system":
            // The Mac's own Light/Dark setting (no main-thread-only calls needed).
            return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        default: return false
        }
    }
}
