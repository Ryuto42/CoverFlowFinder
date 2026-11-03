import Foundation

extension ViewMode {
    var localizedName: String {
        switch self {
        case .coverFlow: String(localized: "Cover Flow")
        case .icons: String(localized: "Icons")
        case .masonry: String(localized: "Masonry")
        case .list: String(localized: "List")
        case .columns: String(localized: "Columns")
        case .dualPane: String(localized: "Dual Pane")
        case .quadPane: String(localized: "Quad Pane")
        }
    }
}

extension SearchMode {
    var localizedName: String {
        switch self {
        case .filter: String(localized: "Filter")
        case .finder: String(localized: "Spotlight")
        }
    }
}

extension ListColumn {
    var localizedName: String {
        switch self {
        case .name: String(localized: "Name")
        case .dateModified: String(localized: "Date Modified")
        case .dateCreated: String(localized: "Date Created")
        case .size: String(localized: "Size")
        case .kind: String(localized: "Kind")
        case .tags: String(localized: "Tags")
        case .cloudStatus: String(localized: "Sync Status")
        }
    }
}

extension DualPaneView.PaneViewMode {
    var localizedName: String {
        switch self {
        case .list: String(localized: "List")
        case .icons: String(localized: "Icons")
        }
    }
}

extension QuadPaneView.PaneViewMode {
    var localizedName: String {
        switch self {
        case .list: String(localized: "List")
        case .icons: String(localized: "Icons")
        }
    }
}

extension URL {
    /// ローカライズされたフォルダ名（「書類」「ユーザ」など）。ファイル・名前が同じ場合は nil。
    var localizedFolderName: String? {
        guard isFileURL,
              let values = try? resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .localizedNameKey]),
              values.isDirectory == true,
              let localized = values.localizedName, !localized.isEmpty else { return nil }
        let name = lastPathComponent
        let plainName = values.isPackage == true ? (name as NSString).deletingPathExtension : name
        return localized == name || localized == plainName ? nil : localized
    }
}

extension FileItem {
    var localizedFolderName: String? {
        guard isDirectory, !isFromArchive else { return nil }
        return url.localizedFolderName
    }
}

extension SidebarKindFilter {
    /// 表示用の名前。検索・保存には従来どおり `name` を使う。
    var displayName: String {
        guard isBuiltin else { return name }
        switch id {
        case "images": return String(localized: "Images")
        case "pdfs": return String(localized: "PDFs")
        case "movies": return String(localized: "Movies")
        case "music": return String(localized: "Music")
        case "documents": return String(localized: "Documents")
        case "archives": return String(localized: "Archives")
        case "code": return String(localized: "Code")
        default: return name
        }
    }
}
