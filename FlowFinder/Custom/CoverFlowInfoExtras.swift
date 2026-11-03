import SwiftUI
import AppKit
import CoreServices
import ImageIO
import PDFKit
import Security
import UniformTypeIdentifiers

struct InfoEntry {
    var label: String
    var value: String
    var link: URL?
    var icon: NSImage?
}

struct CoverFlowInfoExtrasResult {
    var general: [InfoEntry] = []
    var media: [InfoEntry] = []
    var details: [InfoEntry] = []
}

enum CoverFlowInfoExtras {
    private static let textSampleLimit = 4 * 1024 * 1024

    static func load(url: URL, values: URLResourceValues?, isFolder: Bool) async -> CoverFlowInfoExtrasResult {
        var result = CoverFlowInfoExtrasResult()
        let fileManager = FileManager.default

        let parent = url.deletingLastPathComponent()
        if parent.path != url.path {
            result.general.append(InfoEntry(label: String(localized: "Where"), value: fileManager.displayName(atPath: parent.path)))
        }

        let mdItem = MDItemCreateWithURL(nil, url as CFURL)
        if let mdItem {
            if let sources = MDItemCopyAttribute(mdItem, kMDItemWhereFroms) as? [String], !sources.isEmpty {
                result.general.append(InfoEntry(label: String(localized: "Downloaded From"), value: sources.joined(separator: "\n")))
            }
        }
        if let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate {
            result.general.append(InfoEntry(label: String(localized: "Date Added"), value: format(added)))
        }
        if !isFolder, let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            result.general.append(InfoEntry(
                label: String(localized: "Opens With"),
                value: fileManager.displayName(atPath: appURL.path),
                icon: icon
            ))
        }
        if let mdItem, let comment = MDItemCopyAttribute(mdItem, kMDItemFinderComment) as? String, !comment.isEmpty {
            result.general.append(InfoEntry(label: String(localized: "Comments"), value: comment))
        }
        if values?.isSymbolicLink == true,
           let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            result.general.append(InfoEntry(label: String(localized: "Original"), value: destination))
        } else if values?.isAliasFile == true,
                  let original = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) {
            result.general.append(InfoEntry(label: String(localized: "Original"), value: original.path))
        }

        guard !Task.isCancelled else { return result }
        result.details.append(contentsOf: permissionEntries(url: url, values: values))

        if isFolder {
            if Bundle(url: url)?.bundleIdentifier != nil, url.pathExtension.lowercased() == "app" {
                result.details.insert(contentsOf: applicationEntries(url: url), at: 0)
            } else if values?.isPackage != true {
                result.details.insert(contentsOf: folderEntries(url: url), at: 0)
            }
            return result
        }

        guard let type = values?.contentType else { return result }
        if type.conforms(to: .image) {
            result.media = await imageEntries(url: url)
        } else if type.conforms(to: .audiovisualContent) {
            result.media = await mediaEntries(url: url)
        } else if type.conforms(to: .pdf) {
            result.details.insert(contentsOf: await pdfEntries(url: url), at: 0)
        } else if type.conforms(to: .text) {
            result.details.insert(contentsOf: textEntries(url: url, size: values?.fileSize), at: 0)
        }
        return result
    }

    // MARK: - Common

    private static func permissionEntries(url: URL, values: URLResourceValues?) -> [InfoEntry] {
        var entries: [InfoEntry] = []
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let owner = attributes?[.ownerAccountName] as? String {
            let group = attributes?[.groupOwnerAccountName] as? String
            entries.append(InfoEntry(label: String(localized: "Owner"), value: group.map { "\(owner):\($0)" } ?? owner))
        }
        if let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue {
            entries.append(InfoEntry(label: String(localized: "Permissions"), value: "\(permissionString(mode)) (\(String(mode & 0o777, radix: 8)))"))
        }
        var flags: [String] = []
        if (attributes?[.immutable] as? Bool) == true { flags.append(String(localized: "Locked")) }
        if values?.isHidden == true { flags.append(String(localized: "Hidden")) }
        if values?.hasHiddenExtension == true { flags.append(String(localized: "Extension Hidden")) }
        if !flags.isEmpty {
            entries.append(InfoEntry(label: String(localized: "Flags"), value: flags.joined(separator: ", ")))
        }
        return entries
    }

    private static func permissionString(_ mode: Int) -> String {
        var result = ""
        for shift in stride(from: 6, through: 0, by: -3) {
            let bits = (mode >> shift) & 7
            result += bits & 4 != 0 ? "r" : "-"
            result += bits & 2 != 0 ? "w" : "-"
            result += bits & 1 != 0 ? "x" : "-"
        }
        return result
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Folder / application

    private static func folderEntries(url: URL) -> [InfoEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files = 0
        var folders = 0
        for child in children {
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                folders += 1
            } else {
                files += 1
            }
        }
        return [
            InfoEntry(label: String(localized: "Files"), value: files.formatted()),
            InfoEntry(label: String(localized: "Folders"), value: folders.formatted())
        ]
    }

    private static func applicationEntries(url: URL) -> [InfoEntry] {
        guard let bundle = Bundle(url: url) else { return [] }
        var entries: [InfoEntry] = []
        let info = bundle.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String {
            let build = info?["CFBundleVersion"] as? String
            entries.append(InfoEntry(
                label: String(localized: "Version"),
                value: build.map { $0 == short ? short : "\(short) (\($0))" } ?? short
            ))
        }
        if let identifier = bundle.bundleIdentifier {
            entries.append(InfoEntry(label: String(localized: "Bundle ID"), value: identifier))
        }
        if let architectures = bundle.executableArchitectures?.map(\.intValue), !architectures.isEmpty {
            var names: [String] = []
            if architectures.contains(NSBundleExecutableArchitectureARM64) { names.append("Apple Silicon") }
            if architectures.contains(NSBundleExecutableArchitectureX86_64) { names.append("Intel") }
            if !names.isEmpty {
                entries.append(InfoEntry(label: String(localized: "Architecture"), value: names.joined(separator: ", ")))
            }
        }
        if let signer = signer(of: url) {
            entries.append(InfoEntry(label: String(localized: "Signed By"), value: signer))
        }
        return entries
    }

    private static func signer(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }

    // MARK: - Documents

    private static func pdfEntries(url: URL) async -> [InfoEntry] {
        let metadata = await MediaMetadata(url: url)
        var entries = metadata.pdfInfo.map { InfoEntry(label: $0.0, value: $0.1) }
        if let document = PDFDocument(url: url), document.isEncrypted {
            entries.append(InfoEntry(label: String(localized: "Encrypted"), value: String(localized: "Yes")))
        }
        return entries
    }

    private static func textEntries(url: URL, size: Int?) -> [InfoEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: textSampleLimit), !data.isEmpty,
              !Task.isCancelled else { return [] }
        let truncated = (size ?? data.count) > data.count

        var converted: NSString?
        var lossy = ObjCBool(false)
        let rawEncoding = NSString.stringEncoding(
            for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: &lossy
        )
        guard let text = converted as String? else { return [] }

        var lines = 0
        text.enumerateLines { _, _ in lines += 1 }
        let suffix = truncated ? "+" : ""
        var entries = [
            InfoEntry(label: String(localized: "Characters"), value: text.count.formatted() + suffix),
            InfoEntry(label: String(localized: "Lines"), value: lines.formatted() + suffix)
        ]
        if rawEncoding != 0 {
            entries.append(InfoEntry(
                label: String(localized: "Encoding"),
                value: String.localizedName(of: String.Encoding(rawValue: rawEncoding))
            ))
        }
        return entries
    }

    // MARK: - Media

    private static let skippedImageLabels: Set<String> = [
        String(localized: "Width"), String(localized: "Height"), String(localized: "Aspect Ratio")
    ]
    private static let exposureLabels: Set<String> = [
        String(localized: "Shutter Speed"), String(localized: "Aperture"), String(localized: "ISO")
    ]

    private static func imageEntries(url: URL) async -> [InfoEntry] {
        var entries: [InfoEntry] = []
        var coordinateEntry: InfoEntry?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                entries.append(InfoEntry(label: String(localized: "Dimensions"), value: "\(width) × \(height)"))
            }
            if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
               let longitude = gps[kCGImagePropertyGPSLongitude] as? Double,
               latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 {
                let lat = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -latitude : latitude
                let lon = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -longitude : longitude
                coordinateEntry = InfoEntry(
                    label: String(localized: "Location"),
                    value: String(format: "%.5f, %.5f", lat, lon) + " — " + String(localized: "Open in Maps"),
                    link: URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f", lat, lon))
                )
            }
        }
        guard !Task.isCancelled else { return entries }
        let metadata = await MediaMetadata(url: url)
        entries += metadata.imageInfo.filter { !skippedImageLabels.contains($0.0) }.map { InfoEntry(label: $0.0, value: $0.1) }
        entries += metadata.cameraInfo.map { InfoEntry(label: $0.0, value: $0.1) }
        entries += metadata.exposureInfo.filter { exposureLabels.contains($0.0) }.map { InfoEntry(label: $0.0, value: $0.1) }
        if let coordinateEntry { entries.append(coordinateEntry) }
        return entries
    }

    private static func mediaEntries(url: URL) async -> [InfoEntry] {
        let metadata = await MediaMetadata(url: url)
        return (metadata.videoInfo + metadata.audioInfo + metadata.cameraInfo).map { InfoEntry(label: $0.0, value: $0.1) }
    }
}
