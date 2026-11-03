import Foundation

// MARK: - Criteria

/// What the smart folder editor edits. Saved inside the .savedSearch file (`FlowFinderCriteria`) next to the
/// Finder keys, so the criteria can be edited again; smart folders made by Finder are edited as a raw query.
struct SmartFolderCriteria: Codable, Equatable {
    enum Scope: String, Codable, CaseIterable {
        case thisMac
        case folder
    }

    enum Match: String, Codable, CaseIterable {
        case all
        case any
    }

    var scope: Scope = .thisMac
    var folderPath: String?
    var match: Match = .all
    var rules: [SmartFolderRule] = [SmartFolderRule()]

    var rawQuery: String? {
        let terms = rules.compactMap(\.queryTerm)
        guard !terms.isEmpty else { return nil }
        if terms.count == 1 { return terms[0] }
        return terms.map { "(\($0))" }.joined(separator: match == .all ? " && " : " || ")
    }

    /// Spotlight scope strings as stored in the file ("kMDQueryScopeComputer" or folder paths).
    var scopeStrings: [String] {
        if scope == .folder, let folderPath, !folderPath.isEmpty { return [folderPath] }
        return [SavedSearchFile.computerScope]
    }
}

struct SmartFolderRule: Codable, Equatable, Identifiable {
    enum Attribute: String, Codable, CaseIterable {
        case kind
        case name
        case contents
        case created
        case modified
        case lastOpened
        case size
        case tag
        case fileExtension
        case whereFrom
        case rawQuery
    }

    enum DateRange: String, Codable, CaseIterable {
        case today
        case yesterday
        case thisWeek
        case lastDays
        case after
        case before
    }

    enum SizeComparison: String, Codable, CaseIterable {
        case greaterThan
        case lessThan
    }

    enum SizeUnit: String, Codable, CaseIterable {
        case kb = "KB"
        case mb = "MB"
        case gb = "GB"

        var bytes: Double {
            switch self {
            case .kb: return 1_000
            case .mb: return 1_000_000
            case .gb: return 1_000_000_000
            }
        }
    }

    var id = UUID()
    var attribute: Attribute = .kind
    var kindID: String = SmartFolderKind.image.rawValue
    var text: String = ""
    var dateRange: DateRange = .lastDays
    var days: Int = 7
    var date: Date = Calendar.current.startOfDay(for: Date())
    var sizeComparison: SizeComparison = .greaterThan
    var size: Double = 1
    var sizeUnit: SizeUnit = .mb

    init(attribute: Attribute = .kind) {
        self.attribute = attribute
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SmartFolderRule()
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        attribute = (try? c.decodeIfPresent(Attribute.self, forKey: .attribute)) ?? .rawQuery
        kindID = (try? c.decodeIfPresent(String.self, forKey: .kindID)) ?? defaults.kindID
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        dateRange = (try? c.decodeIfPresent(DateRange.self, forKey: .dateRange)) ?? defaults.dateRange
        days = (try? c.decodeIfPresent(Int.self, forKey: .days)) ?? defaults.days
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? defaults.date
        sizeComparison = (try? c.decodeIfPresent(SizeComparison.self, forKey: .sizeComparison)) ?? defaults.sizeComparison
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? defaults.size
        sizeUnit = (try? c.decodeIfPresent(SizeUnit.self, forKey: .sizeUnit)) ?? defaults.sizeUnit
    }

