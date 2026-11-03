import AppKit
import UniformTypeIdentifiers
import os

/// File-kind icons for the list views. Kinds whose app ships its own document icon (Office, Adobe,
/// Xcode sources, …) keep that official icon; the rest get a drawn sheet with kind-specific content and
/// the default app's icon as a badge. Folders, apps, packages and links keep the system icons.
enum ColorfulFileIcon {
    enum Category: String {
        case pdf, word, spreadsheet, presentation, image, video, audio, archive, diskImage
        case code, text, font, web, other
    }

    private static let enabled = OSAllocatedUnfairLock(initialState: true)

    static var isEnabled: Bool {
        get { enabled.withLock { $0 } }
        set { enabled.withLock { $0 = newValue } }
    }

    /// The icon for the item, or nil when the system icon should be used.
    static func image(for item: FileItem) -> NSImage? {
        guard isEnabled,
              !item.isDirectory, !item.isPackage, !item.isSymbolicLink, !item.isAliasFile,
              item.fileType != .application, item.fileType != .folder,
              item.url.isFileURL || item.isFromArchive else { return nil }
        let ext = item.url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        _ = startObservingChanges
        if let hit = byExtension.withLock({ $0[ext] }) { return hit }
        let image = resolve(ext: ext)
        byExtension.withLock { $0[ext] = image }
        return image
    }

    // MARK: - Cache

    /// Extension → icon (a lookup shortcut) and "app|type" → icon. Dropped when the app becomes active
    /// (the default app may have been changed elsewhere) and when the system appearance changes.
    private static let byExtension = OSAllocatedUnfairLock(initialState: [String: NSImage]())
    private static let byAppAndType = OSAllocatedUnfairLock(initialState: [String: NSImage]())
    private static let bundleInfo = OSAllocatedUnfairLock(initialState: [String: [String: Any]]())

    private static let startObservingChanges: Void = {
        let flush: (Notification) -> Void = { _ in
            byExtension.withLock { $0.removeAll() }
            byAppAndType.withLock { $0.removeAll() }
            bundleInfo.withLock { $0.removeAll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil, using: flush)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: nil, using: flush)
    }()

    // MARK: - Resolution

    private static func resolve(ext: String) -> NSImage {
        let type = UTType(filenameExtension: ext) ?? .data
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: type)
        let key = "\(defaultApp?.path ?? "-")|\(type.identifier)|\(type.isDynamic ? ext : "")"
        if let hit = byAppAndType.withLock({ $0[key] }) { return hit }

