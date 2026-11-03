import AppKit
import AVFoundation
import ImageIO
import CoreImage
import PDFKit
import UniformTypeIdentifiers

// MARK: - Kinds and actions

enum ConversionKind: CaseIterable {
    case image, pdf, video, audio, text, markdown

    static func of(_ url: URL) -> ConversionKind? {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(ext) { return .markdown }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if ["rtf", "rtfd", "docx", "doc", "html", "htm", "txt", "odt", "webarchive", "text"].contains(ext)
            || type.conforms(to: .plainText) && ext != "md" { return .text }
        return nil
    }
}

enum ImageTarget: String, CaseIterable {
    case jpeg, png, heic, tiff, pdf

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .pdf: "PDF"
        }
    }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .pdf: .pdf
        }
    }
}

enum ImageResize: Hashable {
    case longEdge(Int)
    case percent(Int)
}

enum VideoTarget: CaseIterable {
    case mp4H264, mp4HEVC, mov, p1080, p720, audioOnly

    var title: String {
        switch self {
        case .mp4H264: String(localized: "MP4 (H.264)")
        case .mp4HEVC: String(localized: "MP4 (HEVC)")
        case .mov: "MOV"
        case .p1080: String(localized: "1080p (MP4)")
        case .p720: String(localized: "720p (MP4)")
        case .audioOnly: String(localized: "Audio Only (M4A)")
        }
    }

    var preset: String {
        switch self {
        case .mp4H264: AVAssetExportPresetHighestQuality
        case .mp4HEVC: AVAssetExportPresetHEVCHighestQuality
        case .mov: AVAssetExportPresetPassthrough
        case .p1080: AVAssetExportPreset1920x1080
        case .p720: AVAssetExportPreset1280x720
        case .audioOnly: AVAssetExportPresetAppleM4A
        }
    }

    var fileType: AVFileType {
        switch self {
        case .mov: .mov
        case .audioOnly: .m4a
        default: .mp4
        }
    }

    var fileExtension: String {
        switch self {
        case .mov: "mov"
        case .audioOnly: "m4a"
        default: "mp4"
        }
    }

    /// Added to the name when the extension alone wouldn't tell the copy apart.
    var nameSuffix: String {
        switch self {
        case .p1080: " 1080p"
        case .p720: " 720p"
        case .mp4HEVC: " HEVC"
        default: ""
        }
    }
}

enum AudioTarget: String, CaseIterable {
    case m4a, wav, aiff

    var title: String {
        switch self {
        case .m4a: String(localized: "M4A (AAC)")
        case .wav: "WAV"
        case .aiff: "AIFF"
        }
    }
}

enum TextTarget: String, CaseIterable {
    case rtf, docx, html, txt

    var title: String {
        switch self {
        case .rtf: String(localized: "Rich Text (RTF)")
        case .docx: String(localized: "Word Document (DOCX)")
        case .html: "HTML"
        case .txt: String(localized: "Plain Text (TXT)")
        }
    }
}

enum ConversionAction: Hashable {
    case image(ImageTarget)
    case resize(ImageResize)
    case combinePDF
    case pdfToPNG
    case video(VideoTarget)
    case audio(AudioTarget)
    case text(TextTarget)
    case markdownToHTML

    var title: String {
        switch self {
        case .image(let target): target.title
        case .resize(.longEdge(let pixels)): String(localized: "Resize to \(pixels) px")
        case .resize(.percent(let percent)): "\(percent)%"
        case .combinePDF: String(localized: "Combine into PDF")
        case .pdfToPNG: String(localized: "Export Pages as PNG")
        case .video(let target): target.title
        case .audio(let target): target.title
        case .text(let target): target.title
        case .markdownToHTML: "HTML"
        }
    }

    func accepts(_ kind: ConversionKind) -> Bool {
        switch self {
        case .image, .resize: kind == .image
        case .combinePDF: kind == .image || kind == .pdf
        case .pdfToPNG: kind == .pdf
        case .video: kind == .video
        case .audio: kind == .audio
        case .text: kind == .text
        case .markdownToHTML: kind == .markdown
        }
    }
}

struct ConversionSettings {
    var quality: Double

    static var current: ConversionSettings {
        let value = UserDefaults.standard.object(forKey: "settings.imageQuality") as? Double ?? 0.85
        return ConversionSettings(quality: min(max(value, 0.1), 1))
    }
}

// MARK: - Engine