    /// The rule in Spotlight's query syntax (the one `mdfind` and Finder's `RawQuery` use); nil while incomplete.
    var queryTerm: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = SmartFolderQuery.escaped(trimmed)
        switch attribute {
        case .kind:
            let types: [String]
            if let kind = SmartFolderKind(rawValue: kindID), kind != .other {
                types = kind.contentTypes
            } else {
                types = SmartFolderQuery.list(trimmed)
            }
            let terms = types.map { "kMDItemContentTypeTree == \"\(SmartFolderQuery.escaped($0))\"" }
            return SmartFolderQuery.joinedAny(terms)
        case .name:
            return value.isEmpty ? nil : "kMDItemFSName == \"*\(value)*\"cd"
        case .contents:
            return value.isEmpty ? nil : "kMDItemTextContent == \"\(value)*\"cdw"
        case .created:
            return dateTerm("kMDItemFSCreationDate")
        case .modified:
            return dateTerm("kMDItemFSContentChangeDate")
        case .lastOpened:
            return dateTerm("kMDItemLastUsedDate")
        case .size:
            guard size > 0 else { return nil }
            let bytes = Int64((size * sizeUnit.bytes).rounded())
            return "kMDItemFSSize \(sizeComparison == .greaterThan ? ">" : "<") \(bytes)"
        case .tag:
            return value.isEmpty ? nil : "kMDItemUserTags == \"\(value)\"cd"
        case .fileExtension:
            let terms = SmartFolderQuery.list(trimmed).map { "kMDItemFSName == \"*.\(SmartFolderQuery.escaped($0))\"c" }
            return SmartFolderQuery.joinedAny(terms)
        case .whereFrom:
            return value.isEmpty ? nil : "kMDItemWhereFroms == \"*\(value)*\"cd"
        case .rawQuery:
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func dateTerm(_ key: String) -> String {
        switch dateRange {
        case .today:
            return "\(key) >= $time.today"
        case .yesterday:
            return "\(key) >= $time.today(-1) && \(key) < $time.today"
        case .thisWeek:
            return "\(key) >= $time.this_week"
        case .lastDays:
            return "\(key) >= $time.today(-\(max(0, days)))"
        case .after:
            return "\(key) >= \(SmartFolderQuery.isoTime(Calendar.current.startOfDay(for: date)))"
        case .before:
            return "\(key) < \(SmartFolderQuery.isoTime(Calendar.current.startOfDay(for: date)))"
        }
    }
}

enum SmartFolderKind: String, CaseIterable {
    case application
    case archive
    case document
    case folder
    case image
    case movie
    case music
    case pdf
    case presentation
    case text
    case sourceCode
    case other

    var contentTypes: [String] {
        switch self {
        case .application: return ["com.apple.application"]
        case .archive: return ["public.archive"]
        case .document:
            return ["public.composite-content", "public.text", "public.presentation", "public.spreadsheet",
                    "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages",
                    "com.apple.iwork.numbers.sffnumbers", "com.apple.iwork.numbers.numbers",
                    "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
                    "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls"]
        case .folder: return ["public.folder"]
        case .image: return ["public.image"]
        case .movie: return ["public.movie"]
        case .music: return ["public.audio"]
        case .pdf: return ["com.adobe.pdf"]
        case .presentation: return ["public.presentation"]
        case .text: return ["public.text"]
        case .sourceCode: return ["public.source-code"]
        case .other: return []
        }
    }
}

// MARK: - Query helpers

enum SmartFolderQuery {
    static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\"\\*?".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// "jpg, .png" / "public.image, com.adobe.pdf" style input.
    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
    }

    static func joinedAny(_ terms: [String]) -> String? {
        switch terms.count {
        case 0: return nil
        case 1: return terms[0]
        default: return terms.map { "(\($0))" }.joined(separator: " || ")
        }
    }

    static func isoTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "$time.iso(\(formatter.string(from: date)))"
    }

    /// Spotlight's `InRange(attr, a, b)` (Finder writes it for dates) isn't understood by
    /// `NSPredicate(fromMetadataQueryString:)`; rewrite it as two comparisons.
    static func rewritingInRange(_ query: String) -> String {
        let argument = #"\s*((?:[^,()]|\([^()]*\))+?)\s*"#
        guard let regex = try? NSRegularExpression(pattern: #"InRange\("# + argument + "," + argument + "," + argument + #"\)"#) else {
            return query
        }
        let range = NSRange(query.startIndex..., in: query)
        return regex.stringByReplacingMatches(in: query, range: range, withTemplate: "($1 >= $2 && $1 <= $3)")
    }

    /// The predicate for a raw query; $time values are resolved now, so build it again for each search.
    static func predicate(for rawQuery: String) -> NSPredicate? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NSPredicate(fromMetadataQueryString: rewritingInRange(trimmed))
    }
}

// MARK: - .savedSearch file

