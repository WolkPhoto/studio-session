import SwiftUI
import Foundation

struct SessionCompositionView: View {
    let summary: SessionStorageSummary
    let scanning: Bool
    @State private var metric = 0
    @State private var expanded: Set<String> = []
    private let colors: [String: Color] = [
        "RAW Images": .blue, "JPEG Images": .purple, "Other Images": .pink,
        "Capture One Data": .orange, "Session Files": .teal,
        "Video": .green, "Other Files": .gray
    ]
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func fraction(_ category: SessionStorageCategory) -> Double {
        metric == 0 ? Double(category.bytes) / Double(max(1, summary.bytes)) : Double(category.count) / Double(max(1, summary.count))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Session composition").font(.headline)
                    Text("The sweet spot between file counts and storage.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Measure", selection: $metric) {
                    Text("Storage Size").tag(0)
                    Text("File Count").tag(1)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 270)
            }
            if scanning { ProgressView("Inventorying all session files…").font(.caption) }
            HStack(alignment: .firstTextBaseline) {
                Text(metric == 0 ? bytes(summary.bytes) : summary.count.formatted())
                    .font(.system(size: 27, weight: .bold, design: .rounded)).monospacedDigit()
                Spacer()
                Text(metric == 0 ? "\(summary.count.formatted()) files total" : "\(bytes(summary.bytes)) total")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if summary.categories.isEmpty {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                    } else {
                        ForEach(summary.categories) { category in
                            let portion = fraction(category)
                            if portion > 0 {
                                Rectangle().fill(colors[category.name] ?? .gray)
                                    .frame(width: max(0, (geo.size.width - CGFloat(max(0, summary.categories.count - 1)) * 2) * portion))
                                    .help("\(category.name): \(bytes(category.bytes)), \(category.count) files")
                            }
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 5))
            }.frame(height: 17)
            ForEach(summary.categories) { category in
                VStack(spacing: 7) {
                    Button {
                        if expanded.contains(category.name) { expanded.remove(category.name) }
                        else { expanded.insert(category.name) }
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(colors[category.name] ?? .gray).frame(width: 10, height: 10)
                            Text(category.name).font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(category.count.formatted()) files").font(.caption).foregroundStyle(.secondary)
                            Text(bytes(category.bytes)).font(.subheadline.monospacedDigit()).frame(minWidth: 85, alignment: .trailing)
                            Image(systemName: expanded.contains(category.name) ? "chevron.up" : "chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if expanded.contains(category.name) {
                        ForEach(Array(category.formats.enumerated()), id: \.offset) { _, format in
                            HStack {
                                Text(format.0).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(format.1.formatted()) files").font(.caption).foregroundStyle(.secondary)
                                Text(bytes(format.2)).font(.caption.monospacedDigit()).frame(minWidth: 85, alignment: .trailing)
                            }.padding(.leading, 22)
                        }
                    }
                }
                if category.id != summary.categories.last?.id { Divider().opacity(0.35) }
            }
            if summary.categories.isEmpty && !scanning {
                Text("Choose a shoot session to see its complete storage breakdown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(DigiBrand.cardFill, in: RoundedRectangle(cornerRadius: 13))
    }
}
