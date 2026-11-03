import SwiftUI
import AppKit

/// Shown in the right-hand Cover Flow panel instead of the covers while several items are
/// selected: their thumbnails in a grid.
struct CoverFlowSelectionGrid: View {
    /// The selected items in display order
    let items: [FileItem]
    let showsDetails: Bool
    let onSelect: (FileItem) -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var width: CGFloat = 0

    static let displayLimit = 30
    private static let minThreeColumnCell: CGFloat = 70
    private let padding: CGFloat = 16
    private let spacing: CGFloat = 10

    private var columnCount: Int {
        guard items.count >= 5 else { return 2 }
        let threeColumnCell = (width - padding * 2 - spacing * 2) / 3
        return threeColumnCell >= Self.minThreeColumnCell ? 3 : 2
    }

    private var overflowsThumbnails: Bool { items.count > Self.displayLimit }
    private var thumbnailItems: ArraySlice<FileItem> {
        items.prefix(overflowsThumbnails ? Self.displayLimit - 1 : Self.displayLimit)
    }

    private var cellSize: CGFloat {
        let count = CGFloat(columnCount)
        return max(40, (width - padding * 2 - spacing * (count - 1)) / count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cellSize), spacing: spacing), count: columnCount),
                alignment: .leading,
                spacing: spacing
            ) {
                ForEach(thumbnailItems) { item in
                    thumbnail(item)
                }
                if overflowsThumbnails {
                    overflowTile(items.count - thumbnailItems.count)
                }
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(items.count) items selected")
                .font(.system(size: settings.coverFlowTitleFontSize + 2, weight: .semibold))
            Text(totalText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var totalText: String {
        var total: Int64 = 0
        var pending = false
        for item in items {
            if item.isDirectory {
                if let size = item.calculatedSize {
                    total += size
                } else if item.isPackage, item.size > 0 {
                    total += item.size
                } else if !item.isFromArchive {
                    pending = true
                }
            } else {
                total += item.size
            }
        }
        let size = FileItem.formattedByteCount(total)
        return pending ? String(localized: "Total: \(size) (calculating…)") : String(localized: "Total: \(size)")
    }

    private func name(_ item: FileItem) -> String {
        item.displayName(showFileExtensions: settings.showFileExtensions)
    }

    private func thumbnail(_ item: FileItem) -> some View {
        VStack(spacing: 4) {
            CoverFlowSelectionThumbnail(item: item, size: cellSize - 8)
                .frame(width: cellSize, height: cellSize)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
            Text(name(item))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: cellSize)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(item) }
        .help(Text(name(item)))
    }

    private func overflowTile(_ count: Int) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: "+\(count)")
                .font(.system(size: max(14, cellSize * 0.28), weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: cellSize, height: cellSize)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
            Text(" ")
                .font(.caption)
        }
    }
}

/// A selected item's Quick Look thumbnail (its icon until loaded, or when it has none).
private struct CoverFlowSelectionThumbnail: View {
    let item: FileItem
    let size: CGFloat

    @EnvironmentObject private var settings: AppSettings
    @State private var image: NSImage?

    private var pixelSize: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return max(64, (size * scale * settings.thumbnailQualityValue).rounded())
    }

    var body: some View {
        Image(nsImage: image ?? item.placeholderIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: "\(item.url.path)|\(Int(pixelSize))") {
                let cache = ThumbnailCacheManager.shared
                if let cached = cache.cachedThumbnail(for: item, maxPixelSize: pixelSize) {
                    image = cached
                    return
                }
                let item = item
                let pixelSize = pixelSize
                let loaded: NSImage? = await withCheckedContinuation { continuation in
                    cache.generateThumbnail(for: item, maxPixelSize: pixelSize) { _, thumbnail in
                        continuation.resume(returning: thumbnail)
                    }
                }
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}
