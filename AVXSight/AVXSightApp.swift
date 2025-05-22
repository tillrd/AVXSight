// AVXSightApp.swift

import SwiftUI
import AppKit // Needed for NSOpenPanel, NSWorkspace, FileManager etc. in PluginManager

// MARK: - App Entry Point

@main
struct AVXSightApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView() // ContentView is defined in ContentView.swift
        }
        .windowStyle(DefaultWindowStyle())
        .commands {
            CommandGroup(replacing: CommandGroupPlacement.newItem, addition: {})
        }
    }
}

// MARK: - Data Model

// Conforms to Sendable as all its properties (UUID, String, Bool) are Sendable.
struct Plugin: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let type: String
    let path: String
    let isUserDomain: Bool
    let version: String?
    let manufacturer: String?
    let pluginDescription: String?

    init(name: String, type: String, path: String, isUserDomain: Bool, version: String? = nil, manufacturer: String? = nil, pluginDescription: String? = nil) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.path = path
        self.isUserDomain = isUserDomain
        self.version = version
        self.manufacturer = manufacturer
        self.pluginDescription = pluginDescription
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    static func == (lhs: Plugin, rhs: Plugin) -> Bool {
        lhs.path == rhs.path
    }
}

// MARK: - Error Structure for Alerts

// Conforms to Sendable as its properties (UUID, String) are Sendable.
struct ErrorAlert: Identifiable, Sendable {
    let id: UUID = UUID() // Can provide default UUID
    let message: String
}


// MARK: - Plugin Manager Class

@MainActor // Ensures class methods and properties are accessed on the main thread by default
class PluginManager: ObservableObject {
    static let shared = PluginManager() // Singleton instance

    // Only system Library
    private let fileExtensions: Set<String> = ["component", "vst3", "vst", "aaxplugin"]
    private let systemLibraryPath = "/Library"
    private let systemLibraryBookmarkKey = "systemLibraryBookmarkData"

    @Published var fetchedPlugins: Set<Plugin> = []
    @Published var isLoading: Bool = false
    @Published var errorAlert: ErrorAlert?

    private(set) var systemLibraryURL: URL?

    // Remove all user library logic

    // One-time clear of old system bookmark
    private func clearAllBookmarksOnce() {
        UserDefaults.standard.removeObject(forKey: systemLibraryBookmarkKey)
        print("Cleared old system bookmark")
    }

    private init() {
        clearAllBookmarksOnce()
        loadBookmarks()
        print("PluginManager initialized. System Bookmark URL: \(systemLibraryURL?.path ?? "nil")")
    }

