import AppKit
import PDFKit
import ImageIO


struct JobReportOptions {
    var fontName = "Helvetica"
    var images = true
    var raw = true
    var jpeg = true
    var size = true
    var audits = true
    var folders = true
    var thumbnails = false
}

private struct JobFolder {
    let path: String
    let files: [Asset]
}

enum DigiJobReport {
    static func export(root: URL, assets: [Asset], reportName: String,
                       results: [CheckResult], options: JobReportOptions, to url: URL) -> Bool {
        let pageSize = NSSize(width: 612, height: 792)
        let pdf = PDFDocument()
        let font = NSFont(name: options.fontName, size: 11) ?? .systemFont(ofSize: 11)
        let heading = NSFont(name: options.fontName, size: 19) ?? .boldSystemFont(ofSize: 19)
        let rawExtensions: Set<String> = ["iiq","cr2","cr3","nef","nrw","arw","raf","orf","rw2","dng","3fr","fff","mos","pef","srw","rwl","raw"]
        let rawCount = assets.filter { rawExtensions.contains($0.url.pathExtension.lowercased()) }.count
        let jpegCount = assets.filter { ["jpg","jpeg"].contains($0.url.pathExtension.lowercased()) }.count
        let capture = root.appendingPathComponent("Capture", isDirectory: true)
        let isCapture = (try? capture.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let base = isCapture ? capture : root
        let groups = Dictionary(grouping: assets.filter { $0.url.path.hasPrefix(base.path + "/") }) { asset in
            let parent = asset.url.deletingLastPathComponent().path
            let relative = String(parent.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? "(Capture root)" : relative
        }
        let folders: [JobFolder] = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            JobFolder(path: key, files: (groups[key] ?? []).sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending })
        }

        // v1.32: graded folder thumbnails. QuickProof (and any export) writes
        // graded JPEGs into the session's Output folder with the same base name
        // as the raw. Index them once (by lowercased stem) so each folder's
        // thumbnail can prefer the graded proof and fall back to the raw's own
        // embedded preview when a frame hasn't been proofed yet. These are normal
        // JPEGs, so nothing has to decode Capture One's JPEG XL proxies.
        var proofByStem: [String: URL] = [:]
        let proofExtensions: Set<String> = ["jpg","jpeg","heic","heif","png","tif","tiff"]
        let outputFolder = root.appendingPathComponent("Output", isDirectory: true)
        if let walker = FileManager.default.enumerator(at: outputFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let item as URL in walker {
                guard proofExtensions.contains(item.pathExtension.lowercased()) else { continue }
                let stem = item.deletingPathExtension().lastPathComponent.lowercased()
                if proofByStem[stem] == nil { proofByStem[stem] = item }
            }
        }

        // Editorial report layout: running page header/footer, metric tiles,
        // and a two-column gallery of Capture folders.
        let ink = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.21, alpha: 1)
        let muted = NSColor(calibratedRed: 0.42, green: 0.46, blue: 0.51, alpha: 1)
        let accent = NSColor(calibratedRed: 0.13, green: 0.39, blue: 0.72, alpha: 1)
        let panel = NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.98, alpha: 1)
        let border = NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.93, alpha: 1)
        let bodyFont = NSFont(name: options.fontName, size: 10.5) ?? font
        let smallFont = NSFont(name: options.fontName, size: 8.5) ?? .systemFont(ofSize: 8.5)
        let boldFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        let titleFont = NSFontManager.shared.convert(NSFont(name: options.fontName, size: 23) ?? heading, toHaveTrait: .boldFontMask)
        let sectionFont = NSFontManager.shared.convert(NSFont(name: options.fontName, size: 13) ?? heading, toHaveTrait: .boldFontMask)
        let margin: CGFloat = 43
        let contentWidth: CGFloat = 526
        let cardGap: CGFloat = 12
        let cardWidth = (contentWidth - cardGap) / 2
        var pageIndex = 0
        var y: CGFloat = 0
        var pageImage = NSImage(size: pageSize)

        func drawText(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat,
                      font: NSFont, color: NSColor = NSColor.black,
                      maxHeight: CGFloat = 500) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let str = NSAttributedString(string: text, attributes: attrs)
            let bounds = str.boundingRect(with: NSSize(width: width, height: maxHeight),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
            let h = min(maxHeight, max(ceil(bounds.height) + 3, font.pointSize + 4))
            str.draw(with: NSRect(x: x, y: top - h, width: width, height: h),
                     options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            return h
        }
        func startPage() {
            pageImage = NSImage(size: pageSize)
            pageImage.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: pageSize).fill()
            accent.setFill()
            NSRect(x: 0, y: 784, width: 612, height: 8).fill()
            _ = drawText("DIGITOOLS  /  JOB REPORT", x: margin, top: 766, width: 380,
                         font: smallFont, color: muted)
            border.setStroke()
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: margin, y: 742))
            rule.line(to: NSPoint(x: 569, y: 742))
            rule.stroke()
            y = 726
        }
        func endPage() {
            border.setStroke()
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: margin, y: 42))
            rule.line(to: NSPoint(x: 569, y: 42))
            rule.stroke()
            _ = drawText(reportName, x: margin, top: 33, width: 430,
                         font: smallFont, color: muted)
            _ = drawText("PAGE \(pageIndex + 1)", x: 500, top: 33, width: 70,
                         font: smallFont, color: muted)
            pageImage.unlockFocus()
            if let page = PDFPage(image: pageImage) {
                pdf.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }
        func ensureSpace(_ height: CGFloat) {
            if y - height < 60 {
                endPage()
                startPage()
            }
        }
        func sectionTitle(_ text: String) {
            ensureSpace(38)
            y -= 13
            let h = drawText(text.uppercased(), x: margin, top: y,
                             width: contentWidth, font: sectionFont, color: ink)
            y -= h + 11
        }
        func detail(_ label: String, _ value: String) {
            let h = drawText(label.uppercased(), x: margin, top: y, width: 100,
                             font: smallFont, color: muted)
            let vh = drawText(value, x: margin + 104, top: y, width: contentWidth - 104,
                              font: bodyFont, color: ink)
            y -= max(h, vh) + 9
        }
        startPage()
        y -= 9
        y -= drawText(reportName, x: margin, top: y, width: contentWidth,
                      font: titleFont, color: ink) + 5
        y -= drawText(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short),
                      x: margin, top: y, width: contentWidth, font: bodyFont, color: muted) + 20

        // Source is always included, regardless of report options.
        ensureSpace(65)
        panel.setFill()
        NSBezierPath(roundedRect: NSRect(x: margin, y: y - 57, width: contentWidth, height: 57),
                     xRadius: 7, yRadius: 7).fill()
        _ = drawText("SOURCE", x: margin + 13, top: y - 10,
                     width: 140, font: smallFont, color: muted)
        _ = drawText(root.path, x: margin + 13, top: y - 27,
                     width: contentWidth - 26, font: bodyFont, color: ink, maxHeight: 26)
        y -= 73

        var metrics: [(String, String)] = []
        if options.images { metrics.append(("TOTAL IMAGES", assets.count.formatted())) }
        if options.raw { metrics.append(("RAW FILES", rawCount.formatted())) }
        if options.jpeg { metrics.append(("JPEG FILES", jpegCount.formatted())) }
        if options.size {
            let bytes = assets.reduce(Int64(0)) { $0 + $1.size }
            metrics.append(("IMAGE DATA", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        if !metrics.isEmpty {
            sectionTitle("Session overview")
            let cols = min(4, metrics.count)
            let gap: CGFloat = 8
            let width = (contentWidth - CGFloat(cols - 1) * gap) / CGFloat(cols)
            for (index, metric) in metrics.enumerated() {
                if index > 0 && index % cols == 0 { y -= 77 }
                let x = margin + CGFloat(index % cols) * (width + gap)
                panel.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y - 65, width: width, height: 65),
                             xRadius: 7, yRadius: 7).fill()
                _ = drawText(metric.1, x: x + 11, top: y - 12, width: width - 20,
                             font: sectionFont, color: ink)
                _ = drawText(metric.0, x: x + 11, top: y - 38, width: width - 20,
                             font: smallFont, color: muted)
            }
            y -= 78
        }

        if options.audits && !results.isEmpty {
            sectionTitle("Audit results")
            for result in results {
                ensureSpace(45)
                let status = result.good ? "PASS" : "REVIEW"
                let statusColor = result.good
                    ? NSColor(calibratedRed: 0.12, green: 0.47, blue: 0.34, alpha: 1)
                    : NSColor(calibratedRed: 0.72, green: 0.37, blue: 0.10, alpha: 1)
                _ = drawText(status, x: margin, top: y, width: 57,
                             font: smallFont, color: statusColor)
                let message = "\(result.label): \(result.detail)"
                let h = drawText(message, x: margin + 63, top: y,
                                 width: contentWidth - 63, font: bodyFont, color: ink)
                y -= max(22, h + 9)
            }
        }

        if options.folders {
            sectionTitle("Capture folders  /  \(folders.count)")
            // Each card is a cohesive unit: no orphaned labels or thumbnails
            // at page breaks. Two columns reduce page count and wasted space.
            let cardHeight: CGFloat = options.thumbnails ? 177 : 74
            for pairStart in stride(from: 0, to: folders.count, by: 2) {
                ensureSpace(cardHeight + 12)
                for column in 0..<2 {
                    let index = pairStart + column
                    guard index < folders.count else { continue }
                    let folder = folders[index]
                    let x = margin + CGFloat(column) * (cardWidth + cardGap)
                    let bottom = y - cardHeight
                    panel.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: bottom,
                                                     width: cardWidth, height: cardHeight),
                                 xRadius: 8, yRadius: 8).fill()
                    let pathHeight = drawText(folder.path, x: x + 12, top: y - 11,
                                              width: cardWidth - 24,
                                              font: boldFont, color: ink, maxHeight: 37)
                    _ = drawText("\(folder.files.count.formatted()) images",
                                 x: x + 12, top: y - 12 - pathHeight,
                                 width: cardWidth - 24, font: smallFont, color: muted)
                    if options.thumbnails && !folder.files.isEmpty {
                        let middle = folder.files.count / 2
                        let order = folder.files.indices.sorted {
                            abs($0 - middle) < abs($1 - middle)
                        }
                        let imageArea = NSRect(x: x + 12, y: bottom + 12,
                                               width: cardWidth - 24, height: 101)
                        border.setFill()
                        NSBezierPath(roundedRect: imageArea, xRadius: 5, yRadius: 5).fill()
                        var rendered = false
                        for candidate in order {
                            let file = folder.files[candidate].url
                            // v1.32: prefer the graded QuickProof JPEG from Output when
                            // one exists (same base name); otherwise the raw's own
                            // embedded preview. Capture One's JPEG XL proxies are not
                            // decodable by macOS, so we never touch them.
                            let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                            let imageURL = proofByStem[stem] ?? file
                            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { continue }
                            let properties: [CFString: Any] = [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceThumbnailMaxPixelSize: 420,
                                kCGImageSourceCreateThumbnailWithTransform: true
                            ]
                            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, properties as CFDictionary)
                                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                            let scale = min(imageArea.width / CGFloat(cg.width),
                                            imageArea.height / CGFloat(cg.height))
                            let w = CGFloat(cg.width) * scale
                            let h = CGFloat(cg.height) * scale
                            let destination = CGRect(x: imageArea.midX - w / 2,
                                                     y: imageArea.midY - h / 2,
                                                     width: w, height: h)
                            // Render into the active page graphics context instead of
                            // nesting NSImage drawing, which could omit the image in PDFPage.
                            if let context = NSGraphicsContext.current?.cgContext {
                                context.saveGState()
                                context.interpolationQuality = .high
                                context.draw(cg, in: destination)
                                context.restoreGState()
                                rendered = true
                                break
                            }
                        }
                        if !rendered {
                            _ = drawText("Preview unavailable", x: imageArea.minX + 10,
                                         top: imageArea.midY + 8,
                                         width: imageArea.width - 20,
                                         font: smallFont, color: muted)
                        }
                    }
                }
                y -= cardHeight + 12
            }
        }
        endPage()
        return pdf.write(to: url)
    }
}