/// A Finder smart folder file (~/Library/Saved Searches/*.savedSearch, a property list).
struct SavedSearchFile: Equatable {
    static let fileExtension = "savedSearch"
    static let computerScope = "kMDQueryScopeComputer"
    static let homeScope = "kMDQueryScopeHome"
    private static let criteriaKey = "FlowFinderCriteria"

    var rawQuery: String
    /// "kMDQueryScopeComputer", "kMDQueryScopeHome" or folder paths.
    var scopes: [String]
    /// Set for files this app saved.
    var criteria: SmartFolderCriteria?

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Saved Searches", isDirectory: true)
    }

    init(rawQuery: String, scopes: [String], criteria: SmartFolderCriteria? = nil) {
        self.rawQuery = rawQuery
        self.scopes = scopes
        self.criteria = criteria
    }

    init?(criteria: SmartFolderCriteria) {
        guard let rawQuery = criteria.rawQuery else { return nil }
        self.init(rawQuery: rawQuery, scopes: criteria.scopeStrings, criteria: criteria)
    }

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let rawDict = plist["RawQueryDict"] as? [String: Any]
        let searchCriteria = plist["SearchCriteria"] as? [String: Any]
        guard let rawQuery = (plist["RawQuery"] as? String) ?? (rawDict?["RawQuery"] as? String),
              !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let scopes = Self.nonEmpty(rawDict?["SearchScopes"])
            ?? Self.nonEmpty(searchCriteria?["FXScopeArrayOfPaths"])
            ?? Self.nonEmpty(searchCriteria?["CurrentFolderPath"])
            ?? [Self.computerScope]
        var criteria: SmartFolderCriteria?
        if let json = plist[Self.criteriaKey] as? Data {
            criteria = try? JSONDecoder().decode(SmartFolderCriteria.self, from: json)
        }
        // A file edited in Finder afterwards keeps our key but has a new query.
        if let decoded = criteria, decoded.rawQuery != rawQuery {
            criteria = nil
        }
        self.init(rawQuery: rawQuery, scopes: scopes, criteria: criteria)
    }

    private static func nonEmpty(_ value: Any?) -> [String]? {
        let strings = (value as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
        return strings.isEmpty ? nil : strings
    }

    /// The criteria to edit: ours, or the raw query and scope of a Finder smart folder.
    var editableCriteria: SmartFolderCriteria {
        if let criteria { return criteria }
        var rule = SmartFolderRule(attribute: .rawQuery)
        rule.text = rawQuery
        let folder = scopes.first { $0.hasPrefix("/") }
        return SmartFolderCriteria(scope: folder == nil ? .thisMac : .folder, folderPath: folder, match: .all, rules: [rule])
    }

    /// `base`: the file's current contents, whose other keys (Finder's view settings) are kept.
    func propertyListData(base: [String: Any]? = nil) throws -> Data {
        let previousQuery = (base?["RawQuery"] as? String) ?? ((base?["RawQueryDict"] as? [String: Any])?["RawQuery"] as? String)
        var searchCriteria = base?["SearchCriteria"] as? [String: Any] ?? [:]
        if previousQuery != rawQuery {
            // Finder's own description of the criteria no longer matches the query.
            searchCriteria["FXCriteriaSlices"] = nil
        }
        searchCriteria["FXScopeArrayOfPaths"] = scopes
        let folders = scopes.filter { $0.hasPrefix("/") }
        searchCriteria["CurrentFolderPath"] = folders.isEmpty ? nil : folders
        var rawQueryDict = base?["RawQueryDict"] as? [String: Any] ?? ["FinderFilesOnly": true, "UserFilesOnly": true]
        rawQueryDict["RawQuery"] = rawQuery
        rawQueryDict["SearchScopes"] = scopes
        var plist = base ?? [:]
        plist["CompatibleVersion"] = plist["CompatibleVersion"] ?? 1
        plist["RawQuery"] = rawQuery
        plist["RawQueryDict"] = rawQueryDict
        plist["SearchCriteria"] = searchCriteria
        plist[Self.criteriaKey] = criteria.flatMap { try? JSONEncoder().encode($0) }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// `existing`: a file to update, keeping its other keys.
    func write(to url: URL, updating existing: URL? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let base = existing.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        try propertyListData(base: base).write(to: url, options: .atomic)
    }
}
