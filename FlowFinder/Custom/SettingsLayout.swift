import SwiftUI
import FinderSync

/// The Settings window: toolbar tabs by topic, each sized to its content like Finder's settings.
struct SettingsLayoutView: View {
    enum Pane: String {
        case general, display, tabsAndWindows, interaction, files, sidebar, coverFlow, viewFormats, advanced
    }

    @State private var selection: Pane = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsPane()
                .settingsPaneSize(height: 515)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general)
            DisplaySettingsPane()
                .settingsPaneSize(height: 620)
                .tabItem { Label("Display", systemImage: "eye") }
                .tag(Pane.display)
            TabsAndWindowsSettingsPane()
                .settingsPaneSize(height: 345)
                .tabItem { Label("Tabs & Windows", systemImage: "macwindow.on.rectangle") }
                .tag(Pane.tabsAndWindows)
            InteractionSettingsPane()
                .settingsPaneSize(height: 625)
                .tabItem { Label("Interaction", systemImage: "cursorarrow.click.2") }
                .tag(Pane.interaction)
            FilesSettingsPane()
                .settingsPaneSize(height: 535)
                .tabItem { Label("Files", systemImage: "doc.on.doc") }
                .tag(Pane.files)
            SidebarLayoutSettingsView()
                .padding(20)
                .frame(width: 640, height: 480)
                .tabItem { Label("Sidebar", systemImage: "sidebar.left") }
                .tag(Pane.sidebar)
            CoverFlowSettingsPane()
                .settingsPaneSize(height: 480)
                .tabItem { Label("Cover Flow", systemImage: "square.stack.3d.forward.dottedline") }
                .tag(Pane.coverFlow)
            ViewFormatSettingsPane()
                .settingsPaneSize(height: 400)
                .tabItem { Label("View Formats", systemImage: "square.grid.2x2") }
                .tag(Pane.viewFormats)
            AdvancedSettingsPane()
                .settingsPaneSize(height: 340)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
                .tag(Pane.advanced)
        }
    }
}

private extension View {
    func settingsPaneSize(height: CGFloat) -> some View {
        formStyle(.grouped).frame(width: 640, height: height)
    }
}

private struct SettingsCaption: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Restore tabs on launch", isOn: $settings.restoreTabsOnLaunch)
                NewTabLocationSetting()
            }
            Section {
                DefaultFolderBrowserSetting()
            } header: {
                Text("Default Folder Browser")
            } footer: {
                SettingsCaption("Folders opened from other apps and the Dock open in FlowFinder instead of Finder.")
            }
            Section("Sound and Dock") {
                Toggle("Play sound effects", isOn: $settings.soundEffectsEnabled)
                Toggle("Show file operation progress on the Dock icon", isOn: $settings.showDockProgress)
            }
            Section("Updates") {
                LabeledContent("Check for a newer version of CoverFlowFinder") {
                    Button("Check Now") { UpstreamUpdateChecker.checkForUpdates() }
                }
            }
        }
    }
}

// MARK: - Display

private struct DisplaySettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Icons") {
                Toggle("Use easy-to-read file icons", isOn: $settings.useColorfulFileIcons)
                SettingsCaption("Show the file type on the icon in list views, with the default app as a badge.")
                Toggle("Show item tags", isOn: $settings.showItemTags)
                SettingsSliderRow(title: "Thumbnail quality", value: $settings.thumbnailQuality, range: 0.5...1.6, step: 0.05, format: "%.2fx")
            }
            Section("Items") {
                Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
                Toggle("Show all filename extensions", isOn: $settings.showFileExtensions)
                Toggle("Keep folders on top", isOn: $settings.foldersFirst)
                Toggle("Calculate all sizes", isOn: $settings.calculateAllSizes)
                SettingsCaption("Show the total size of folders in the Size column. Sizes are calculated in the background.")
            }
            Section {
                Toggle("Remember view options per folder", isOn: $settings.rememberViewOptionsPerFolder)
                Toggle("Remember column settings per folder", isOn: $settings.usePerFolderColumnState)
            } header: {
                Text("Per-Folder View Options")
            } footer: {
                SettingsCaption("Each folder keeps its own view, sort order and list columns, like Finder. When off, every folder uses the same settings.")
            }
        }
    }
}

// MARK: - Tabs & Windows

