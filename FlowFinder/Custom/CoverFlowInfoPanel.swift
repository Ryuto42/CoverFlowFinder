import SwiftUI
import AppKit
import CoreServices
import ImageIO
import UniformTypeIdentifiers

/// Details of the centred item (or of the current folder when nothing is selected), shown below
/// the covers in the right-hand Cover Flow panel, which scrolls it with the covers.
struct CoverFlowInfoPanel: View {
    let item: FileItem?
    let selectionCount: Int
    let folderURL: URL
    let folderItemCount: Int

    @EnvironmentObject private var settings: AppSettings
    @State private var details: CoverFlowItemDetails?
    @State private var folderTotals: FolderSizeTotals?
    @State private var isCalculatingSize = false
    @State private var copiedPath = false

    private var targetURL: URL { item?.url ?? folderURL }

    private var loadKey: String {
        let date = item?.modificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(targetURL.path)|\(date)|\(item == nil)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            rows
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: loadKey) {
            await load()
        }
    }

    private var title: String {
        if let item {
            return item.displayName(showFileExtensions: settings.showFileExtensions)
        }
        return FileManager.default.displayName(atPath: folderURL.path)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: settings.coverFlowTitleFontSize + 2, weight: .semibold))
                .lineLimit(3)
                .textSelection(.enabled)
            if selectionCount > 1 {
                Text("\(selectionCount) items selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if item == nil {
                Text(FileAttributes.formatItemCount(folderItemCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let kind = details?.kind ?? item?.kindDescription {
                row("Kind", kind)
            }
            if let size = sizeText {
                row("Size", size)
            }
            ForEach(Array((details?.general ?? []).enumerated()), id: \.offset) { _, entry in
                entryRow(entry)
            }
            if let created = details?.created ?? item?.creationDate {
                row("Created", Self.format(created))
            }
            if let modified = details?.modified ?? item?.modificationDate {
                row("Modified", Self.format(modified))
            }
            if let lastOpened = details?.lastOpened {
                row("Last opened", Self.format(lastOpened))
            }
            if let tags = details?.tags, !tags.isEmpty {
                labeledRow("Tags") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(FinderTag.from(name: tag)?.color ?? Color.secondary)
                                    .frame(width: 9, height: 9)
                                Text(tag)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            labeledRow("Path") {
                Button {
                    copyPath()
                } label: {
                    Text(copiedPath ? String(localized: "Copied") : targetURL.path)
                        .foregroundStyle(copiedPath ? Color.accentColor : Color.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(Text("Click to copy the path"))
            }
            GitInfoRows(url: targetURL, isDirectory: item?.isDirectory ?? true)
            section("Media", details?.media)
            section("Details", details?.details)
        }
        .font(settings.coverFlowDetailFont)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ entries: [InfoEntry]?) -> some View {
        if let entries, !entries.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                entryRow(entry)
            }
        }
    }

    private func entryRow(_ entry: InfoEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(width: 84, alignment: .trailing)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let icon = entry.icon {
                    Image(nsImage: icon)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                }
                if let link = entry.link {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        Text(entry.value)
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(entry.value)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sizeText: String? {
        let isFolder = details?.isFolder ?? (item?.isDirectory ?? true)
        if isFolder {
            guard item != nil, !(item?.isFromArchive ?? false) else { return nil }
            if let folderTotals {
                let size = FileItem.formattedByteCount(folderTotals.logicalSize)
                let count = FileAttributes.formatItemCount(folderTotals.itemCount)
                return isCalculatingSize
                    ? String(localized: "Calculating… \(size)")
                    : "\(size) (\(count))"
            }
            return isCalculatingSize ? String(localized: "Calculating…") : nil
        }
        if let size = details?.size {
            return FileItem.formattedByteCount(size)
        }
        return item?.formattedSize
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        labeledRow(label) {
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeledRow<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            content()
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(targetURL.path, forType: .string)
        copiedPath = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copiedPath = false
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    // MARK: - Loading

    private func load() async {
        folderTotals = nil
        isCalculatingSize = false
        copiedPath = false

        if item?.isFromArchive == true {
            details = nil
            return
        }
        let url = targetURL
        let key = loadKey
        let loaded: CoverFlowItemDetails
        if let cached = CoverFlowItemDetails.cache.object(forKey: key as NSString) {
            loaded = cached.value
        } else {
            details = nil
            let loading = Task.detached(priority: .userInitiated) {
                await CoverFlowItemDetails.load(url: url)
            }
            loaded = await withTaskCancellationHandler {
                await loading.value
            } onCancel: {
                loading.cancel()
            }
            guard !Task.isCancelled else { return }
            CoverFlowItemDetails.cache.setObject(CoverFlowItemDetails.Box(loaded), forKey: key as NSString)
        }
        details = loaded

        // A selected folder or package is totalled; the current folder only shows its item count
        guard item != nil, loaded.isFolder else { return }
        isCalculatingSize = true
        let calculation = Task.detached(priority: .utility) { () -> FolderSizeTotals? in
            FolderSizeCalculator.calculate(url: url, progress: { partial in
                Task { @MainActor in
                    if isCalculatingSize, targetURL == url {
                        folderTotals = partial
                    }
                }
            })
        }
        let totals = await withTaskCancellationHandler {
            await calculation.value
        } onCancel: {
            calculation.cancel()
        }
        guard !Task.isCancelled else { return }
        folderTotals = totals ?? folderTotals
        isCalculatingSize = false
    }
}

struct CoverFlowItemDetails {
    var isFolder = false
    var kind: String?
    var size: Int64?
    var created: Date?
    var modified: Date?
    var lastOpened: Date?
    var tags: [String] = []
    var general: [InfoEntry] = []
    var media: [InfoEntry] = []
    var details: [InfoEntry] = []

    final class Box {
        let value: CoverFlowItemDetails
        init(_ value: CoverFlowItemDetails) { self.value = value }
    }

    static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 200
        return cache
    }()

    static func load(url: URL) async -> CoverFlowItemDetails {
        var details = CoverFlowItemDetails()
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .localizedTypeDescriptionKey, .totalFileSizeKey, .fileSizeKey,
            .creationDateKey, .contentModificationDateKey, .tagNamesKey, .contentTypeKey,
            .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .isHiddenKey, .hasHiddenExtensionKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        details.isFolder = values?.isDirectory ?? false
        details.kind = values?.localizedTypeDescription
        if !details.isFolder {
            details.size = (values?.totalFileSize ?? values?.fileSize).map(Int64.init)
        }
        details.created = values?.creationDate
        details.modified = values?.contentModificationDate
        details.tags = values?.tagNames ?? []

        if let mdItem = MDItemCreateWithURL(nil, url as CFURL),
           let lastUsed = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) as? Date {
            details.lastOpened = lastUsed
        }

        let extras = await CoverFlowInfoExtras.load(url: url, values: values, isFolder: details.isFolder)
        details.general = extras.general
        details.media = extras.media
        details.details = extras.details
        return details
    }
}
