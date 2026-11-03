import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let showHiddenFiles = "settings.showHiddenFiles"
        static let showFileExtensions = "settings.showFileExtensions"
        static let foldersFirst = "settings.foldersFirst"
        static let showPathBar = "settings.showPathBar"
        static let showStatusBar = "settings.showStatusBar"
        static let soundEffectsEnabled = "settings.soundEffectsEnabled"
        static let showItemTags = "settings.showItemTags"
        static let useColorfulFileIcons = "settings.useColorfulFileIcons"
        static let sidebarShowFavorites = "settings.sidebarShowFavorites"
        static let sidebarShowICloud = "settings.sidebarShowICloud"
        static let sidebarShowLocations = "settings.sidebarShowLocations"
        static let sidebarShowTags = "settings.sidebarShowTags"
        static let sidebarFavorites = "settings.sidebarFavorites"
        /// Holds a favorites blob this version couldn't read (e.g. written by a newer version), saved before it's replaced.
        static let sidebarFavoritesUnreadableBackup = "settings.sidebarFavorites.unreadableBackup"
        /// Format of the stored favorites, written with them since 1.39. Its absence means 1.38 or earlier wrote them.
        static let sidebarFavoritesFormat = "settings.sidebarFavorites.format"
        static let sidebarCollapsedSections = "settings.sidebarCollapsedSections"
        static let sidebarLayout = "settings.sidebarLayout"
        static let thumbnailQuality = "settings.thumbnailQuality"
        static let masonryShowFilenames = "settings.masonryShowFilenames"

        static let listFontSize = "settings.listFontSize"
        static let listIconSize = "settings.listIconSize"

        static let iconGridIconSize = "settings.iconGridIconSize"
        static let iconGridFontSize = "settings.iconGridFontSize"
        static let iconGridSpacing = "settings.iconGridSpacing"

        static let columnFontSize = "settings.columnFontSize"
        static let columnIconSize = "settings.columnIconSize"
        static let columnWidth = "settings.columnWidth"
        static let columnShowPreview = "settings.columnShowPreview"
        static let columnPreviewWidth = "settings.columnPreviewWidth"

        static let coverFlowTitleFontSize = "settings.coverFlowTitleFontSize"
        static let coverFlowScale = "settings.coverFlowScale"
        static let coverFlowSwipeSpeed = "settings.coverFlowSwipeSpeed"
        static let coverFlowShowInfo = "settings.coverFlowShowInfo"
        static let coverFlowPanelInSplit = "settings.coverFlowPanelInSplit"
        static let coverFlowPaneHeight = "settings.coverFlowPaneHeight"
        static let coverFlowLayout = "settings.coverFlowLayout"
        static let coverFlowPanelWidth = "settings.coverFlowPanelWidth"
        static let usePerFolderColumnState = "settings.usePerFolderColumnState"
        static let calculateAllSizes = "settings.calculateAllSizes"
        static let inlineVideoPreview = "settings.inlineVideoPreview"
        static let inlineAudioPreview = "settings.inlineAudioPreview"
        static let videoSkimming = "settings.videoSkimming"
        static let swipeToNavigate = "settings.swipeToNavigate"
        static let backspaceGoesBack = "settings.backspaceGoesBack"
        static let terminalAppBundleID = "settings.terminalAppBundleID"
        static let newTabLocation = "settings.newTabLocation"
        static let newTabCustomPath = "settings.newTabCustomPath"
        static let showShareRibbon = "settings.showShareRibbon"
        static let showDockProgress = "settings.showDockProgress"
        static let showGitStatus = "settings.showGitStatus"
        static let filterSearchesSubfolders = "settings.filterSearchesSubfolders"
        static let offerInstallerCleanup = "settings.offerInstallerCleanup"
        static let compressExcludeMacFiles = "settings.compressExcludeMacFiles"
        static let compressionLevel = "settings.compressionLevel"
        static let imageQuality = "settings.imageQuality"
        static let restoreTabsOnLaunch = "settings.restoreTabsOnLaunch"
        static let rememberViewOptionsPerFolder = "settings.rememberViewOptionsPerFolder"
        static let translucentWindow = "settings.translucentWindow"
        static let showDropStack = "settings.showDropStack"
        static let dropStackKeepsItems = "settings.dropStackKeepsItems"
        static let dragMovesWindowAside = "settings.dragMovesWindowAside"
        static let compactViewModePicker = "settings.compactViewModePicker"
    }

    private enum Defaults {
        static let showHiddenFiles = false
        static let showFileExtensions = true
        static let foldersFirst = true
        static let showPathBar = true
        static let showStatusBar = true
        static let soundEffectsEnabled = true
        static let showItemTags = true
        static let useColorfulFileIcons = true
        static let sidebarShowFavorites = true
        static let sidebarShowICloud = true
        static let sidebarShowLocations = true
        static let sidebarShowTags = true
        static let sidebarFavorites: [SidebarFavorite] = [
            .system(.documents),
            .system(.applications),
            .system(.desktop),
            .system(.downloads),
            .system(.movies),
            .system(.music),
            .system(.pictures)
        ]
        static let thumbnailQuality: Double = 1.0
        static let masonryShowFilenames = false

        static let listFontSize: Double = 13
        static let listIconSize: Double = 20

        static let iconGridIconSize: Double = 80
        static let iconGridFontSize: Double = 12
        static let iconGridSpacing: Double = 24

        static let columnFontSize: Double = 13
        static let columnIconSize: Double = 16
        static let columnWidth: Double = 220
        static let columnShowPreview = true
        static let columnPreviewWidth: Double = 220

        static let coverFlowTitleFontSize: Double = 15
        static let coverFlowScale: Double = 1.2
        static let coverFlowSwipeSpeed: Double = 1.0
        static let coverFlowShowInfo = true
        static let coverFlowPanelInSplit = false
        static let coverFlowPaneHeight: Double = 0
        static let coverFlowLayout = "right"
        static let coverFlowPanelWidth: Double = 360
        static let usePerFolderColumnState = true  // Finder-like behavior (default)
        static let calculateAllSizes = true
        static let inlineVideoPreview = true
        static let inlineAudioPreview = true
        static let videoSkimming = true
        static let swipeToNavigate = true
        static let backspaceGoesBack = true
        static let terminalAppBundleID = "com.apple.Terminal"
        static let newTabLocation = "current"
        static let newTabCustomPath = ""
        static let showShareRibbon = true
        static let showDockProgress = true
        static let showGitStatus = true
        static let filterSearchesSubfolders = true
        static let offerInstallerCleanup = true
        static let compressExcludeMacFiles = true
        static let compressionLevel = "normal"
        static let imageQuality = 0.85
        static let restoreTabsOnLaunch = true
        static let rememberViewOptionsPerFolder = true
        static let translucentWindow = true
        static let showDropStack = true
        static let dropStackKeepsItems = false
        static let dragMovesWindowAside = true
        static let compactViewModePicker = false
    }

    private let defaults: UserDefaults

    @Published var showHiddenFiles: Bool {
        didSet { defaults.set(showHiddenFiles, forKey: Keys.showHiddenFiles) }
    }
    @Published var showFileExtensions: Bool {
        didSet { defaults.set(showFileExtensions, forKey: Keys.showFileExtensions) }
    }
    @Published var foldersFirst: Bool {
        didSet { defaults.set(foldersFirst, forKey: Keys.foldersFirst) }
    }
    @Published var showPathBar: Bool {
        didSet { defaults.set(showPathBar, forKey: Keys.showPathBar) }
    }
    @Published var showStatusBar: Bool {
        didSet { defaults.set(showStatusBar, forKey: Keys.showStatusBar) }
    }
    @Published var soundEffectsEnabled: Bool {
        didSet { defaults.set(soundEffectsEnabled, forKey: Keys.soundEffectsEnabled) }
    }
    @Published var showItemTags: Bool {
        didSet { defaults.set(showItemTags, forKey: Keys.showItemTags) }
    }
    @Published var useColorfulFileIcons: Bool {
        didSet {
            defaults.set(useColorfulFileIcons, forKey: Keys.useColorfulFileIcons)
            ColorfulFileIcon.isEnabled = useColorfulFileIcons
        }
    }
    @Published var sidebarShowFavorites: Bool {
        didSet { defaults.set(sidebarShowFavorites, forKey: Keys.sidebarShowFavorites) }
    }
    @Published var sidebarShowICloud: Bool {
        didSet { defaults.set(sidebarShowICloud, forKey: Keys.sidebarShowICloud) }
    }
    @Published var sidebarShowLocations: Bool {
        didSet { defaults.set(sidebarShowLocations, forKey: Keys.sidebarShowLocations) }
    }
    @Published var sidebarShowTags: Bool {
        didSet { defaults.set(sidebarShowTags, forKey: Keys.sidebarShowTags) }
    }
    @Published var sidebarFavorites: [SidebarFavorite] {
        didSet { persistSidebarFavorites() }
    }
    /// Stored favorites this version can't decode (e.g. a newer `Kind`); written back so a downgrade doesn't lose them.
    private var preservedUnknownFavorites: [SidebarFavoritesCoding.UnknownElement] = []
    /// The stored favorites blob when it couldn't be decoded at all; backed up before the first write replaces it.
    private var unreadableFavoritesData: Data?
    /// Sidebar sections the user collapsed (`SidebarSection.Kind` raw values). Not published: only the sidebar reads
    /// it, when it rebuilds its rows.
    var sidebarCollapsedSections: Set<String> {
        didSet { defaults.set(sidebarCollapsedSections.sorted(), forKey: Keys.sidebarCollapsedSections) }
    }
    /// Section order, groups, Kinds and per-item customization (JSON), applied on top of the settings above.
    @Published var sidebarLayout: SidebarLayout {
        didSet { defaults.set(sidebarLayout.encoded(), forKey: Keys.sidebarLayout) }
    }
    @Published var thumbnailQuality: Double {
        didSet { defaults.set(thumbnailQuality, forKey: Keys.thumbnailQuality) }
    }
    @Published var masonryShowFilenames: Bool {
        didSet { defaults.set(masonryShowFilenames, forKey: Keys.masonryShowFilenames) }
    }

    @Published var listFontSize: Double {
        didSet { defaults.set(listFontSize, forKey: Keys.listFontSize) }
    }
    @Published var listIconSize: Double {
        didSet { defaults.set(listIconSize, forKey: Keys.listIconSize) }
    }

    @Published var iconGridIconSize: Double {
        didSet { defaults.set(iconGridIconSize, forKey: Keys.iconGridIconSize) }
    }
    @Published var iconGridFontSize: Double {
        didSet { defaults.set(iconGridFontSize, forKey: Keys.iconGridFontSize) }
    }
    @Published var iconGridSpacing: Double {
        didSet { defaults.set(iconGridSpacing, forKey: Keys.iconGridSpacing) }
    }

    @Published var columnFontSize: Double {
        didSet { defaults.set(columnFontSize, forKey: Keys.columnFontSize) }
    }
    @Published var columnIconSize: Double {
        didSet { defaults.set(columnIconSize, forKey: Keys.columnIconSize) }
    }
    @Published var columnWidth: Double {
        didSet { defaults.set(columnWidth, forKey: Keys.columnWidth) }
    }
    @Published var columnShowPreview: Bool {
        didSet { defaults.set(columnShowPreview, forKey: Keys.columnShowPreview) }
    }
    @Published var columnPreviewWidth: Double {
        didSet { defaults.set(columnPreviewWidth, forKey: Keys.columnPreviewWidth) }
    }

    @Published var coverFlowTitleFontSize: Double {
        didSet { defaults.set(coverFlowTitleFontSize, forKey: Keys.coverFlowTitleFontSize) }
    }
    @Published var coverFlowScale: Double {
        didSet { defaults.set(coverFlowScale, forKey: Keys.coverFlowScale) }
    }
    @Published var coverFlowSwipeSpeed: Double {
        didSet { defaults.set(coverFlowSwipeSpeed, forKey: Keys.coverFlowSwipeSpeed) }
    }
    @Published var coverFlowShowInfo: Bool {
        didSet { defaults.set(coverFlowShowInfo, forKey: Keys.coverFlowShowInfo) }
    }

    @Published var coverFlowPanelInSplit: Bool {
        didSet { defaults.set(coverFlowPanelInSplit, forKey: Keys.coverFlowPanelInSplit) }
    }
    @Published var coverFlowPaneHeight: Double {
        didSet { defaults.set(coverFlowPaneHeight, forKey: Keys.coverFlowPaneHeight) }
    }
    /// "right": covers in a tall panel beside the list; "top": covers above the list
    @Published var coverFlowLayout: String {
        didSet { defaults.set(coverFlowLayout, forKey: Keys.coverFlowLayout) }
    }
    @Published var coverFlowPanelWidth: Double {
        didSet { defaults.set(coverFlowPanelWidth, forKey: Keys.coverFlowPanelWidth) }
    }
    @Published var usePerFolderColumnState: Bool {
        didSet { defaults.set(usePerFolderColumnState, forKey: Keys.usePerFolderColumnState) }
    }
    /// Lists show the total size of folders too (Finder's "Calculate all sizes"), and sort by it.
    /// Packages (.app, …) show theirs either way.
    @Published var calculateAllSizes: Bool {
        didSet {
            defaults.set(calculateAllSizes, forKey: Keys.calculateAllSizes)
            if calculateAllSizes != oldValue {
                // Sizes calculated so far are recalculated (the views re-request them)
                ItemSizeCalculator.shared.invalidateAll()
            }
        }
    }
    @Published var inlineVideoPreview: Bool {
        didSet { defaults.set(inlineVideoPreview, forKey: Keys.inlineVideoPreview) }
    }
    @Published var inlineAudioPreview: Bool {
        didSet { defaults.set(inlineAudioPreview, forKey: Keys.inlineAudioPreview) }
    }
    @Published var videoSkimming: Bool {
        didSet { defaults.set(videoSkimming, forKey: Keys.videoSkimming) }
    }
    @Published var swipeToNavigate: Bool {
        didSet { defaults.set(swipeToNavigate, forKey: Keys.swipeToNavigate) }
    }
    @Published var backspaceGoesBack: Bool {
        didSet { defaults.set(backspaceGoesBack, forKey: Keys.backspaceGoesBack) }
    }
    @Published var terminalAppBundleID: String {
        didSet { defaults.set(terminalAppBundleID, forKey: Keys.terminalAppBundleID) }
    }
    @Published var newTabLocation: String {
        didSet { defaults.set(newTabLocation, forKey: Keys.newTabLocation) }
    }
    @Published var newTabCustomPath: String {
        didSet { defaults.set(newTabCustomPath, forKey: Keys.newTabCustomPath) }
    }
    @Published var showShareRibbon: Bool {
        didSet { defaults.set(showShareRibbon, forKey: Keys.showShareRibbon) }
    }
    @Published var showDockProgress: Bool {
        didSet { defaults.set(showDockProgress, forKey: Keys.showDockProgress) }
    }
    @Published var showGitStatus: Bool {
        didSet { defaults.set(showGitStatus, forKey: Keys.showGitStatus) }
    }
    @Published var filterSearchesSubfolders: Bool {
        didSet { defaults.set(filterSearchesSubfolders, forKey: Keys.filterSearchesSubfolders) }
    }
    @Published var offerInstallerCleanup: Bool {
        didSet { defaults.set(offerInstallerCleanup, forKey: Keys.offerInstallerCleanup) }
    }

    @Published var compressExcludeMacFiles: Bool {
        didSet { defaults.set(compressExcludeMacFiles, forKey: Keys.compressExcludeMacFiles) }
    }
    @Published var compressionLevel: String {
        didSet { defaults.set(compressionLevel, forKey: Keys.compressionLevel) }
    }
    @Published var imageQuality: Double {
        didSet { defaults.set(imageQuality, forKey: Keys.imageQuality) }
    }
    @Published var restoreTabsOnLaunch: Bool {
        didSet { defaults.set(restoreTabsOnLaunch, forKey: Keys.restoreTabsOnLaunch) }
    }
    /// Folders set to "Always open in … view" keep their view mode and icon sizes.
    @Published var rememberViewOptionsPerFolder: Bool {
        didSet { defaults.set(rememberViewOptionsPerFolder, forKey: Keys.rememberViewOptionsPerFolder) }
    }
    @Published var translucentWindow: Bool {
        didSet { defaults.set(translucentWindow, forKey: Keys.translucentWindow) }
    }
    @Published var showDropStack: Bool {
        didSet { defaults.set(showDropStack, forKey: Keys.showDropStack) }
    }
    @Published var dropStackKeepsItems: Bool {
        didSet { defaults.set(dropStackKeepsItems, forKey: Keys.dropStackKeepsItems) }
    }
    @Published var dragMovesWindowAside: Bool {
        didSet { defaults.set(dragMovesWindowAside, forKey: Keys.dragMovesWindowAside) }
    }
    @Published var compactViewModePicker: Bool {
        didSet { defaults.set(compactViewModePicker, forKey: Keys.compactViewModePicker) }
    }

    private convenience init() {
        self.init(defaults: .standard)
    }

    /// Use `AppSettings.shared` in the app; this initializer exists so tests can supply their own defaults.
    init(defaults: UserDefaults) {
        self.defaults = defaults

        defaults.register(defaults: [
            Keys.showHiddenFiles: Defaults.showHiddenFiles,
            Keys.showFileExtensions: Defaults.showFileExtensions,
            Keys.foldersFirst: Defaults.foldersFirst,
            Keys.showPathBar: Defaults.showPathBar,
            Keys.showStatusBar: Defaults.showStatusBar,
            Keys.soundEffectsEnabled: Defaults.soundEffectsEnabled,
            Keys.showItemTags: Defaults.showItemTags,
            Keys.useColorfulFileIcons: Defaults.useColorfulFileIcons,
            Keys.sidebarShowFavorites: Defaults.sidebarShowFavorites,
            Keys.sidebarShowICloud: Defaults.sidebarShowICloud,
            Keys.sidebarShowLocations: Defaults.sidebarShowLocations,
            Keys.sidebarShowTags: Defaults.sidebarShowTags,
            Keys.thumbnailQuality: Defaults.thumbnailQuality,
            Keys.masonryShowFilenames: Defaults.masonryShowFilenames,
            Keys.listFontSize: Defaults.listFontSize,
            Keys.listIconSize: Defaults.listIconSize,
            Keys.iconGridIconSize: Defaults.iconGridIconSize,
            Keys.iconGridFontSize: Defaults.iconGridFontSize,
            Keys.iconGridSpacing: Defaults.iconGridSpacing,
            Keys.columnFontSize: Defaults.columnFontSize,
            Keys.columnIconSize: Defaults.columnIconSize,
            Keys.columnWidth: Defaults.columnWidth,
            Keys.columnShowPreview: Defaults.columnShowPreview,
            Keys.columnPreviewWidth: Defaults.columnPreviewWidth,
            Keys.coverFlowTitleFontSize: Defaults.coverFlowTitleFontSize,
            Keys.coverFlowScale: Defaults.coverFlowScale,
            Keys.coverFlowSwipeSpeed: Defaults.coverFlowSwipeSpeed,
            Keys.coverFlowShowInfo: Defaults.coverFlowShowInfo,
            Keys.coverFlowPanelInSplit: Defaults.coverFlowPanelInSplit,
            Keys.coverFlowPaneHeight: Defaults.coverFlowPaneHeight,
            Keys.coverFlowLayout: Defaults.coverFlowLayout,
            Keys.coverFlowPanelWidth: Defaults.coverFlowPanelWidth,
            Keys.usePerFolderColumnState: Defaults.usePerFolderColumnState,
            Keys.calculateAllSizes: Defaults.calculateAllSizes,
            Keys.inlineVideoPreview: Defaults.inlineVideoPreview,
            Keys.inlineAudioPreview: Defaults.inlineAudioPreview,
            Keys.videoSkimming: Defaults.videoSkimming,
            Keys.swipeToNavigate: Defaults.swipeToNavigate,
            Keys.backspaceGoesBack: Defaults.backspaceGoesBack,
            Keys.terminalAppBundleID: Defaults.terminalAppBundleID,
            Keys.newTabLocation: Defaults.newTabLocation,
            Keys.newTabCustomPath: Defaults.newTabCustomPath,
            Keys.showShareRibbon: Defaults.showShareRibbon,
            Keys.showDockProgress: Defaults.showDockProgress,
            Keys.showGitStatus: Defaults.showGitStatus,
            Keys.filterSearchesSubfolders: Defaults.filterSearchesSubfolders,
            Keys.offerInstallerCleanup: Defaults.offerInstallerCleanup,
            Keys.compressExcludeMacFiles: Defaults.compressExcludeMacFiles,
            Keys.compressionLevel: Defaults.compressionLevel,
            Keys.imageQuality: Defaults.imageQuality,
            Keys.restoreTabsOnLaunch: Defaults.restoreTabsOnLaunch,
            Keys.rememberViewOptionsPerFolder: Defaults.rememberViewOptionsPerFolder,
            Keys.translucentWindow: Defaults.translucentWindow,
            Keys.showDropStack: Defaults.showDropStack,
            Keys.dropStackKeepsItems: Defaults.dropStackKeepsItems,
            Keys.dragMovesWindowAside: Defaults.dragMovesWindowAside,
            Keys.compactViewModePicker: Defaults.compactViewModePicker
        ])

        showHiddenFiles = defaults.bool(forKey: Keys.showHiddenFiles)
        showFileExtensions = defaults.bool(forKey: Keys.showFileExtensions)
        foldersFirst = defaults.bool(forKey: Keys.foldersFirst)
        showPathBar = defaults.bool(forKey: Keys.showPathBar)
        showStatusBar = defaults.bool(forKey: Keys.showStatusBar)
        soundEffectsEnabled = defaults.bool(forKey: Keys.soundEffectsEnabled)
        showItemTags = defaults.bool(forKey: Keys.showItemTags)
        useColorfulFileIcons = defaults.bool(forKey: Keys.useColorfulFileIcons)
        ColorfulFileIcon.isEnabled = defaults.bool(forKey: Keys.useColorfulFileIcons)
        sidebarShowFavorites = defaults.bool(forKey: Keys.sidebarShowFavorites)
        sidebarShowICloud = defaults.bool(forKey: Keys.sidebarShowICloud)
        sidebarShowLocations = defaults.bool(forKey: Keys.sidebarShowLocations)
        sidebarShowTags = defaults.bool(forKey: Keys.sidebarShowTags)
        // Favorites are deliberately not registered as a default: "never set" (use the defaults) must stay
        // distinguishable from an empty list the user chose.
        let storedFavorites = defaults.data(forKey: Keys.sidebarFavorites)
        switch SidebarFavoritesCoding.decode(storedFavorites) {
        case .notSet:
            sidebarFavorites = Defaults.sidebarFavorites
        case .decoded(let favorites, let unknown)
            where favorites.isEmpty && unknown.isEmpty && defaults.object(forKey: Keys.sidebarFavoritesFormat) == nil:
            // 1.38 and earlier showed the defaults for a stored empty list, so that's what such a list means. Only
            // an empty list saved by this version (with the format key) is one the user chose.
            sidebarFavorites = Defaults.sidebarFavorites
        case .decoded(let favorites, let unknown):
            sidebarFavorites = favorites
            preservedUnknownFavorites = unknown
        case .unreadable:
            sidebarFavorites = Defaults.sidebarFavorites
            unreadableFavoritesData = storedFavorites
        }
        sidebarCollapsedSections = Set(defaults.stringArray(forKey: Keys.sidebarCollapsedSections) ?? [])
        sidebarLayout = SidebarLayout.decode(defaults.data(forKey: Keys.sidebarLayout))
        thumbnailQuality = defaults.double(forKey: Keys.thumbnailQuality)
        masonryShowFilenames = defaults.bool(forKey: Keys.masonryShowFilenames)

        listFontSize = defaults.double(forKey: Keys.listFontSize)
        listIconSize = defaults.double(forKey: Keys.listIconSize)

        iconGridIconSize = defaults.double(forKey: Keys.iconGridIconSize)
        iconGridFontSize = defaults.double(forKey: Keys.iconGridFontSize)
        iconGridSpacing = defaults.double(forKey: Keys.iconGridSpacing)

        columnFontSize = defaults.double(forKey: Keys.columnFontSize)
        columnIconSize = defaults.double(forKey: Keys.columnIconSize)
        columnWidth = defaults.double(forKey: Keys.columnWidth)
        columnShowPreview = defaults.bool(forKey: Keys.columnShowPreview)
        columnPreviewWidth = defaults.double(forKey: Keys.columnPreviewWidth)

        coverFlowTitleFontSize = defaults.double(forKey: Keys.coverFlowTitleFontSize)
        coverFlowScale = defaults.double(forKey: Keys.coverFlowScale)
        coverFlowSwipeSpeed = defaults.double(forKey: Keys.coverFlowSwipeSpeed)
        coverFlowShowInfo = defaults.bool(forKey: Keys.coverFlowShowInfo)
        coverFlowPanelInSplit = defaults.bool(forKey: Keys.coverFlowPanelInSplit)
        coverFlowPaneHeight = defaults.double(forKey: Keys.coverFlowPaneHeight)
        coverFlowLayout = defaults.string(forKey: Keys.coverFlowLayout) ?? Defaults.coverFlowLayout
        coverFlowPanelWidth = defaults.double(forKey: Keys.coverFlowPanelWidth)
        usePerFolderColumnState = defaults.bool(forKey: Keys.usePerFolderColumnState)
        calculateAllSizes = defaults.bool(forKey: Keys.calculateAllSizes)
        inlineVideoPreview = defaults.bool(forKey: Keys.inlineVideoPreview)
        inlineAudioPreview = defaults.bool(forKey: Keys.inlineAudioPreview)
        videoSkimming = defaults.bool(forKey: Keys.videoSkimming)
        swipeToNavigate = defaults.bool(forKey: Keys.swipeToNavigate)
        backspaceGoesBack = defaults.bool(forKey: Keys.backspaceGoesBack)
        terminalAppBundleID = defaults.string(forKey: Keys.terminalAppBundleID) ?? Defaults.terminalAppBundleID
        newTabLocation = defaults.string(forKey: Keys.newTabLocation) ?? Defaults.newTabLocation
        newTabCustomPath = defaults.string(forKey: Keys.newTabCustomPath) ?? Defaults.newTabCustomPath
        showShareRibbon = defaults.bool(forKey: Keys.showShareRibbon)
        showDockProgress = defaults.bool(forKey: Keys.showDockProgress)
        showGitStatus = defaults.bool(forKey: Keys.showGitStatus)
        filterSearchesSubfolders = defaults.bool(forKey: Keys.filterSearchesSubfolders)
        offerInstallerCleanup = defaults.bool(forKey: Keys.offerInstallerCleanup)
        compressExcludeMacFiles = defaults.bool(forKey: Keys.compressExcludeMacFiles)
        compressionLevel = defaults.string(forKey: Keys.compressionLevel) ?? Defaults.compressionLevel
        imageQuality = defaults.double(forKey: Keys.imageQuality)
        restoreTabsOnLaunch = defaults.bool(forKey: Keys.restoreTabsOnLaunch)
        rememberViewOptionsPerFolder = defaults.bool(forKey: Keys.rememberViewOptionsPerFolder)
        translucentWindow = defaults.bool(forKey: Keys.translucentWindow)
        showDropStack = defaults.bool(forKey: Keys.showDropStack)
        dropStackKeepsItems = defaults.bool(forKey: Keys.dropStackKeepsItems)
        dragMovesWindowAside = defaults.bool(forKey: Keys.dragMovesWindowAside)
        compactViewModePicker = defaults.bool(forKey: Keys.compactViewModePicker)
    }

    func resetToDefaults() {
        showHiddenFiles = Defaults.showHiddenFiles
        showFileExtensions = Defaults.showFileExtensions
        foldersFirst = Defaults.foldersFirst
        showPathBar = Defaults.showPathBar
        showStatusBar = Defaults.showStatusBar
        soundEffectsEnabled = Defaults.soundEffectsEnabled
        showItemTags = Defaults.showItemTags
        useColorfulFileIcons = Defaults.useColorfulFileIcons
        sidebarShowFavorites = Defaults.sidebarShowFavorites
        sidebarShowICloud = Defaults.sidebarShowICloud
        sidebarShowLocations = Defaults.sidebarShowLocations
        sidebarShowTags = Defaults.sidebarShowTags
        preservedUnknownFavorites = []
        sidebarFavorites = Defaults.sidebarFavorites
        sidebarCollapsedSections = []
        sidebarLayout = .default
        thumbnailQuality = Defaults.thumbnailQuality
        masonryShowFilenames = Defaults.masonryShowFilenames

        listFontSize = Defaults.listFontSize
        listIconSize = Defaults.listIconSize

        iconGridIconSize = Defaults.iconGridIconSize
        iconGridFontSize = Defaults.iconGridFontSize
        iconGridSpacing = Defaults.iconGridSpacing

        columnFontSize = Defaults.columnFontSize
        columnIconSize = Defaults.columnIconSize
        columnWidth = Defaults.columnWidth
        columnShowPreview = Defaults.columnShowPreview
        columnPreviewWidth = Defaults.columnPreviewWidth

        coverFlowTitleFontSize = Defaults.coverFlowTitleFontSize
        coverFlowScale = Defaults.coverFlowScale
        coverFlowSwipeSpeed = Defaults.coverFlowSwipeSpeed
        coverFlowShowInfo = Defaults.coverFlowShowInfo
        coverFlowPanelInSplit = Defaults.coverFlowPanelInSplit
        coverFlowPaneHeight = Defaults.coverFlowPaneHeight
        coverFlowLayout = Defaults.coverFlowLayout
        coverFlowPanelWidth = Defaults.coverFlowPanelWidth
        usePerFolderColumnState = Defaults.usePerFolderColumnState
        calculateAllSizes = Defaults.calculateAllSizes
        inlineVideoPreview = Defaults.inlineVideoPreview
        inlineAudioPreview = Defaults.inlineAudioPreview
        videoSkimming = Defaults.videoSkimming
        swipeToNavigate = Defaults.swipeToNavigate
        backspaceGoesBack = Defaults.backspaceGoesBack
        terminalAppBundleID = Defaults.terminalAppBundleID
        newTabLocation = Defaults.newTabLocation
        newTabCustomPath = Defaults.newTabCustomPath
        showShareRibbon = Defaults.showShareRibbon
        showDockProgress = Defaults.showDockProgress
        showGitStatus = Defaults.showGitStatus
        filterSearchesSubfolders = Defaults.filterSearchesSubfolders
        offerInstallerCleanup = Defaults.offerInstallerCleanup
        compressExcludeMacFiles = Defaults.compressExcludeMacFiles
        compressionLevel = Defaults.compressionLevel
        imageQuality = Defaults.imageQuality
        restoreTabsOnLaunch = Defaults.restoreTabsOnLaunch
        rememberViewOptionsPerFolder = Defaults.rememberViewOptionsPerFolder
        translucentWindow = Defaults.translucentWindow
        showDropStack = Defaults.showDropStack
        dropStackKeepsItems = Defaults.dropStackKeepsItems
        dragMovesWindowAside = Defaults.dragMovesWindowAside
        compactViewModePicker = Defaults.compactViewModePicker
    }

    var listFont: Font {
        .system(size: listFontSize)
    }

    var listDetailFont: Font {
        .system(size: max(9, listFontSize - 2))
    }

    var listIconSizeValue: CGFloat {
        CGFloat(listIconSize)
    }

    var iconGridFont: Font {
        .system(size: iconGridFontSize)
    }

    var iconGridIconSizeValue: CGFloat {
        CGFloat(iconGridIconSize)
    }

    var iconGridSpacingValue: CGFloat {
        CGFloat(iconGridSpacing)
    }

    var columnFont: Font {
        .system(size: columnFontSize)
    }

    var columnDetailFont: Font {
        .system(size: max(9, columnFontSize - 2))
    }

    var columnPreviewTitleFont: Font {
        .system(size: max(11, columnFontSize + 2), weight: .semibold)
    }

    var columnIconSizeValue: CGFloat {
        CGFloat(columnIconSize)
    }

    var columnWidthValue: CGFloat {
        CGFloat(columnWidth)
    }

    var columnPreviewWidthValue: CGFloat {
        CGFloat(columnPreviewWidth)
    }

    var coverFlowTitleFont: Font {
        .system(size: coverFlowTitleFontSize, weight: .semibold)
    }

    var coverFlowDetailFont: Font {
        .system(size: max(9, coverFlowTitleFontSize - 3))
    }

    var coverFlowScaleValue: CGFloat {
        CGFloat(coverFlowScale)
    }

    var coverFlowSwipeSpeedValue: CGFloat {
        CGFloat(coverFlowSwipeSpeed)
    }

    var compactListFont: Font {
        .system(size: max(10, listFontSize - 1))
    }

    var compactListDetailFont: Font {
        .system(size: max(9, listFontSize - 3))
    }

    var compactListIconSize: CGFloat {
        max(14, CGFloat(listIconSize) - 4)
    }

    var dualPaneIconSize: CGFloat {
        max(32, CGFloat(iconGridIconSize) * 0.6)
    }

    var dualPaneFont: Font {
        .system(size: max(9, iconGridFontSize - 1))
    }

    var dualPaneGridSpacing: CGFloat {
        max(8, CGFloat(iconGridSpacing) * 0.7)
    }

    var quadPaneIconSize: CGFloat {
        max(28, CGFloat(iconGridIconSize) * 0.45)
    }

    var quadPaneFont: Font {
        .system(size: max(8, iconGridFontSize - 2))
    }

    var quadPaneGridSpacing: CGFloat {
        max(6, CGFloat(iconGridSpacing) * 0.5)
    }

    var thumbnailQualityValue: CGFloat {
        CGFloat(thumbnailQuality * 1.6)
    }

    /// Number of user-added (non-system) favorites, e.g. for the reset confirmation.
    var customFavoritesCount: Int {
        sidebarFavorites.filter { $0.kind == .custom }.count
    }

    private func persistSidebarFavorites() {
        if let unreadable = unreadableFavoritesData {
            // Never silently replace data we couldn't read: keep a copy before the first overwrite.
            if defaults.data(forKey: Keys.sidebarFavoritesUnreadableBackup) == nil {
                defaults.set(unreadable, forKey: Keys.sidebarFavoritesUnreadableBackup)
            }
            unreadableFavoritesData = nil
        }
        guard let data = SidebarFavoritesCoding.encode(sidebarFavorites, preserving: preservedUnknownFavorites) else { return }
        defaults.set(data, forKey: Keys.sidebarFavorites)
        defaults.set(SidebarFavoritesCoding.currentFormat, forKey: Keys.sidebarFavoritesFormat)
    }
}

