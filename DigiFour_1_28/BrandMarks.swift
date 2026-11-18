import SwiftUI

// Small drawn logos for each app's header, matching its Dock icon.

struct GripMark: View {
    var size: CGFloat = 26
    var body: some View {
        let t = DigiBrand.theme
        return Canvas { context, canvas in
            let s = canvas.width / 200
            let w = 16 * s
            var corners = Path()
            corners.move(to: CGPoint(x: 24 * s, y: 72 * s)); corners.addLine(to: CGPoint(x: 24 * s, y: 24 * s)); corners.addLine(to: CGPoint(x: 72 * s, y: 24 * s))
            corners.move(to: CGPoint(x: 128 * s, y: 176 * s)); corners.addLine(to: CGPoint(x: 176 * s, y: 176 * s)); corners.addLine(to: CGPoint(x: 176 * s, y: 128 * s))
            corners.move(to: CGPoint(x: 24 * s, y: 128 * s)); corners.addLine(to: CGPoint(x: 24 * s, y: 176 * s)); corners.addLine(to: CGPoint(x: 72 * s, y: 176 * s))
            context.stroke(corners, with: .color(t.text), style: StrokeStyle(lineWidth: w, lineCap: .square))
            let dot = Path(ellipseIn: CGRect(x: 124 * s, y: 20 * s, width: 56 * s, height: 56 * s))
            context.fill(dot, with: .color(t.accent))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct WrapMark: View {
    var size: CGFloat = 26
    var body: some View {
        let colors: [Color] = [DigiBrand.patches[1], DigiBrand.patches[2], DigiBrand.patches[3],
                               DigiBrand.patches[4], DigiBrand.patches[5], DigiBrand.patches[6]]
        let cell = size / 3.4
        return VStack(spacing: cell * 0.18) {
            HStack(spacing: cell * 0.18) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: cell * 0.15).fill(colors[i]).frame(width: cell, height: cell)
                }
            }
            HStack(spacing: cell * 0.18) {
                ForEach(3..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: cell * 0.15).fill(colors[i]).frame(width: cell, height: cell)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ProofMark: View {
    var size: CGFloat = 26
    var body: some View {
        let t = DigiBrand.theme
        return Canvas { context, canvas in
            let s = canvas.width / 150
            let ring = Path(ellipseIn: CGRect(x: 31 * s, y: 31 * s, width: 88 * s, height: 88 * s))
            context.stroke(ring, with: .color(t.text), lineWidth: 8 * s)
            var cross = Path()
            cross.move(to: CGPoint(x: 75 * s, y: 6 * s)); cross.addLine(to: CGPoint(x: 75 * s, y: 144 * s))
            cross.move(to: CGPoint(x: 6 * s, y: 75 * s)); cross.addLine(to: CGPoint(x: 144 * s, y: 75 * s))
            context.stroke(cross, with: .color(t.text), lineWidth: 8 * s)
            let dot = Path(ellipseIn: CGRect(x: 55 * s, y: 55 * s, width: 40 * s, height: 40 * s))
            context.fill(dot, with: .color(t.accent))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CartMark: View {
    var size: CGFloat = 26
    var body: some View {
        let t = DigiBrand.theme
        let cell = size * 0.44
        let gap = size * 0.12
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: cell * 0.22).fill(t.accent).frame(width: cell, height: cell)
                RoundedRectangle(cornerRadius: cell * 0.22).strokeBorder(t.text, lineWidth: max(1.5, size * 0.07)).frame(width: cell, height: cell)
            }
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: cell * 0.22).strokeBorder(t.text, lineWidth: max(1.5, size * 0.07)).frame(width: cell, height: cell)
                RoundedRectangle(cornerRadius: cell * 0.22).strokeBorder(t.text, lineWidth: max(1.5, size * 0.07)).frame(width: cell, height: cell)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct TallyLight: View {
    var color: Color
    var size: CGFloat = 26
    var glowing = true
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(glowing ? 0.25 : 0.12)).frame(width: size, height: size)
            Circle().fill(color).frame(width: size * 0.56, height: size * 0.56)
                .shadow(color: color.opacity(glowing ? 0.9 : 0), radius: size * 0.25)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The current app's mark, for shared places such as the menu bar panel.
struct DigiBrandMark: View {
    var size: CGFloat = 26
    var body: some View {
        switch DigiBrand.nav {
        case .sidebar: GripMark(size: size)
        case .command: WrapMark(size: size)
        case .timeline: ProofMark(size: size)
        case .tiles: CartMark(size: size)
        case .menuBar: TallyLight(color: DigiBrand.theme.accent, size: size)
        case .classic: Image(systemName: "externaldrive.badge.checkmark").font(.system(size: size * 0.7))
        }
    }
}