private struct TabsAndWindowsSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Window") {
                Toggle("Translucent window", isOn: $settings.translucentWindow)
                Toggle("Combine view mode buttons", isOn: $settings.compactViewModePicker)
                Toggle("Move the window to the edge of the screen when dragging items out of it", isOn: $settings.dragMovesWindowAside)
                SettingsCaption("Lets you drop items on the windows behind it.")
            }
            Section("Path Bar and Status Bar") {
                Toggle("Show path bar", isOn: $settings.showPathBar)
                Toggle("Show status bar", isOn: $settings.showStatusBar)
            }
        }
    }
}

// MARK: - Interaction

private struct InteractionSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    private var terminalApps: [TerminalLauncher.App] {
        var apps = TerminalLauncher.installedApps
        if !apps.contains(where: { $0.bundleID == settings.terminalAppBundleID }) {
            apps.append(TerminalLauncher.App(bundleID: settings.terminalAppBundleID, name: settings.terminalAppBundleID))
        }
        return apps
    }

    var body: some View {
        Form {
            Section {
                Toggle("Swipe with the trackpad to go back and forward", isOn: $settings.swipeToNavigate)
                Toggle("Backspace goes back", isOn: $settings.backspaceGoesBack)
            } header: {
                Text("Navigation")
            } footer: {
                SettingsCaption("Command-double-click a folder to open it in a new tab. While dragging, hold over a folder to open it (spring-loading).")
            }
            Section("Hover Previews") {
                Toggle("Inline video preview on hover", isOn: $settings.inlineVideoPreview)
                Toggle("Video skimming", isOn: $settings.videoSkimming)
                    .disabled(!settings.inlineVideoPreview)
                SettingsCaption("Scrub through video by moving the mouse across the thumbnail")
                Toggle("Inline audio preview on hover", isOn: $settings.inlineAudioPreview)
            }
            Section("Terminal") {
                Picker("Open in Terminal with", selection: $settings.terminalAppBundleID) {
                    ForEach(terminalApps) { app in
                        Text(verbatim: app.name).tag(app.bundleID)
                    }
                }
            }
            Section {
                Toggle("Show Drop Stack", isOn: $settings.showDropStack)
                Toggle("Keep items in the Drop Stack after dragging them out", isOn: $settings.dropStackKeepsItems)
                    .disabled(!settings.showDropStack)
            } header: {
                Text("Drop Stack")
            } footer: {
                SettingsCaption("A shelf at the edge of the window to collect items while you move between folders.")
            }
        }
    }
}

// MARK: - Files

private struct FilesSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Compression") {
                Toggle("Exclude Mac-specific files when compressing (.DS_Store, __MACOSX…)", isOn: $settings.compressExcludeMacFiles)
                Picker("Compression level", selection: $settings.compressionLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.title).tag(level.rawValue)
                    }
                }
            }
            Section("Conversion") {
                LabeledContent("Image quality when converting (JPEG, HEIC)") {
                    HStack {
                        Slider(value: $settings.imageQuality, in: 0.1...1, step: 0.05)
                            .frame(width: 140)
                        Text(verbatim: "\(Int((settings.imageQuality * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Installers") {
                Toggle("After installing an app, offer to move its disk image or archive to the Trash", isOn: $settings.offerInstallerCleanup)
            }
            Section {
                LabeledContent("New File templates") {
                    Button("Open Templates Folder") { NewFileCreator.openTemplatesFolder() }
                }
            } header: {
                Text("New File")
            } footer: {
                SettingsCaption("Files you put in the templates folder appear in the New File menu.")
            }
            Section("Filter") {
                Toggle("Include subfolders when filtering", isOn: $settings.filterSearchesSubfolders)
            }
        }
    }
}

// MARK: - Cover Flow

private struct CoverFlowSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Position", selection: $settings.coverFlowLayout) {
                    Text("Right panel").tag("right")
                    Text("Top (classic)").tag("top")
                }
                SettingsSliderRow(title: "Cover scale", value: $settings.coverFlowScale, range: 0.8...2.0, step: 0.05, format: "%.2fx")
                Toggle("Show info panel", isOn: $settings.coverFlowShowInfo)
            }
            Section {
                Toggle("Show the Cover Flow panel in split tabs", isOn: $settings.coverFlowPanelInSplit)
                    .disabled(settings.coverFlowLayout == "top")
            } header: {
                Text("Split Tabs")
            } footer: {
                SettingsCaption("Available when the position is Right panel.")
            }
            Section("Motion") {
                SettingsSliderRow(title: "Swipe speed", value: $settings.coverFlowSwipeSpeed, range: 0.5...2.0, step: 0.05, format: "%.2fx")
            }
            Section("Text") {
                SettingsSliderRow(title: "Title size", value: $settings.coverFlowTitleFontSize, range: 12...22, step: 1, format: "%.0f pt")
            }
        }
    }
}