/// Runs off the main thread. Every output is written into a hidden staging folder beside the
/// original, then moved into place keeping both names ("name 2.ext") and recorded for Undo.
enum FileConversionEngine {
    static func convert(_ urls: [URL], action: ConversionAction, settings: ConversionSettings,
                        journal: FileOperationJournal, progress: Progress) -> FileOperationResult {
        var result = FileOperationResult()
        let jobs: [[URL]] = action == .combinePDF ? [urls] : urls.map { [$0] }
        progress.totalUnitCount = Int64(max(1, jobs.count * 100))
        for job in jobs {
            if progress.isCancelled { result.wasCancelled = true; break }
            let step = Progress(totalUnitCount: 100)
            progress.addChild(step, withPendingUnitCount: 100)
            guard let first = job.first else { continue }
            let folder = first.deletingLastPathComponent()
            do {
                let staging = folder.appendingPathComponent(".FlowFinder-convert-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: staging) }
                let output = try convert(job, action: action, settings: settings, into: staging, progress: step)
                if progress.isCancelled { result.wasCancelled = true; break }
                let published = FileOperationJournal()
                let moved = FileOperationEngine.transfer([
                    FileTransferItem(source: output, destination: folder.appendingPathComponent(output.lastPathComponent),
                                     kind: .move, placement: .keepBoth)
                ], journal: published)
                journal.steps += published.placedURLs.map { .created($0) }
                result.failures += moved.failures
                step.completedUnitCount = step.totalUnitCount
            } catch {
                if FileOperationEngine.isCancellation(error) || progress.isCancelled { result.wasCancelled = true; break }
                result.failures.append(FileOperationFailure(url: first, error: error))
            }
        }
        return result
    }

    /// Writes the result of one job into `folder` and returns it.
    static func convert(_ urls: [URL], action: ConversionAction, settings: ConversionSettings,
                        into folder: URL, progress: Progress) throws -> URL {
        let source = urls[0]
        let base = source.deletingPathExtension().lastPathComponent
        switch action {
        case .image(let target):
            let output = folder.appendingPathComponent(base + "." + target.fileExtension)
            try ImageConverter.convert(source, to: output, target: target, resize: nil, quality: settings.quality)
            return output
        case .resize(let resize):
            let target = ImageConverter.sameFormatTarget(for: source)
            let suffix: String
            switch resize {
            case .longEdge(let pixels): suffix = " \(pixels)px"
            case .percent(let percent): suffix = " \(percent)%"
            }
            let output = folder.appendingPathComponent(base + suffix + "." + target.fileExtension)
            try ImageConverter.convert(source, to: output, target: target, resize: resize, quality: settings.quality)
            return output
        case .combinePDF:
            let output = folder.appendingPathComponent(String(localized: "Combined") + ".pdf")
            try PDFConverter.combine(urls, to: output, progress: progress)
            return output
        case .pdfToPNG:
            let output = folder.appendingPathComponent(base, isDirectory: true)
            try PDFConverter.exportPages(of: source, to: output, progress: progress)
            return output
        case .video(let target):
            let output = folder.appendingPathComponent(base + target.nameSuffix + "." + target.fileExtension)
            try MediaConverter.export(source, to: output, preset: target.preset, fileType: target.fileType, progress: progress)
            return output
        case .audio(let target):
            let output = folder.appendingPathComponent(base + "." + target.rawValue)
            if target == .m4a {
                try MediaConverter.export(source, to: output, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, progress: progress)
            } else {
                try MediaConverter.writePCM(source, to: output, aiff: target == .aiff, progress: progress)
            }
            return output
        case .text(let target):
            let output = folder.appendingPathComponent(base + "." + target.rawValue)
            try TextConverter.convert(source, to: output, format: target.rawValue, progress: progress)
            return output
        case .markdownToHTML:
            let output = folder.appendingPathComponent(base + ".html")
            let text = try String(contentsOf: source, encoding: .utf8)
            try MarkdownConverter.html(from: text, title: base).write(to: output, atomically: false, encoding: .utf8)
            return output
        }
    }
}

// MARK: Images

enum ImageConverter {
    static func sameFormatTarget(for url: URL) -> ImageTarget {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        default: .png
        }
    }

    /// The first frame, turned upright (EXIF orientation applied) and scaled.
    static func orientedImage(_ url: URL, resize: ImageResize?) throws -> (image: CGImage, properties: [CFString: Any]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw FileOperationEngine.makeError(String(localized: "The image couldn’t be read."))
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longEdge = max(width, height, 1)
        var target = longEdge
        switch resize {
        case .longEdge(let pixels)?: target = min(pixels, longEdge)
        case .percent(let percent)?: target = max(1, longEdge * percent / 100)
        case nil: break
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(target, longEdge)
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FileOperationEngine.makeError(String(localized: "The image couldn’t be read."))
        }
        if target > longEdge, let scaled = upscale(image, by: Double(target) / Double(longEdge)) {
            image = scaled
        }
        return (image, properties)
    }