    func scanForPlugins() async {
        self.isLoading = true
        self.errorAlert = nil
        await ensureAccess(for: systemLibraryPath, key: systemLibraryBookmarkKey)
        let capturedSystemURL = self.systemLibraryURL
        let capturedFileExtensions = self.fileExtensions
        print("Starting background scan task...")
        let scanResult: Result<Set<Plugin>, Error> = await Task.detached(priority: .userInitiated) {
            var combinedPlugins: Set<Plugin> = []
            var encounteredError: Error? = nil
            func scanLibrary(url: URL?, description: String) async -> (Set<Plugin>, Error?) {
                guard let currentURL = url else {
                    print("Background Task: No URL provided for \(description).")
                    return ([], nil)
                }
                let accessStarted = currentURL.startAccessingSecurityScopedResource()
                guard accessStarted else {
                    print("Background Task: Failed to start security access for \(description): \(currentURL.path)")
                    return ([], NSError(domain: "PluginManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start security access for \(description)."]))
                }
                defer { currentURL.stopAccessingSecurityScopedResource() }
                print("Background Task: Scanning \(description): \(currentURL.path)")
                let (plugins, error) = await PluginManager.performScanInBackground(
                    libraryURL: currentURL,
                    fileExtensions: capturedFileExtensions
                )
                print("Background Task: Finished scanning \(description). Found \(plugins.count) plugins.")
                return (plugins, error)
            }
            let (systemPlugins, systemError) = await scanLibrary(url: capturedSystemURL, description: "System Library")
            combinedPlugins.formUnion(systemPlugins)
            if systemError != nil { encounteredError = systemError }
            if let error = encounteredError {
                return .failure(error)
            } else {
                return .success(combinedPlugins)
            }
        }.value
        self.isLoading = false
        switch scanResult {
        case .success(let allPlugins):
            self.fetchedPlugins = allPlugins
            print("Scan complete. Found \(self.fetchedPlugins.count) plugins.")
            if self.fetchedPlugins.isEmpty && self.systemLibraryURL == nil {
                 self.errorAlert = ErrorAlert(message: "Could not access /Library. Please grant access via the Refresh button or check System Settings > Privacy & Security > Files and Folders.")
            } else if self.errorAlert == nil && self.fetchedPlugins.isEmpty {
                 print("Scan complete, no plugins found in /Library.")
            }
        case .failure(let error):
             print("Scan failed with error: \(error.localizedDescription)")
             self.errorAlert = ErrorAlert(message: "Failed during plugin scan: \(error.localizedDescription)")
        }
    }

    private func ensureAccess(for path: String, key: String) async {
        let targetURL = URL(fileURLWithPath: path)
        let currentURL = self.systemLibraryURL
        if currentURL != nil {
            print("Access already established for \(path)")
            return
        }
        print("Attempting to request access for \(targetURL.path)...")
        let granted = await requestAccessAndBookmark(for: targetURL, key: key)
        if granted {
            print("Access granted for \(path). Reloading bookmark.")
            loadBookmark(forKey: key)
             let newlyLoadedURL = self.systemLibraryURL
             if newlyLoadedURL == nil {
                 print("Error: Bookmark saved but failed to load immediately for \(path).")
                 if self.errorAlert == nil {
                    self.errorAlert = ErrorAlert(message: "Could not immediately use the granted access for \(targetURL.lastPathComponent). Please try refreshing again.")
                 }
             } else {
                 print("Bookmark successfully loaded for \(path) after granting access.")
             }
        } else if self.errorAlert == nil {
             print("Access denied or failed for \(path).")
             self.errorAlert = ErrorAlert(message: "Could not get access to \(targetURL.lastPathComponent). Some plugins may not be listed.")
        }
    }

    private func saveBookmark(for url: URL, key: String) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: key)
            UserDefaults.standard.synchronize()
            print("Successfully saved bookmark for \(url.path) under key '\(key)'")
        } catch {
            print("Error saving bookmark for \(url.path): \(error.localizedDescription)")
            self.errorAlert = ErrorAlert(message: "Could not save access permissions for \(url.lastPathComponent). You might be asked again later.")
        }
    }

    private func loadBookmarks() {
        print("Loading bookmarks...")
        loadBookmark(forKey: self.systemLibraryBookmarkKey)
    }

    private func loadBookmark(forKey key: String) {
        guard let bookmarkData = UserDefaults.standard.data(forKey: key) else {
            print("No bookmark data found for key: \(key)")
            self.systemLibraryURL = nil
            return
        }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else {
                 print("Could not start accessing security scoped resource on load for \(key) (\(url.path))")
                 throw NSError(domain: "PluginManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not start accessing bookmarked URL."])
            }
            url.stopAccessingSecurityScopedResource()
            if isStale {
                print("Bookmark data is stale for key: \(key) (\(url.path)). Attempting to refresh.")
                saveBookmark(for: url, key: key)
                if self.errorAlert != nil {
                    print("Failed to refresh stale bookmark for key \(key). Removing.")
                    UserDefaults.standard.removeObject(forKey: key)
                    self.systemLibraryURL = nil
                    return
                }
            }
            self.systemLibraryURL = url
            print("Successfully loaded bookmark for System Library: \(url.path)")
        } catch {
            print("Error resolving bookmark data for key \(key): \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: key)
            self.systemLibraryURL = nil
            if self.errorAlert == nil {
                 self.errorAlert = ErrorAlert(message: "Saved access permission for /Library is no longer valid. Please use Refresh to grant access again.")
            }
        }
    }

    static private func performScanInBackground(libraryURL: URL, fileExtensions: Set<String>) async -> (Set<Plugin>, Error?) {
        let pluginDirectories = [
            libraryURL.appendingPathComponent("Audio/Plug-Ins/Components"),
            libraryURL.appendingPathComponent("Audio/Plug-Ins/VST3"),
            libraryURL.appendingPathComponent("Audio/Plug-Ins/VST"),
            libraryURL.appendingPathComponent("Application Support/Avid/Audio/Plug-Ins")
        ]
        var combinedPlugins: Set<Plugin> = []
        var firstError: Error? = nil
        await withTaskGroup(of: (Set<Plugin>, Error?).self) { group in
            for directory in pluginDirectories {
                group.addTask {
                    return Self.getPluginsInBackground(
                        directory: directory,
                        fileExtensions: fileExtensions
                    )
                }
            }
            for await (plugins, error) in group {
                combinedPlugins.formUnion(plugins)
                if firstError == nil && error != nil {
                    firstError = error
                }
            }
        }
        return (combinedPlugins, firstError)
    }

    static nonisolated private func getPluginsInBackground(directory: URL, fileExtensions: Set<String>) -> (Set<Plugin>, Error?) {
        var plugins: Set<Plugin> = []
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return ([], nil)
            }
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey], options: [.skipsHiddenFiles])
            for fileURL in fileURLs {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isHiddenKey]),
                      resourceValues.isHidden == false else {
                    continue
                }
                let fileExtension = fileURL.pathExtension.lowercased()
                if fileExtensions.contains(fileExtension) {
                    let name = fileURL.deletingPathExtension().lastPathComponent
                    if !name.starts(with: ".") {
                        let (version, manufacturer, pluginDescription) = Self.extractPluginMetadata(fileURL: fileURL, type: fileExtension)
                        let plugin = Plugin(name: name, type: fileExtension, path: fileURL.path, isUserDomain: false, version: version, manufacturer: manufacturer, pluginDescription: pluginDescription)
                        plugins.insert(plugin)
                    }
                }
            }
            return (plugins, nil)
        } catch {
            return (plugins, error)
        }
    }

    static nonisolated private func extractPluginMetadata(fileURL: URL, type: String) -> (String?, String?, String?) {
        if type == "component" || type == "vst3" {
            let infoPlistURL: URL
            if type == "component" {
                infoPlistURL = fileURL.appendingPathComponent("Contents/Info.plist")
            } else if type == "vst3" {
                infoPlistURL = fileURL.appendingPathComponent("Contents/Info.plist")
            } else {
                return (nil, nil, nil)
            }
            if let dict = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] {
                let version = dict["CFBundleShortVersionString"] as? String
                let manufacturer = dict["CFBundleIdentifier"] as? String
                let desc = dict["CFBundleGetInfoString"] as? String
                return (version, manufacturer, desc)
            }
        }
        return (nil, nil, nil)
    }

    @MainActor
    private func requestAccessAndBookmark(for url: URL, key: String) async -> Bool {
        self.errorAlert = nil
        let openPanel = NSOpenPanel()
        openPanel.message = "Please select the 'Library' folder at the top level of your disk (Macintosh HD > Library)."
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = [.folder]
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.directoryURL = URL(fileURLWithPath: "/")
        openPanel.showsHiddenFiles = false
        let response = await openPanel.begin()
        guard response == .OK, let selectedURL = openPanel.url else {
            print("User cancelled or denied access request for \(url.path)")
            return false
        }
        let expectedPath = "/Library"
        if selectedURL.standardizedFileURL.path == "/" {
            print("User selected the whole disk ('/'). Not allowed.")
            self.errorAlert = ErrorAlert(message: "You selected the whole disk (Macintosh HD). Please open the 'Library' folder and select it. You cannot select the entire disk.\n\nDouble-click 'Library' in the dialog, then click 'Grant Access'.")
            return false
        }
        guard selectedURL.standardizedFileURL.path == expectedPath else {
            print("Incorrect folder selected. Expected '/Library', but user selected '\(selectedURL.path)'.")
            self.errorAlert = ErrorAlert(message: "Incorrect folder selected. Please select the 'Library' folder at the top level of your disk (Macintosh HD > Library).\n\nDouble-click 'Library' in the dialog, then click 'Grant Access'.")
            return false
        }
        print("Correct folder '/Library' selected. Saving bookmark.")
        saveBookmark(for: selectedURL, key: key)
        return self.errorAlert == nil
    }
} // End of PluginManager class
