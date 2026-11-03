import Foundation

/// Finder keeps an item's creation and modification dates when it copies (or moves across
/// volumes); a plain copy gives the folders the time of the copy.
enum CopiedDates {
    static func preserve(from source: URL, to destination: URL) {
        let fileManager = FileManager.default
        var pairs: [(URL, URL)] = [(source, destination)]
        if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: nil, options: []) {
            let base = source.standardizedFileURL.path
            for case let url as URL in enumerator {
                let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
                pairs.append((url, destination.appendingPathComponent(relative)))
            }
        }
        // Deepest first: dating a child afterwards would bump its folder's modification date again.
        for (from, to) in pairs.reversed() {
            guard let attributes = try? fileManager.attributesOfItem(atPath: from.path) else { continue }
            var dates: [FileAttributeKey: Any] = [:]
            dates[.creationDate] = attributes[.creationDate]
            dates[.modificationDate] = attributes[.modificationDate]
            try? fileManager.setAttributes(dates, ofItemAtPath: to.path)
        }
    }
}