    private static func upscale(_ image: CGImage, by scale: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent.integral)
    }

    static func convert(_ url: URL, to output: URL, target: ImageTarget, resize: ImageResize?, quality: Double) throws {
        let (image, sourceProperties) = try orientedImage(url, resize: resize)
        if target == .pdf {
            try PDFConverter.write([PDFConverter.page(for: image, properties: sourceProperties)], to: output)
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, target.type.identifier as CFString, 1, nil) else {
            throw FileOperationEngine.makeError(String(localized: "This Mac can’t write \(target.title) images."))
        }
        // Keep the metadata, but the pixels are upright now.
        var properties = sourceProperties
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { properties[key] = nil }
        if target == .jpeg || target == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if target == .jpeg, image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast {
            CGImageDestinationAddImage(destination, flattened(image) ?? image, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw FileOperationEngine.makeError(String(localized: "The image couldn’t be written."))
        }
    }

    /// JPEG has no transparency: draw on white.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

// MARK: PDF

enum PDFConverter {
    static func page(for image: CGImage, properties: [CFString: Any]) -> PDFPage? {
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = 72 / max(dpi, 1)
        let size = NSSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        return PDFPage(image: NSImage(cgImage: image, size: size))
    }

    static func write(_ pages: [PDFPage?], to output: URL) throws {
        let document = PDFDocument()
        for page in pages.compactMap({ $0 }) { document.insert(page, at: document.pageCount) }
        guard document.pageCount > 0, document.write(to: output) else {
            throw FileOperationEngine.makeError(String(localized: "The PDF couldn’t be written."))
        }
    }

    /// Images become one page each; PDFs add all their pages, in the given order.
    static func combine(_ urls: [URL], to output: URL, progress: Progress) throws {
        let document = PDFDocument()
        for (index, url) in urls.enumerated() {
            if progress.isCancelled { throw CocoaError(.userCancelled) }
            if ConversionKind.of(url) == .pdf {
                guard let pdf = PDFDocument(url: url) else {
                    throw FileOperationEngine.makeError(String(localized: "“\(url.lastPathComponent)” couldn’t be read."))
                }
                if pdf.isLocked {
                    throw FileOperationEngine.makeError(String(localized: "“\(url.lastPathComponent)” is locked with a password."))
                }
                for pageIndex in 0..<pdf.pageCount {
                    if let page = pdf.page(at: pageIndex)?.copy() as? PDFPage {
                        document.insert(page, at: document.pageCount)
                    }
                }
            } else {
                let (image, properties) = try ImageConverter.orientedImage(url, resize: nil)
                if let page = page(for: image, properties: properties) {
                    document.insert(page, at: document.pageCount)
                }
            }
            progress.completedUnitCount = Int64((index + 1) * 90 / urls.count)
        }
        guard document.pageCount > 0, document.write(to: output) else {
            throw FileOperationEngine.makeError(String(localized: "The PDF couldn’t be written."))
        }
    }

    /// One PNG per page (144 dpi) in a new folder.
    static func exportPages(of url: URL, to folder: URL, progress: Progress) throws {
        guard let pdf = PDFDocument(url: url) else {
            throw FileOperationEngine.makeError(String(localized: "“\(url.lastPathComponent)” couldn’t be read."))
        }
        if pdf.isLocked {
            throw FileOperationEngine.makeError(String(localized: "“\(url.lastPathComponent)” is locked with a password."))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let base = url.deletingPathExtension().lastPathComponent
        let digits = String(pdf.pageCount).count
        let scale = 2.0
        for index in 0..<pdf.pageCount {
            if progress.isCancelled { throw CocoaError(.userCancelled) }
            guard let page = pdf.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let size = CGSize(width: (rotated ? bounds.height : bounds.width) * scale,
                              height: (rotated ? bounds.width : bounds.height) * scale)
            guard let context = CGContext(data: nil, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.setFillColor(.white)
            context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { continue }
            let number = String(repeating: "0", count: max(0, digits - String(index + 1).count)) + String(index + 1)
            let output = folder.appendingPathComponent("\(base) \(number).png")
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw FileOperationEngine.makeError(String(localized: "The image couldn’t be written."))
            }
            progress.completedUnitCount = Int64((index + 1) * 95 / max(1, pdf.pageCount))
        }
    }
}

// MARK: Audio and video

enum MediaConverter {
    private final class Box: @unchecked Sendable {
        var error: Error?
    }

    static func export(_ url: URL, to output: URL, preset: String, fileType: AVFileType, progress: Progress) throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw FileOperationEngine.makeError(String(localized: "This file can’t be converted to that format."))
        }
        session.shouldOptimizeForNetworkUse = fileType == .mp4
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        nonisolated(unsafe) let unsafeSession = session
        let task = Task.detached {
            do { try await unsafeSession.export(to: output, as: fileType) } catch { box.error = error }
            done.signal()
        }
        let watcher = Task.detached {
            for await state in unsafeSession.states(updateInterval: 0.2) {
                if case .exporting(let exportProgress) = state {
                    progress.completedUnitCount = Int64(exportProgress.fractionCompleted * 99)
                }
            }
        }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            if progress.isCancelled { task.cancel() }
        }
        watcher.cancel()
        if progress.isCancelled || task.isCancelled { throw CocoaError(.userCancelled) }
        if let error = box.error {
            if (error as? CancellationError) != nil { throw CocoaError(.userCancelled) }
            throw error
        }
    }

    /// Decodes with AVAudioFile and writes 16-bit PCM (WAV or AIFF).
    static func writePCM(_ url: URL, to output: URL, aiff: Bool, progress: Progress) throws {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: aiff,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outputFile = try AVAudioFile(forWriting: output, settings: settings, commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw FileOperationEngine.makeError(String(localized: "This file can’t be converted to that format."))
        }
        let total = max(1, input.length)
        while input.framePosition < input.length {
            if progress.isCancelled { throw CocoaError(.userCancelled) }
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try outputFile.write(from: buffer)
            progress.completedUnitCount = input.framePosition * 99 / total
        }
    }
}

