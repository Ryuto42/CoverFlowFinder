import AppKit
import CoreImage
import UniformTypeIdentifiers

enum FolderColor: CaseIterable {
    case red, orange, yellow, green, blue, purple, gray

    var title: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .gray: String(localized: "Gray")
        }
    }

    /// Target hue (0...1); nil for gray.
    var hue: CGFloat? {
        switch self {
        case .red: 0.99
        case .orange: 0.08
        case .yellow: 0.14
        case .green: 0.34
        case .blue: 0.58
        case .purple: 0.77
        case .gray: nil
        }
    }

    var swatch: NSColor {
        guard let hue else { return .systemGray }
        return NSColor(hue: hue, saturation: 0.75, brightness: 0.95, alpha: 1)
    }
}

@MainActor
enum FolderAppearance {
    static func canChange(_ items: [FileItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.isDirectory && !$0.isPackage && !$0.isFromArchive && $0.url.isFileURL }
    }

    static func menuEntries(viewModel: FileBrowserViewModel, targets: @escaping () -> [FileItem]) -> [CustomMenuEntry] {
        var colors: [CustomMenuEntry] = FolderColor.allCases.map { color in
            .action(color.title, enabled: true) { [weak viewModel] in
                guard let viewModel else { return }
                setColor(color, for: targets().map(\.url), viewModel: viewModel)
            }
        }
        colors.append(.separator)
        colors.append(.action(String(localized: "Revert to Default"), enabled: true) { [weak viewModel] in
            guard let viewModel else { return }
            apply(nil, to: targets().map(\.url), viewModel: viewModel)
        })
        return [
            .submenu(String(localized: "Folder Color"), enabled: true, colors),
            .action(String(localized: "Change Icon…"), enabled: true) { [weak viewModel] in
                guard let viewModel else { return }
                chooseIcon(for: targets().map(\.url), viewModel: viewModel)
            }
        ]
    }

    static func setColor(_ color: FolderColor, for urls: [URL], viewModel: FileBrowserViewModel) {
        guard let image = coloredFolderIcon(color) else {
            NSSound.beep()
            return
        }
        apply(image, to: urls, viewModel: viewModel)
    }

    static func chooseIcon(for urls: [URL], viewModel: FileBrowserViewModel) {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose an image to use as the folder icon.")
        panel.prompt = String(localized: "Choose")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = squareIcon(from: url) else {
            NSSound.beep()
            return
        }
        apply(image, to: urls, viewModel: viewModel)
    }

    /// Sets (or, with nil, removes) the custom icon like Finder's Get Info does, then drops what the app cached for them.
    static func apply(_ image: NSImage?, to urls: [URL], viewModel: FileBrowserViewModel) {
        nonisolated(unsafe) let image = image
        DispatchQueue.global(qos: .userInitiated).async { [weak viewModel] in
            let failed = urls.filter { !NSWorkspace.shared.setIcon(image, forFile: $0.path, options: []) }
            DispatchQueue.main.async {
                ThumbnailCacheManager.shared.forgetFolderThumbnails(for: urls)
                viewModel?.refresh()
                if let first = failed.first {
                    NSSound.beep()
                    FileOperationAlerts.showMessage(
                        String(localized: "The icon of “\(first.lastPathComponent)” couldn’t be changed."),
                        information: String(localized: "You may not have permission to modify it."),
                        in: NSApp.keyWindow
                    )
                }
            }
        }
    }

    // MARK: - Images

    private static var coloredCache: [FolderColor: NSImage] = [:]
    private static var baseHueCache: CGFloat?
    private static let imageSize = 1024

    private static func bitmap(drawing draw: (NSRect) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: imageSize, pixelsHigh: imageSize, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(NSRect(x: 0, y: 0, width: imageSize, height: imageSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func icon(from cgImage: CGImage) -> NSImage {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: imageSize / 2, height: imageSize / 2))
        return image
    }

    /// The system folder icon with its hue turned to `color`, so the shading stays.
    static func coloredFolderIcon(_ color: FolderColor) -> NSImage? {
        if let cached = coloredCache[color] { return cached }
        let system = NSWorkspace.shared.icon(for: .folder)
        guard let rep = bitmap(drawing: { system.draw(in: $0, from: .zero, operation: .copy, fraction: 1) }),
              let source = rep.cgImage else { return nil }

        var input = CIImage(cgImage: source)
        if let hue = color.hue {
            let base = baseHueCache ?? averageHue(of: rep)
            baseHueCache = base
            let adjust = CIFilter(name: "CIHueAdjust")
            adjust?.setValue(input, forKey: kCIInputImageKey)
            adjust?.setValue((hue - base) * 2 * .pi, forKey: kCIInputAngleKey)
            input = adjust?.outputImage ?? input
        } else {
            let controls = CIFilter(name: "CIColorControls")
            controls?.setValue(input, forKey: kCIInputImageKey)
            controls?.setValue(0.0, forKey: kCIInputSaturationKey)
            controls?.setValue(0.05, forKey: kCIInputBrightnessKey)
            input = controls?.outputImage ?? input
        }
        guard let output = CIContext().createCGImage(input, from: CGRect(x: 0, y: 0, width: imageSize, height: imageSize)) else { return nil }
        let image = icon(from: output)
        coloredCache[color] = image
        return image
    }

    /// The mean hue (0...1) of the saturated, opaque pixels, i.e. the folder's body.
    private static func averageHue(of rep: NSBitmapImageRep) -> CGFloat {
        guard let data = rep.bitmapData else { return 0.58 }
        let stride = 8
        var x: CGFloat = 0, y: CGFloat = 0
        for row in Swift.stride(from: 0, to: rep.pixelsHigh, by: stride) {
            for column in Swift.stride(from: 0, to: rep.pixelsWide, by: stride) {
                let p = data + row * rep.bytesPerRow + column * 4
                guard p[3] > 240 else { continue }
                let r = CGFloat(p[0]) / 255, g = CGFloat(p[1]) / 255, b = CGFloat(p[2]) / 255
                let top = max(r, g, b), bottom = min(r, g, b)
                guard top > 0, (top - bottom) / top > 0.25 else { continue }
                let color = NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
                let angle = color.hueComponent * 2 * .pi
                x += cos(angle)
                y += sin(angle)
            }
        }
        guard x != 0 || y != 0 else { return 0.58 }
        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return hue
    }

    private static func squareIcon(from url: URL) -> NSImage? {
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0,
              let rep = bitmap(drawing: { canvas in
                  let scale = min(canvas.width / source.size.width, canvas.height / source.size.height)
                  let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
                  let rect = NSRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
                  source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
              }),
              let cgImage = rep.cgImage else { return nil }
        return icon(from: cgImage)
    }
}
