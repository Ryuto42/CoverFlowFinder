import Foundation

extension SearchMode {
    private static let defaultsKey = "lastSearchMode"

    /// The search mode used last, so new tabs and the next launch keep Spotlight once it was chosen.
    static var lastUsed: SearchMode {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchMode.init(rawValue:)) ?? .filter }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