        let image: NSImage
        if let app = defaultApp, hasOwnDocumentIcon(app: app, type: type, ext: ext) {
            image = fittedToSystemSheet(NSWorkspace.shared.icon(for: type))
        } else if let vendorIcon = vendorDocumentIcon(type: type, ext: ext) {
            image = fittedToSystemSheet(vendorIcon)
        } else {
            let badge = defaultApp.map { NSWorkspace.shared.icon(forFile: $0.path) }
            image = drawnIcon(category: category(for: type, ext: ext), ext: ext, badge: badge)
        }
        byAppAndType.withLock { $0[key] = image }
        return image
    }

    private static func info(of app: URL) -> [String: Any] {
        if let hit = bundleInfo.withLock({ $0[app.path] }) { return hit }
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        bundleInfo.withLock { $0[app.path] = plist }
        return plist
    }

    /// The icon resource the app declares for the type, when it declares its own artwork
    /// (not one the system composes from the app icon).
    private static func documentIconName(app: URL, type: UTType, ext: String) -> String? {
        let plist = info(of: app)
        let identifier = type.identifier.lowercased()
        for entry in plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            let types = (entry["LSItemContentTypes"] as? [String] ?? []).map { $0.lowercased() }
            let exts = (entry["CFBundleTypeExtensions"] as? [String] ?? []).map { $0.lowercased() }
            guard types.contains(identifier) || exts.contains(ext) else { continue }
            if (entry["CFBundleTypeIconSystemGenerated"] as? NSNumber)?.boolValue == true { return nil }
            if let name = (entry["CFBundleTypeIconFile"] ?? entry["CFBundleTypeIconName"]) as? String, !name.isEmpty {
                return name
            }
        }
        // A badge that is just the app icon on a plain sheet is the generic look, not own artwork.
        let appIconNames = Set(([plist["CFBundleIconFile"], plist["CFBundleIconName"]] as [Any?])
            .compactMap { ($0 as? String).map { ($0 as NSString).deletingPathExtension.lowercased() } } + ["icon", "appicon"])
        for key in ["UTExportedTypeDeclarations", "UTImportedTypeDeclarations"] {
            for decl in plist[key] as? [[String: Any]] ?? [] where (decl["UTTypeIdentifier"] as? String)?.lowercased() == identifier {
                if let name = (decl["UTTypeIconFile"] ?? decl["UTTypeIconName"]) as? String, !name.isEmpty { return name }
                guard let icons = decl["UTTypeIcons"] as? [String: Any] else { continue }
                for iconKey in ["UTTypeIconFile", "UTTypeIconBackgroundName", "UTTypeIconBadgeName"] {
                    if let name = icons[iconKey] as? String, !name.isEmpty,
                       !appIconNames.contains((name as NSString).deletingPathExtension.lowercased()) {
                        return name
                    }
                }
            }
        }
        return nil
    }

    private static func hasOwnDocumentIcon(app: URL, type: UTType, ext: String) -> Bool {
        documentIconName(app: app, type: type, ext: ext) != nil
    }

    /// Bundle-ID prefixes of the vendor whose apps own a type (e.g. Acrobat for PDF while Preview is the default).
    private static func vendorPrefix(for type: UTType) -> String? {
        let id = type.identifier.lowercased()
        if id.hasPrefix("com.adobe.") { return "com.adobe." }
        if id.hasPrefix("com.microsoft.") || id.hasPrefix("org.openxmlformats.") { return "com.microsoft." }
        if id.hasPrefix("com.apple.iwork.") { return "com.apple.iwork." }
        return nil
    }

    private static func vendorDocumentIcon(type: UTType, ext: String) -> NSImage? {
        guard let prefix = vendorPrefix(for: type) else { return nil }
        for app in NSWorkspace.shared.urlsForApplications(toOpen: type) {
            guard let bundle = Bundle(url: app),
                  bundle.bundleIdentifier?.lowercased().hasPrefix(prefix) == true,
                  let name = documentIconName(app: app, type: type, ext: ext) else { continue }
            let base = (name as NSString).deletingPathExtension
            if let url = bundle.url(forResource: base, withExtension: "icns"), let image = NSImage(contentsOf: url) {
                return image
            }
            if let image = bundle.image(forResource: base) { return image }
        }
        return nil
    }

    // MARK: - Sheet alignment

    /// The sheet of the system's document icons as a fraction of the square canvas, centered
    /// (measured from `NSWorkspace.icon(for: .data)`: 0.64 × 0.86 from 32 pt up, 0.69 × 0.875 at 16 pt).
    private static let sheetSize = CGSize(width: 0.64, height: 0.86)
    private static let smallSheetSize = CGSize(width: 0.6875, height: 0.875)

    /// Apps' own document icons differ in sheet size and position (Acrobat's is larger, VS Code's
    /// sits higher). Scales a portrait sheet to the system sheet's height and centers it, keeping the
    /// aspect ratio; other shapes (e.g. Office's newer cards) are only centered.
    private static func fittedToSystemSheet(_ image: NSImage) -> NSImage {
        let px = 256
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()

        // Rows from the top.
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        func opaque(_ x: Int, _ y: Int) -> Bool { bytes[y * px * 4 + x * 4 + 3] > 128 }
        var minX = px, maxX = -1, minY = px, maxY = -1
        for y in 0..<px { for x in 0..<px where opaque(x, y) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return image }

        // The sheet, away from badges (lower corners): its height along a column left of center,
        // its width along a row a little above its middle.
        let column = minX + (maxX - minX) * 3 / 10
        let ys = (0..<px).filter { opaque(column, $0) }
        guard let top = ys.first, let bottom = ys.last else { return image }
        let row = top + (bottom - top) * 45 / 100
        let xs = (0..<px).filter { opaque($0, row) }
        guard let left = xs.first, let right = xs.last else { return image }
        let unit = CGFloat(px)
        let sheetH = CGFloat(bottom - top + 1) / unit
        let sheetW = CGFloat(right - left + 1) / unit

        let scale: CGFloat
        let center: CGPoint
        if sheetH >= sheetW * 1.15 {
            scale = min(max(sheetSize.height / sheetH, 0.8), 1.1)
            center = CGPoint(x: CGFloat(left + right + 1) / 2 / unit, y: CGFloat(top + bottom + 1) / 2 / unit)
        } else {
            scale = 1
            center = CGPoint(x: CGFloat(minX + maxX + 1) / 2 / unit, y: CGFloat(minY + maxY + 1) / 2 / unit)
        }
        guard abs(scale - 1) > 0.02 || abs(center.x - 0.5) > 0.012 || abs(center.y - 0.5) > 0.012 else { return image }

        let originX = 0.5 - scale * center.x
        let originTop = 0.5 - scale * center.y
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: NSRect(x: rect.minX + originX * rect.width, y: rect.minY + (1 - originTop - scale) * rect.height,
                                  width: scale * rect.width, height: scale * rect.height))
            return true
        }
    }

    // MARK: - Thumbnails

    /// Images and movies show their own thumbnail in the list views instead of the kind icon.
    static func prefersThumbnail(for item: FileItem) -> Bool {
        guard !item.isDirectory, !item.isPackage else { return false }
        let ext = item.url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// A small thumbnail as Finder's list shows it: rounded corners and a thin outline (aspect kept).
    static func listThumbnail(_ image: NSImage) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        return NSImage(size: size, flipped: false) { rect in
            let side = max(rect.width, rect.height)
            let line = side * 0.025
            let frame = rect.insetBy(dx: line / 2, dy: line / 2)
            let path = NSBezierPath(roundedRect: frame, xRadius: side * 0.08, yRadius: side * 0.08)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: frame, from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            path.lineWidth = line
            NSColor.black.withAlphaComponent(0.22).setStroke()
            path.stroke()
            return true
        }
    }

    // MARK: - Classification

    private static let explicit: [String: Category] = {
        var map: [String: Category] = [:]
        func add(_ category: Category, _ exts: String) {
            for ext in exts.split(separator: " ") { map[String(ext)] = category }
        }
        add(.pdf, "pdf")
        add(.word, "doc docx dot dotx docm pages rtf rtfd odt")
        add(.spreadsheet, "xls xlsx xlsm xlsb numbers csv tsv ods")
        add(.presentation, "ppt pptx pps ppsx key odp")
        add(.archive, "zip rar 7z tar gz tgz bz2 xz zst lz lzma cab z jar war")
        add(.diskImage, "dmg iso img pkg mpkg toast cdr")
        add(.code, "json yaml yml toml xml plist sh zsh bash swift py js ts tsx jsx c h m mm cpp hpp cc java kt go rs rb php css scss sql lua pl r gradle")
        add(.text, "txt md markdown log text rst")
        add(.font, "ttf otf ttc woff woff2 dfont")
        add(.web, "html htm xhtml webloc url")
        return map
    }()

    static func category(forExtension ext: String) -> Category {
        guard !ext.isEmpty else { return .other }
        return category(for: UTType(filenameExtension: ext) ?? .data, ext: ext)
    }

    private static func category(for type: UTType, ext: String) -> Category {
        if let hit = explicit[ext] { return hit }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .font) { return .font }
        if type.conforms(to: .html) { return .web }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .plainText) || type.conforms(to: .text) { return .text }
        return .other
    }

    // MARK: - Style

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    private static func accent(for category: Category) -> NSColor {
        switch category {
        case .pdf: return rgb(229, 57, 53)
        case .image: return rgb(52, 178, 92)
        case .video: return rgb(142, 84, 214)
        case .audio: return rgb(236, 64, 122)
        case .archive: return rgb(166, 112, 64)
        case .code: return rgb(88, 86, 214)
        case .text: return rgb(120, 124, 132)
        case .word: return rgb(43, 108, 222)
        case .spreadsheet: return rgb(30, 140, 80)
        case .presentation: return rgb(240, 120, 30)
        case .diskImage: return rgb(120, 128, 140)
        case .font: return rgb(20, 150, 160)
        case .web: return rgb(10, 132, 255)
        case .other: return rgb(130, 134, 142)
        }
    }

    // MARK: - Drawing

    private static func drawnIcon(category: Category, ext: String, badge: NSImage?) -> NSImage {
        let label = String(ext.uppercased().prefix(5))
        let color = accent(for: category)
        // One representation per size, so small sizes get their own simplified layout.
        let image = NSImage(size: NSSize(width: 128, height: 128))
        for points in [16, 24, 32, 48, 64, 128, 256] as [CGFloat] {
            let rep = NSCustomImageRep(size: NSSize(width: points, height: points), flipped: false) { rect in
                drawIcon(in: rect, points: points, category: category, color: color, label: label, badge: badge)
            }
            rep.pixelsWide = Int(points * 2)
            rep.pixelsHigh = Int(points * 2)
            image.addRepresentation(rep)
        }
        return image
    }

    private static func drawIcon(in rect: NSRect, points: CGFloat, category: Category, color: NSColor, label: String, badge: NSImage?) -> Bool {
        let unit = rect.width / points
        let small = points < 26
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        let sheet = small ? smallSheetSize : sheetSize
        let docH = rect.height * sheet.height
        let docW = rect.width * sheet.width
        let doc = NSRect(x: rect.midX - docW / 2, y: rect.midY - docH / 2, width: docW, height: docH)
        drawPaper(doc, unit: unit, isDark: isDark)

        let fold = doc.width * 0.26
        let badgeSide = badge == nil ? 0 : (small ? rect.width * 0.62 : doc.width * (points < 50 ? 0.6 : 0.5))
        if !small {
            let bottom = doc.height * (badge == nil ? 0.3 : 0.12)
            let content = NSRect(x: doc.minX + doc.width * 0.15, y: doc.minY + bottom,
                                 width: doc.width * 0.70, height: doc.height - fold - bottom - doc.height * 0.06)
            drawContent(category, in: content, color: color, unit: unit, hasBadge: badge != nil)
        }

        if let badge {
            let side = badgeSide
            let frame = NSRect(x: min(doc.maxX - side * (small ? 0.75 : 0.62), rect.maxX - side * 0.96), y: max(doc.minY - side * 0.16, rect.minY - side * 0.04),
                               width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowOffset = NSSize(width: 0, height: -unit * 0.6)
            shadow.shadowBlurRadius = unit * 1.2
            shadow.set()
            badge.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            if points >= 40 {
                drawLabel(label, color: color, in: NSRect(x: doc.minX + doc.width * 0.12, y: doc.minY + doc.height * 0.05,
                                                          width: frame.minX - doc.minX - doc.width * 0.14, height: doc.height * 0.1),
                          unit: unit, alignLeft: true)
            }
        } else {
            let band = NSRect(x: doc.minX + doc.width * 0.08, y: doc.minY + doc.height * (small ? 0.1 : 0.06),
                              width: doc.width * 0.84, height: doc.height * (small ? 0.36 : 0.2))
            drawLabel(label, color: color, in: band, unit: unit, alignLeft: false)
        }
        return true
    }

    private static func drawPaper(_ doc: NSRect, unit: CGFloat, isDark: Bool) {
        let radius = doc.width * 0.08
        let fold = doc.width * 0.26
        let path = NSBezierPath()
        path.move(to: NSPoint(x: doc.minX + radius, y: doc.minY))
        path.line(to: NSPoint(x: doc.maxX - radius, y: doc.minY))
        path.appendArc(from: NSPoint(x: doc.maxX, y: doc.minY), to: NSPoint(x: doc.maxX, y: doc.minY + radius), radius: radius)
        path.line(to: NSPoint(x: doc.maxX, y: doc.maxY - fold))
        path.line(to: NSPoint(x: doc.maxX - fold, y: doc.maxY))
        path.line(to: NSPoint(x: doc.minX + radius, y: doc.maxY))
        path.appendArc(from: NSPoint(x: doc.minX, y: doc.maxY), to: NSPoint(x: doc.minX, y: doc.maxY - radius), radius: radius)
        path.line(to: NSPoint(x: doc.minX, y: doc.minY + radius))
        path.appendArc(from: NSPoint(x: doc.minX, y: doc.minY), to: NSPoint(x: doc.minX + radius, y: doc.minY), radius: radius)
        path.close()

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -unit * 0.5)
        shadow.shadowBlurRadius = unit * 1.5
        shadow.set()
        (isDark ? rgb(236, 237, 240) : NSColor.white).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: rgb(0, 0, 0, isDark ? 0.08 : 0.04))?
            .draw(in: doc, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        path.lineWidth = max(unit * 0.5, doc.width * 0.008)
        path.lineJoinStyle = .round
        rgb(0, 0, 0, isDark ? 0.35 : 0.16).setStroke()
        path.stroke()

        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: doc.maxX - fold, y: doc.maxY))
        corner.line(to: NSPoint(x: doc.maxX - fold, y: doc.maxY - fold + radius * 0.6))
        corner.appendArc(from: NSPoint(x: doc.maxX - fold, y: doc.maxY - fold),
                         to: NSPoint(x: doc.maxX - fold + radius * 0.6, y: doc.maxY - fold), radius: radius * 0.6)
        corner.line(to: NSPoint(x: doc.maxX, y: doc.maxY - fold))
        corner.close()
        NSGradient(starting: rgb(226, 228, 232), ending: rgb(246, 247, 249))?
            .draw(in: corner, angle: -45)
        corner.lineWidth = path.lineWidth
        corner.lineJoinStyle = .round
        rgb(0, 0, 0, isDark ? 0.3 : 0.14).setStroke()
        corner.stroke()
    }

    private static func roundedBar(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private static func drawContent(_ category: Category, in area: NSRect, color: NSColor, unit: CGFloat, hasBadge: Bool) {
        let lineGray = rgb(196, 199, 206)
        // Leave the lower right free for the badge.
        let rightLimit: (CGFloat) -> CGFloat = { y in
            hasBadge && y < area.minY + area.height * 0.38 ? area.width * 0.42 : area.width
        }
        switch category {
        case .code, .web:
            let palette = category == .web
                ? [rgb(10, 132, 255), rgb(255, 149, 0), rgb(52, 199, 89)]
                : [rgb(175, 82, 222), rgb(10, 132, 255), rgb(255, 149, 0), rgb(52, 199, 89), rgb(255, 55, 95)]
            let pattern: [(indent: CGFloat, parts: [CGFloat])] = [
                (0, [0.30, 0.42]), (0.14, [0.22, 0.36]), (0.14, [0.46]), (0.28, [0.20, 0.30]),
                (0.14, [0.34]), (0, [0.16]), (0, [0.26, 0.38]),
            ]
            let barH = area.height * 0.065
            let step = area.height / CGFloat(pattern.count)
            var colorIndex = 0
            for (row, line) in pattern.enumerated() {
                let y = area.maxY - step * (CGFloat(row) + 0.5) - barH / 2
                var x = area.minX + area.width * line.indent
                for part in line.parts {
                    let w = area.width * part
                    guard x + w - area.minX <= rightLimit(y) else { break }
                    roundedBar(NSRect(x: x, y: y, width: w, height: barH), palette[colorIndex % palette.count])
                    colorIndex += 1
                    x += w + area.width * 0.06
                }
            }
        case .text, .word, .pdf, .other:
            let barH = area.height * 0.055
            let count = 7
            let step = area.height / CGFloat(count)
            let widths: [CGFloat] = [0.55, 1, 0.92, 0.97, 0.7, 0.95, 0.6]
            for row in 0..<count {
                let y = area.maxY - step * (CGFloat(row) + 0.5) - barH / 2
                let isHeading = row == 0 && category != .text && category != .other
                let w = min(area.width * widths[row], rightLimit(y))
                roundedBar(NSRect(x: area.minX, y: y, width: w, height: isHeading ? barH * 1.5 : barH),
                           isHeading ? color : lineGray)
            }
        case .spreadsheet:
            let grid = NSRect(x: area.minX, y: area.minY + area.height * 0.32, width: area.width, height: area.height * 0.66)
            let rows = 5, cols = 3
            let cellH = grid.height / CGFloat(rows), cellW = grid.width / CGFloat(cols)
            color.withAlphaComponent(0.85).setFill()
            NSRect(x: grid.minX, y: grid.maxY - cellH, width: grid.width, height: cellH).fill()
            color.withAlphaComponent(0.12).setFill()
            NSRect(x: grid.minX, y: grid.minY, width: cellW, height: grid.height - cellH).fill()
            let lines = NSBezierPath()
            for r in 0...rows { lines.move(to: NSPoint(x: grid.minX, y: grid.minY + cellH * CGFloat(r))); lines.line(to: NSPoint(x: grid.maxX, y: grid.minY + cellH * CGFloat(r))) }
            for c in 0...cols { lines.move(to: NSPoint(x: grid.minX + cellW * CGFloat(c), y: grid.minY)); lines.line(to: NSPoint(x: grid.minX + cellW * CGFloat(c), y: grid.maxY)) }
            lines.lineWidth = max(unit * 0.5, area.width * 0.012)
            color.withAlphaComponent(0.45).setStroke()
            lines.stroke()
        case .presentation:
            let slide = NSRect(x: area.minX, y: area.maxY - area.width * 0.66, width: area.width, height: area.width * 0.62)
            color.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: slide, xRadius: slide.width * 0.06, yRadius: slide.width * 0.06).fill()
            let heights: [CGFloat] = [0.35, 0.6, 0.45, 0.8]
            let barW = slide.width * 0.13
            for (i, h) in heights.enumerated() {
                let x = slide.minX + slide.width * 0.16 + CGFloat(i) * barW * 1.6
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: slide.minY + slide.height * 0.14, width: barW, height: slide.height * 0.7 * h),
                             xRadius: barW * 0.2, yRadius: barW * 0.2).fill()
            }
        case .image:
            let frame = NSRect(x: area.minX, y: area.maxY - area.width * 0.85, width: area.width, height: area.width * 0.8)
            let clip = NSBezierPath(roundedRect: frame, xRadius: frame.width * 0.1, yRadius: frame.width * 0.1)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            NSGradient(starting: rgb(120, 200, 255), ending: rgb(200, 236, 255))?.draw(in: frame, angle: -90)
            rgb(255, 204, 0).setFill()
            let sun = frame.width * 0.18
            NSBezierPath(ovalIn: NSRect(x: frame.maxX - sun * 1.7, y: frame.maxY - sun * 1.7, width: sun, height: sun)).fill()
            let back = NSBezierPath()
            back.move(to: NSPoint(x: frame.minX + frame.width * 0.35, y: frame.minY))
            back.line(to: NSPoint(x: frame.minX + frame.width * 0.68, y: frame.minY + frame.height * 0.55))
            back.line(to: NSPoint(x: frame.maxX + frame.width * 0.1, y: frame.minY))
            back.close()
            rgb(76, 175, 80).setFill()
            back.fill()
            let front = NSBezierPath()
            front.move(to: NSPoint(x: frame.minX - frame.width * 0.1, y: frame.minY))
            front.line(to: NSPoint(x: frame.minX + frame.width * 0.3, y: frame.minY + frame.height * 0.62))
            front.line(to: NSPoint(x: frame.minX + frame.width * 0.72, y: frame.minY))
            front.close()
            rgb(46, 140, 70).setFill()
            front.fill()
            NSGraphicsContext.restoreGraphicsState()
        case .video:
            let frame = NSRect(x: area.minX, y: area.maxY - area.width * 0.8, width: area.width, height: area.width * 0.74)
            rgb(44, 44, 52).setFill()
            NSBezierPath(roundedRect: frame, xRadius: frame.width * 0.1, yRadius: frame.width * 0.1).fill()
            let hole = frame.width * 0.07
            NSColor.white.withAlphaComponent(0.55).setFill()
            for i in 0..<5 {
                let x = frame.minX + frame.width * 0.08 + CGFloat(i) * frame.width * 0.2
                NSBezierPath(roundedRect: NSRect(x: x, y: frame.maxY - hole * 1.6, width: hole, height: hole), xRadius: hole * 0.25, yRadius: hole * 0.25).fill()
                NSBezierPath(roundedRect: NSRect(x: x, y: frame.minY + hole * 0.6, width: hole, height: hole), xRadius: hole * 0.25, yRadius: hole * 0.25).fill()
            }
            let tri = NSBezierPath()
            let s = frame.height * 0.36
            tri.move(to: NSPoint(x: frame.midX - s * 0.4, y: frame.midY - s / 2))
            tri.line(to: NSPoint(x: frame.midX - s * 0.4, y: frame.midY + s / 2))
            tri.line(to: NSPoint(x: frame.midX + s * 0.5, y: frame.midY))
            tri.close()
            color.setFill()
            tri.fill()
        case .audio:
            let heights: [CGFloat] = [0.3, 0.6, 0.9, 0.5, 0.75, 0.4, 0.65, 0.25]
            let barW = area.width / CGFloat(heights.count * 2 - 1)
            let midY = area.maxY - area.width * 0.45
            for (i, h) in heights.enumerated() {
                let barH = area.width * 0.8 * h
                roundedBar(NSRect(x: area.minX + CGFloat(i) * barW * 2, y: midY - barH / 2, width: barW, height: barH),
                           color.blended(withFraction: CGFloat(i) / CGFloat(heights.count) * 0.4, of: rgb(175, 82, 222)) ?? color)
            }
        case .archive:
            let w = area.width * 0.18
            let h = area.height * 0.07
            for i in 0..<7 {
                let y = area.maxY - CGFloat(i + 1) * h * 1.15
                let x = area.midX - w * 0.5 + (i.isMultiple(of: 2) ? -w * 0.5 : w * 0.5)
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h * 0.3, yRadius: h * 0.3).fill()
            }
            let tag = NSRect(x: area.midX - w * 0.8, y: area.maxY - h * 1.15 * 7 - w * 1.4, width: w * 1.6, height: w * 1.3)
            color.setFill()
            NSBezierPath(roundedRect: tag, xRadius: w * 0.3, yRadius: w * 0.3).fill()
        case .diskImage:
            let drive = NSRect(x: area.minX, y: area.maxY - area.width * 0.6, width: area.width, height: area.width * 0.42)
            NSGradient(starting: rgb(150, 156, 168), ending: rgb(200, 205, 214))?
                .draw(in: NSBezierPath(roundedRect: drive, xRadius: drive.height * 0.25, yRadius: drive.height * 0.25), angle: 90)
            let dot = drive.height * 0.2
            rgb(52, 199, 89).setFill()
            NSBezierPath(ovalIn: NSRect(x: drive.maxX - dot * 2.2, y: drive.midY - dot / 2, width: dot, height: dot)).fill()
        case .font:
            let size = area.width * 0.62
            let font = NSFont(name: "Georgia-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
            let text = NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: color])
            let textSize = text.size()
            text.draw(at: NSPoint(x: area.midX - textSize.width / 2, y: area.maxY - textSize.height * 1.05))
        }
    }

    private static func drawLabel(_ label: String, color: NSColor, in box: NSRect, unit: CGFloat, alignLeft: Bool) {
        guard box.width > 0, box.height > 0 else { return }
        var fontSize = box.height * 0.85
        func attributed(_ size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .heavy),
                .foregroundColor: color,
                .kern: size * 0.02,
            ])
        }
        let natural = attributed(fontSize).size().width
        if natural > box.width { fontSize *= box.width / natural }
        guard fontSize / unit >= 4.5 else { return }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let string = attributed(fontSize)
        let width = string.size().width
        let x = alignLeft ? box.minX : box.midX - width / 2
        string.draw(at: NSPoint(x: x, y: box.midY - font.capHeight / 2 + font.descender))
    }
}