// MARK: Text

enum TextConverter {
    /// `textutil` reads and writes RTF, DOCX, HTML and TXT (and reads DOC, ODT, web archives).
    static func convert(_ url: URL, to output: URL, format: String, progress: Progress) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        var arguments = ["-convert", format, "-output", output.path]
        if format == "txt" || format == "html" { arguments += ["-encoding", "UTF-8"] }
        process.arguments = arguments + ["--", url.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            if progress.isCancelled { process.terminate() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if progress.isCancelled { throw CocoaError(.userCancelled) }
        guard process.terminationStatus == 0, FileOperationEngine.itemExists(at: output) else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FileOperationEngine.makeError(message.isEmpty ? String(localized: "This file can’t be converted to that format.") : message)
        }
    }
}

/// A small Markdown subset: headings, paragraphs, lists, quotes, code blocks, rules, and inline
/// code, bold, italics, links and images.
enum MarkdownConverter {
    static func html(from markdown: String, title: String) -> String {
        var body: [String] = []
        var paragraph: [String] = []
        var listTag: String?
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { body.append("<p>" + paragraph.map(inline).joined(separator: "\n") + "</p>") }
            paragraph = []
        }
        func closeList() {
            if let tag = listTag { body.append("</\(tag)>") }
            listTag = nil
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    body.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                    code = []
                } else {
                    flushParagraph(); closeList()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(rawLine); continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }
            if let level = headingLevel(line) {
                flushParagraph(); closeList()
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                body.append("<h\(level)>\(inline(text))</h\(level)>")
            } else if ["---", "***", "___"].contains(line.replacingOccurrences(of: " ", with: "")) {
                flushParagraph(); closeList()
                body.append("<hr>")
            } else if line.hasPrefix(">") {
                flushParagraph(); closeList()
                body.append("<blockquote><p>" + inline(line.dropFirst().trimmingCharacters(in: .whitespaces)) + "</p></blockquote>")
            } else if let item = listItem(line) {
                flushParagraph()
                if listTag != item.tag { closeList(); body.append("<\(item.tag)>"); listTag = item.tag }
                body.append("<li>" + inline(item.text) + "</li>")
            } else {
                if listTag != nil { closeList() }
                paragraph.append(line)
            }
        }
        if inCode { body.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>") }
        flushParagraph(); closeList()
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        </head>
        <body>
        \(body.joined(separator: "\n"))
        </body>
        </html>

        """
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (tag: String, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return ("ul", String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return ("ol", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inline(_ text: String) -> String {
        // Code spans first, so their contents stay literal.
        var parts: [String] = []
        for (index, piece) in text.components(separatedBy: "`").enumerated() {
            parts.append(index % 2 == 1 ? "<code>\(escape(piece))</code>" : formatted(escape(piece)))
        }
        return parts.joined()
    }

    private static func formatted(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img src=\"$2\" alt=\"$1\">"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            (#"\*([^*]+)\*"#, "<em>$1</em>"),
            (#"~~([^~]+)~~"#, "<del>$1</del>")
        ]
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result
    }
}

// MARK: - Commands

@MainActor
enum FileConversion {
    static func convertibleURLs(_ items: [FileItem]) -> [URL] {
        guard items.allSatisfy({ !$0.isFromArchive && $0.url.isFileURL }) else { return [] }
        return items.filter { !$0.isDirectory || $0.isPackage && $0.url.pathExtension.lowercased() == "rtfd" }.map(\.url)
    }

    static func convert(_ items: [FileItem], action: ConversionAction, viewModel: FileBrowserViewModel) {
        let urls = convertibleURLs(items).filter { ConversionKind.of($0).map(action.accepts) ?? false }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let settings = ConversionSettings.current
        let title = urls.count == 1 && action != .combinePDF
            ? String(localized: "Converting “\(urls[0].lastPathComponent)”")
            : String(localized: "Converting \(urls.count) items")
        viewModel.runCreatingOperation(actionName: String(localized: "Convert"), failureVerb: String(localized: "converted"), title: title) { journal, progress in
            FileConversionEngine.convert(urls, action: action, settings: settings, journal: journal, progress: progress)
        }
    }

    /// Asks for a percentage in a sheet, then resizes.
    static func resizeByPercent(_ items: [FileItem], viewModel: FileBrowserViewModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Resize Images")
        alert.informativeText = String(localized: "Enter a percentage of the original size (1–400).")
        alert.addButton(withTitle: String(localized: "Resize"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: "50")
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak viewModel] response in
            guard response == .alertFirstButtonReturn, let viewModel else { return }
            let text = field.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: "% ").union(.whitespaces))
            guard let percent = Int(text), (1...400).contains(percent) else {
                NSSound.beep()
                return
            }
            convert(items, action: .resize(.percent(percent)), viewModel: viewModel)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    static func actions(for kind: ConversionKind) -> [[ConversionAction]] {
        switch kind {
        case .image:
            return [ImageTarget.allCases.map { .image($0) },
                    [2048, 1024, 512].map { .resize(.longEdge($0)) }]
        case .pdf: return [[.pdfToPNG]]
        case .video: return [VideoTarget.allCases.map { .video($0) }]
        case .audio: return [AudioTarget.allCases.map { .audio($0) }]
        case .text: return [TextTarget.allCases.map { .text($0) }]
        case .markdown: return [[.markdownToHTML]]
        }
    }

    /// The "Convert" submenu for what's selected, or nil when nothing can be converted.
    static func menuEntry(viewModel: FileBrowserViewModel, targets: @escaping () -> [FileItem]) -> CustomMenuEntry? {
        let urls = convertibleURLs(targets())
        let kinds = ConversionKind.allCases.filter { kind in urls.contains { ConversionKind.of($0) == kind } }
        guard !kinds.isEmpty, !viewModel.isInsideArchive else { return nil }
        let canWrite = viewModel.canAddItemsToCurrentLocation
        let make: (ConversionAction) -> CustomMenuEntry = { [weak viewModel] action in
            .action(action.title, enabled: true) {
                guard let viewModel else { return }
                convert(targets(), action: action, viewModel: viewModel)
            }
        }
        var children: [CustomMenuEntry] = []
        for kind in kinds {
            var entries: [CustomMenuEntry] = []
            for group in actions(for: kind) {
                entries.append(.separator)
                entries += group.map(make)
            }
            if kind == .image {
                entries.append(.action(String(localized: "Resize by Percentage…"), enabled: true) { [weak viewModel] in
                    guard let viewModel else { return }
                    resizeByPercent(targets(), viewModel: viewModel)
                })
            }
            if kinds.count > 1 {
                children.append(.submenu(title(of: kind), enabled: true, entries.filter {
                    if case .separator = $0 { return false } else { return true }
                }))
            } else {
                children += entries
            }
        }
        let combinable = urls.filter { [.image, .pdf].contains(ConversionKind.of($0)) }
        if combinable.count > 1 {
            children.append(.separator)
            children.append(make(.combinePDF))
        }
        if case .separator? = children.first { children.removeFirst() }
        return .submenu(String(localized: "Convert"), enabled: canWrite, children)
    }

    private static func title(of kind: ConversionKind) -> String {
        switch kind {
        case .image: String(localized: "Images")
        case .pdf: "PDF"
        case .video: String(localized: "Movies")
        case .audio: String(localized: "Audio")
        case .text: String(localized: "Documents")
        case .markdown: "Markdown"
        }
    }
}