struct SidebarFavorite: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case documents
        case applications
        case desktop
        case downloads
        case movies
        case music
        case pictures
        case custom
    }

    let id: String
    let kind: Kind
    /// Last known path of a custom favorite.
    let path: String?
    /// Bookmark to a custom favorite's folder, so renaming or moving the folder doesn't break the favorite.
    /// Favorites saved by older versions only have `path`; they get a bookmark the first time they resolve.
    let bookmark: Data?

    init(kind: Kind, id: String? = nil, path: String? = nil, bookmark: Data? = nil) {
        self.kind = kind
        self.path = path
        self.bookmark = bookmark
        if let id {
            self.id = id
        } else if kind == .custom {
            self.id = UUID().uuidString
        } else {
            self.id = kind.rawValue
        }
    }

    static func system(_ kind: Kind) -> SidebarFavorite {
        SidebarFavorite(kind: kind, id: kind.rawValue)
    }

    /// Creates a path-only custom favorite without touching the file system; the sidebar adds the bookmark when
    /// it next resolves favorites in the background.
    static func custom(path: String) -> SidebarFavorite {
        SidebarFavorite(kind: .custom, id: UUID().uuidString, path: path)
    }

    /// Creates a custom favorite for a folder, including a bookmark (touches the file system).
    static func custom(url: URL) -> SidebarFavorite {
        let standardized = url.standardizedFileURL
        return SidebarFavorite(kind: .custom, id: UUID().uuidString, path: standardized.path, bookmark: makeBookmark(for: standardized))
    }

    func withLocation(path: String, bookmark: Data?) -> SidebarFavorite {
        SidebarFavorite(kind: kind, id: id, path: path, bookmark: bookmark)
    }

    /// Resolves where the favorite points now. Touches the file system (bookmark resolution, existence checks),
    /// so call it off the main thread.
    func resolve(fileManager: FileManager = .default) -> SidebarFavoriteResolution {
        guard kind == .custom else {
            let location = kind.systemLocation
            let url = location?.url
            let isAvailable = url.map { fileManager.fileExists(atPath: $0.path) } ?? false
            return SidebarFavoriteResolution(
                favorite: self,
                url: url,
                name: location?.name ?? kind.rawValue.capitalized,
                isAvailable: isAvailable,
                updatedFavorite: nil
            )
        }

        let storedURL = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

        if let bookmark,
           let resolved = Self.resolveBookmark(bookmark),
           !Self.isInTrash(resolved.url),
           fileManager.fileExists(atPath: resolved.url.path) {
            let resolvedURL = resolved.url
            if let storedURL, Self.isSameLocation(storedURL, resolvedURL) {
                // Still where we left it (possibly spelled differently, e.g. /var vs /private/var): keep the stored path.
                let refreshed = resolved.isStale ? Self.makeBookmark(for: storedURL) : nil
                return SidebarFavoriteResolution(
                    favorite: self,
                    url: storedURL,
                    name: storedURL.finderDisplayName,
                    isAvailable: true,
                    updatedFavorite: refreshed.map { withLocation(path: storedURL.path, bookmark: $0) }
                )
            }
            // The folder was renamed or moved: follow it.
            return SidebarFavoriteResolution(
                favorite: self,
                url: resolvedURL,
                name: resolvedURL.finderDisplayName,
                isAvailable: true,
                updatedFavorite: withLocation(path: resolvedURL.path, bookmark: Self.makeBookmark(for: resolvedURL) ?? bookmark)
            )
        }

        guard let storedURL else {
            return SidebarFavoriteResolution(favorite: self, url: nil, name: String(localized: "Missing Folder"), isAvailable: false, updatedFavorite: nil)
        }

        let isAvailable = fileManager.fileExists(atPath: storedURL.path)
        // A path-only favorite from an older version, or a bookmark that no longer resolves while the path is
        // valid (the folder was replaced): bookmark whatever is at the path now.
        let newBookmark = isAvailable ? Self.makeBookmark(for: storedURL) : nil
        return SidebarFavoriteResolution(
            favorite: self,
            url: storedURL,
            name: storedURL.finderDisplayName,
            isAvailable: isAvailable,
            updatedFavorite: newBookmark.map { withLocation(path: storedURL.path, bookmark: $0) }
        )
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withoutImplicitSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return (url.standardizedFileURL, isStale)
    }

    /// A bookmark follows a folder into the Trash; a trashed favorite should read as missing instead.
    private static func isInTrash(_ url: URL) -> Bool {
        let components = url.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    private static func isSameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension SidebarFavorite.Kind {
    /// Display name and folder of a built-in favorite; nil for `.custom`.
    var systemLocation: (name: String, url: URL?)? {
        let fm = FileManager.default
        func location(_ name: String, _ url: URL?) -> (name: String, url: URL?) {
            (url?.localizedFolderName ?? name, url)
        }
        switch self {
        case .documents:
            return location("Documents", fm.urls(for: .documentDirectory, in: .userDomainMask).first)
        case .applications:
            return location("Applications", fm.urls(for: .applicationDirectory, in: .localDomainMask).first)
        case .desktop:
            return location("Desktop", fm.urls(for: .desktopDirectory, in: .userDomainMask).first)
        case .downloads:
            return location("Downloads", fm.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        case .movies:
            return location("Movies", fm.urls(for: .moviesDirectory, in: .userDomainMask).first)
        case .music:
            return location("Music", fm.urls(for: .musicDirectory, in: .userDomainMask).first)
        case .pictures:
            return location("Pictures", fm.urls(for: .picturesDirectory, in: .userDomainMask).first)
        case .custom:
            return nil
        }
    }
}

/// Where a favorite points right now, from `SidebarFavorite.resolve()`.
struct SidebarFavoriteResolution: Equatable, Sendable {
    /// The favorite that was resolved.
    let favorite: SidebarFavorite
    let url: URL?
    let name: String
    let isAvailable: Bool
    /// Set when the stored favorite should be replaced: the folder moved, or its bookmark was created or refreshed.
    let updatedFavorite: SidebarFavorite?

    /// The folder was renamed or moved (as opposed to only getting a new bookmark).
    var didMove: Bool {
        guard let updatedFavorite else { return false }
        return updatedFavorite.path != favorite.path
    }
}

/// Element-wise coding of the stored favorites list, so one entry this version doesn't understand (e.g. a `Kind`
/// added by a newer version) doesn't throw away the whole list.
enum SidebarFavoritesCoding {
    /// Stored next to the favorites (see `AppSettings`). Format 2: an empty list means no favorites (1.38 and earlier
    /// showed the defaults for it).
    static let currentFormat = 2

    /// A stored element that didn't decode, kept verbatim (with its position) so it's written back unchanged.
    struct UnknownElement: Equatable {
        let index: Int
        let json: Data
    }

    enum DecodeResult: Equatable {
        /// Nothing stored yet: use the default favorites.
        case notSet
        /// Every element that could be decoded (possibly none: an empty list is a valid user choice).
        case decoded([SidebarFavorite], unknown: [UnknownElement])
        /// The stored value isn't a list at all.
        case unreadable
    }

    static func decode(_ data: Data?) -> DecodeResult {
        guard let data else { return .notSet }
        guard let elements = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any] else {
            return .unreadable
        }

        let decoder = JSONDecoder()
        var favorites: [SidebarFavorite] = []
        var unknown: [UnknownElement] = []
        for (index, element) in elements.enumerated() {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed]) else {
                continue
            }
            if let favorite = try? decoder.decode(SidebarFavorite.self, from: elementData) {
                favorites.append(favorite)
            } else {
                unknown.append(UnknownElement(index: index, json: elementData))
            }
        }
        return .decoded(favorites, unknown: unknown)
    }

    static func encode(_ favorites: [SidebarFavorite], preserving unknown: [UnknownElement]) -> Data? {
        guard let data = try? JSONEncoder().encode(favorites) else { return nil }
        guard !unknown.isEmpty,
              var elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return data }

        for element in unknown.sorted(by: { $0.index < $1.index }) {
            guard let object = try? JSONSerialization.jsonObject(with: element.json, options: [.fragmentsAllowed]) else { continue }
            elements.insert(object, at: min(element.index, elements.count))
        }
        return (try? JSONSerialization.data(withJSONObject: elements)) ?? data
    }
}