// MARK: - View formats

private struct ViewFormatSettingsPane: View {
    private enum Format: String, CaseIterable {
        case icons, list, columns, masonry

        var title: LocalizedStringKey {
            switch self {
            case .icons: "Icons"
            case .list: "List"
            case .columns: "Columns"
            case .masonry: "Masonry"
            }
        }
    }

    @EnvironmentObject private var settings: AppSettings
    @State private var format: Format = .icons

    var body: some View {
        VStack(spacing: 0) {
            Picker("View Format", selection: $format) {
                ForEach(Format.allCases, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)
            Form {
                switch format {
                case .icons: icons
                case .list: list
                case .columns: columns
                case .masonry: masonry
                }
            }
        }
    }

    @ViewBuilder private var icons: some View {
        Section("Icons") {
            SettingsSliderRow(title: "Icon size", value: $settings.iconGridIconSize, range: 48...160, step: 4, format: "%.0f pt")
            SettingsSliderRow(title: "Grid spacing", value: $settings.iconGridSpacing, range: 12...40, step: 2, format: "%.0f pt")
        }
        Section("Text") {
            SettingsSliderRow(title: "Label size", value: $settings.iconGridFontSize, range: 9...16, step: 1, format: "%.0f pt")
        }
    }

    @ViewBuilder private var list: some View {
        Section("Text") {
            SettingsSliderRow(title: "Font size", value: $settings.listFontSize, range: 10...18, step: 1, format: "%.0f pt")
        }
        Section("Icons") {
            SettingsSliderRow(title: "Icon size", value: $settings.listIconSize, range: 14...32, step: 1, format: "%.0f pt")
        }
    }

    @ViewBuilder private var columns: some View {
        Section("Layout") {
            SettingsSliderRow(title: "Column width", value: $settings.columnWidth, range: 160...360, step: 10, format: "%.0f pt")
            Toggle("Show preview column", isOn: $settings.columnShowPreview)
            SettingsSliderRow(title: "Preview width", value: $settings.columnPreviewWidth, range: 200...420, step: 10, format: "%.0f pt")
                .disabled(!settings.columnShowPreview)
        }
        Section("Text") {
            SettingsSliderRow(title: "Font size", value: $settings.columnFontSize, range: 10...18, step: 1, format: "%.0f pt")
        }
        Section("Icons") {
            SettingsSliderRow(title: "Icon size", value: $settings.columnIconSize, range: 12...28, step: 1, format: "%.0f pt")
        }
    }

    @ViewBuilder private var masonry: some View {
        Section("Labels") {
            Toggle("Show filenames", isOn: $settings.masonryShowFilenames)
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var extensionEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("Show Git status", isOn: $settings.showGitStatus)
            } header: {
                Text("Git")
            } footer: {
                SettingsCaption("Show changes in Git repositories next to file names.")
            }
            Section {
                LabeledContent {
                    Button("Open System Settings…") { FIFinderSyncController.showExtensionManagementInterface() }
                } label: {
                    Text(extensionEnabled ? LocalizedStringKey("The Finder extension is on.") : LocalizedStringKey("The Finder extension is off."))
                }
            } header: {
                Text("Finder Extension")
            } footer: {
                SettingsCaption("Adds Open in FlowFinder to Finder's shortcut menus. Turn it on in the Extensions settings in System Settings.")
            }
            Section {
                LabeledContent("Return all settings to their defaults") {
                    Button("Reset to Defaults…") { showingResetConfirmation = true }
                }
            } header: {
                Text("Reset")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            extensionEnabled = FIFinderSyncController.isExtensionEnabled
        }
        .alert("Reset all settings to their defaults?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetConfirmationMessage)
        }
    }

    private var resetConfirmationMessage: String {
        var message = String(localized: "This resets every setting in all tabs (visibility, sorting, thumbnails, previews, sound, view sizes and sidebar sections) and restores the default sidebar Favorites: Documents, Applications, Desktop, Downloads, Movies, Music and Pictures.")
        let customCount = settings.customFavoritesCount
        if customCount > 0 {
            message += " " + String(localized: "Your \(customCount) custom favorites will be removed from the sidebar.")
        }
        message += " " + String(localized: "Files and folders are not affected.")
        return message
    }
}
