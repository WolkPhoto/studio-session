import SwiftUI

@main struct StudioSessionRemoteApp: App {
    @StateObject private var store = RemoteStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if store.paired == nil {
                    PairView()
                } else {
                    StatusView()
                }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { store.startPolling() } else { store.stopPolling() }
            }
        }
    }
}

/// Studio Session's studio look: graphite and tungsten orange.
enum Theme {
    static let background = Color(hex: 0x0E0F10)
    static let surface = Color(hex: 0x17191B)
    static let raised = Color(hex: 0x1E2124)
    static let line = Color(hex: 0x2A2D31)
    static let text = Color(hex: 0xECEAE4)
    static let subtext = Color(hex: 0x9A9EA4)
    static let accent = Color(hex: 0xF2A93B)
    static let onAccent = Color(hex: 0x0E0F10)
    static let good = Color(hex: 0x5BD08A)
    static let warn = Color(hex: 0xF5D061)
    static let bad = Color(hex: 0xFF6B5E)
    /// One color per drive by its place in the Mac's list, same as the Mac app.
    static let drives: [Color] = [Color(hex: 0x5B9CF5), Color(hex: 0xB48CF2), Color(hex: 0x3FC1B0), Color(hex: 0xF28BB8)]
    static func drive(_ index: Int) -> Color { drives[index % drives.count] }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct ColorBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(color)
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}
