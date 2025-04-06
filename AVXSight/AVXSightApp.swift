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

    init(name: String, type: String, path: String, isUserDomain: Bool) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.path = path
        self.isUserDomain = isUserDomain
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

    // Immutable properties (constants) are inherently thread-safe
    private let fileExtensions: Set<String> = ["component", "vst3", "vst", "aaxplugin"]
    private let systemLibraryPath = "/Library"
    private lazy var userLibraryPath: String = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!.path
    }()
    private let systemLibraryBookmarkKey = "systemLibraryBookmarkData"
    private let userLibraryBookmarkKey = "userLibraryBookmarkData"

    // @Published properties will be updated on the Main Actor
    @Published var fetchedPlugins: Set<Plugin> = []
    @Published var isLoading: Bool = false
    @Published var errorAlert: ErrorAlert?

    // These URLs will be accessed/modified on the Main Actor
    // Make them Sendable for capture in detached Task if needed, though URL is Sendable.
    private(set) var systemLibraryURL: URL?
    private(set) var userLibraryURL: URL?

    // init runs on Main Actor
    private init() {
        loadBookmarks()
        print("PluginManager initialized. System Bookmark URL: \(systemLibraryURL?.path ?? "nil"), User Bookmark URL: \(userLibraryURL?.path ?? "nil")")
    }

    // MARK: - Public Scan Function (MainActor)

    func scanForPlugins() async {
        // Updates are safe as we are on Main Actor
        self.isLoading = true
        self.errorAlert = nil

        // Access checks run on MainActor
        await ensureAccess(for: systemLibraryPath, key: systemLibraryBookmarkKey)
        await ensureAccess(for: userLibraryPath, key: userLibraryBookmarkKey)

        // Capture necessary state safely before moving to background
        let capturedSystemURL = self.systemLibraryURL // URL is Sendable
        let capturedUserURL = self.userLibraryURL     // URL is Sendable
        let capturedFileExtensions = self.fileExtensions // Set<String> is Sendable

        print("Starting background scan task...")

        // Use Task.detached to run blocking I/O off the main thread
        let scanResult: Result<Set<Plugin>, Error> = await Task.detached(priority: .userInitiated) {
            // --- Background Task Execution ---
            var combinedPlugins: Set<Plugin> = []
            var encounteredError: Error? = nil

            // Helper function within the detached task to scan a single library
            // It needs access to capturedFileExtensions.
            func scanLibrary(url: URL?, isUserDomain: Bool, description: String) async -> (Set<Plugin>, Error?) {
                guard let currentURL = url else {
                    print("Background Task: No URL provided for \(description).")
                    return ([], nil)
                }

                let accessStarted = currentURL.startAccessingSecurityScopedResource()
                guard accessStarted else {
                    print("Background Task: Failed to start security access for \(description): \(currentURL.path)")
                    // Consider returning an error here if critical
                    return ([], NSError(domain: "PluginManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start security access for \(description)."]))
                }
                defer { currentURL.stopAccessingSecurityScopedResource() }

                print("Background Task: Scanning \(description): \(currentURL.path)")
                // Pass captured extensions to the scanning function
                // *** Call static func on Type name 'PluginManager' ***
                let (plugins, error) = await PluginManager.performScanInBackground(
                    libraryURL: currentURL,
                    isUserDomain: isUserDomain,
                    fileExtensions: capturedFileExtensions // Pass captured extensions
                )
                print("Background Task: Finished scanning \(description). Found \(plugins.count) plugins.")
                return (plugins, error)
            }

            // Scan System Library
            let (systemPlugins, systemError) = await scanLibrary(url: capturedSystemURL, isUserDomain: false, description: "System Library")
            combinedPlugins.formUnion(systemPlugins)
            if systemError != nil { encounteredError = systemError }

            // Scan User Library
            let (userPlugins, userError) = await scanLibrary(url: capturedUserURL, isUserDomain: true, description: "User Library")
            combinedPlugins.formUnion(userPlugins)
            if userError != nil && encounteredError == nil { encounteredError = userError } // Keep first error

            // Return result
            if let error = encounteredError {
                return .failure(error)
            } else {
                return .success(combinedPlugins)
            }
        }.value // Get the result from the detached task

        // --- Back on MainActor: Update State ---
        self.isLoading = false

        switch scanResult {
        case .success(let allPlugins):
            self.fetchedPlugins = allPlugins
            print("Scan complete. Found \(self.fetchedPlugins.count) plugins.")
            if self.fetchedPlugins.isEmpty && self.systemLibraryURL == nil && self.userLibraryURL == nil {
                 self.errorAlert = ErrorAlert(message: "Could not access plugin folders. Please grant access via the Refresh button or check System Settings > Privacy & Security > Files and Folders.")
            } else if self.errorAlert == nil && self.fetchedPlugins.isEmpty {
                 print("Scan complete, no plugins found in accessible locations.")
                 // self.errorAlert = ErrorAlert(message: "No audio plugins found in the standard locations.")
            }
        case .failure(let error):
             print("Scan failed with error: \(error.localizedDescription)")
             self.errorAlert = ErrorAlert(message: "Failed during plugin scan: \(error.localizedDescription)")
        }
    }

    // MARK: - Access & Bookmarking (Run on MainActor)

    // Called by scanForPlugins (MainActor) -> runs on MainActor
    private func ensureAccess(for path: String, key: String) async {
        let targetURL = URL(fileURLWithPath: path)
        let currentURL = (key == systemLibraryBookmarkKey) ? self.systemLibraryURL : self.userLibraryURL

        if currentURL != nil {
            print("Access already established for \(path)")
            return // Already have access
        }

        print("Attempting to request access for \(path)...")
        // requestAccessAndBookmark is @MainActor
        let granted = await requestAccessAndBookmark(for: targetURL, key: key)

        if granted {
            print("Access granted for \(path). Reloading bookmark.")
            loadBookmark(forKey: key) // Runs on MainActor
             let newlyLoadedURL = (key == systemLibraryBookmarkKey) ? self.systemLibraryURL : self.userLibraryURL
             if newlyLoadedURL == nil {
                 print("Error: Bookmark saved but failed to load immediately for \(path).")
                 // Avoid overwriting a more specific error possibly set during requestAccess
                 if self.errorAlert == nil {
                    self.errorAlert = ErrorAlert(message: "Could not immediately use the granted access for \(targetURL.lastPathComponent). Please try refreshing again.")
                 }
             } else {
                 print("Bookmark successfully loaded for \(path) after granting access.")
             }
        } else if self.errorAlert == nil { // Show generic denial only if specific error wasn't set
             print("Access denied or failed for \(path).")
             self.errorAlert = ErrorAlert(message: "Could not get access to \(targetURL.lastPathComponent). Some plugins may not be listed.")
        }
    }

    // NSOpenPanel requires MainActor
    @MainActor
    private func requestAccessAndBookmark(for url: URL, key: String) async -> Bool {
        // Reset error specific to this action before starting
        self.errorAlert = nil

        let openPanel = NSOpenPanel()
        openPanel.message = "Grant Access to Folder: \(url.lastPathComponent)\n\nThis app needs access to this folder to find audio plugins."
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = [.folder]
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.directoryURL = url.deletingLastPathComponent()

        let response = await openPanel.begin()

        guard response == .OK, let selectedURL = openPanel.url else {
            print("User cancelled or denied access request for \(url.path)")
            return false // No error alert needed for simple cancellation
        }

        guard selectedURL.standardizedFileURL == url.standardizedFileURL else {
            let desiredName = url.lastPathComponent
            let selectedName = selectedURL.lastPathComponent
            print("Incorrect folder selected. Expected '\(desiredName)', but user selected '\(selectedName)'.")
            self.errorAlert = ErrorAlert(message: "Incorrect folder selected. Please select the '\(desiredName)' folder specifically to grant access.")
            return false
        }

        print("Correct folder '\(selectedURL.lastPathComponent)' selected. Saving bookmark.")
        saveBookmark(for: selectedURL, key: key) // Runs on MainActor
        // Check if saving the bookmark failed (errorAlert might be set in saveBookmark)
        return self.errorAlert == nil
    }

    // Runs on MainActor (called from MainActor methods)
    private func saveBookmark(for url: URL, key: String) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: key)
            UserDefaults.standard.synchronize() // Ensure it's saved immediately
            print("Successfully saved bookmark for \(url.path) under key '\(key)'")
        } catch {
            print("Error saving bookmark for \(url.path): \(error.localizedDescription)")
             // Set error to be checked by caller
            self.errorAlert = ErrorAlert(message: "Could not save access permissions for \(url.lastPathComponent). You might be asked again later.")
        }
    }

    // Runs on MainActor (called from init and ensureAccess)
    private func loadBookmarks() {
        print("Loading bookmarks...")
        loadBookmark(forKey: self.systemLibraryBookmarkKey)
        loadBookmark(forKey: self.userLibraryBookmarkKey)
    }

    // Runs on MainActor
    private func loadBookmark(forKey key: String) {
        guard let bookmarkData = UserDefaults.standard.data(forKey: key) else {
            print("No bookmark data found for key: \(key)")
            if key == self.systemLibraryBookmarkKey { self.systemLibraryURL = nil }
            else if key == self.userLibraryBookmarkKey { self.userLibraryURL = nil }
            return
        }

        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)

            // Ensure we have access; start/stop to potentially refresh permissions if needed
            guard url.startAccessingSecurityScopedResource() else {
                 print("Could not start accessing security scoped resource on load for \(key) (\(url.path))")
                 // Treat as resolution failure
                 throw NSError(domain: "PluginManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not start accessing bookmarked URL."])
            }
            url.stopAccessingSecurityScopedResource() // Stop immediately, access will be started again during scan

            if isStale {
                print("Bookmark data is stale for key: \(key) (\(url.path)). Attempting to refresh.")
                saveBookmark(for: url, key: key) // Refresh bookmark (runs on MainActor)
                // Check if saving failed
                if self.errorAlert != nil {
                    print("Failed to refresh stale bookmark for key \(key). Removing.")
                    UserDefaults.standard.removeObject(forKey: key) // Remove the stale one
                    if key == self.systemLibraryBookmarkKey { self.systemLibraryURL = nil }
                    else if key == self.userLibraryBookmarkKey { self.userLibraryURL = nil }
                    return // Stop processing this bookmark
                }
            }

            // Store the resolved URL
            if key == self.systemLibraryBookmarkKey {
                self.systemLibraryURL = url
                print("Successfully loaded bookmark for System Library: \(url.path)")
            } else if key == self.userLibraryBookmarkKey {
                self.userLibraryURL = url
                print("Successfully loaded bookmark for User Library: \(url.path)")
            }

        } catch {
            print("Error resolving bookmark data for key \(key): \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: key) // Remove invalid bookmark

            if key == self.systemLibraryBookmarkKey { self.systemLibraryURL = nil }
            else if key == self.userLibraryBookmarkKey { self.userLibraryURL = nil }

            let folderName = (key == self.systemLibraryBookmarkKey) ? "/Library" : "~/Library"
            // Only set alert if no other more specific alert is already showing
            if self.errorAlert == nil {
                 self.errorAlert = ErrorAlert(message: "Saved access permission for \(folderName) is no longer valid. Please use Refresh to grant access again.")
            }
        }
    }


    // MARK: - Background Scanning Logic

    // This function is designed to be called from a background thread (Task.detached).
    // It receives the necessary non-isolated data (URL, extensions).
    // It should not access PluginManager's MainActor state directly.
    // Marked static as it doesn't rely on instance state anymore (receives extensions as param).
    // Changed to static method to make non-isolation clear.
    static private func performScanInBackground(libraryURL: URL, isUserDomain: Bool, fileExtensions: Set<String>) async -> (Set<Plugin>, Error?) {
        let pluginDirectories = [
            libraryURL.appendingPathComponent("Audio/Plug-Ins/Components"),
            libraryURL.appendingPathComponent("Audio/Plug-Ins/VST3"),
            libraryURL.appendingPathComponent("Audio/Plug-Ins/VST"),
            libraryURL.appendingPathComponent("Application Support/Avid/Audio/Plug-Ins")
        ]

        var combinedPlugins: Set<Plugin> = []
        var firstError: Error? = nil

        // Use TaskGroup for concurrent directory scanning *within* this background task.
        await withTaskGroup(of: (Set<Plugin>, Error?).self) { group in
            for directory in pluginDirectories {
                group.addTask {
                    // Call the static, nonisolated getPlugins version
                    return Self.getPluginsInBackground( // Use Self here to refer to static method within static func
                        directory: directory,
                        isUserDomain: isUserDomain,
                        fileExtensions: fileExtensions // Pass extensions through
                    )
                }
            }

            // Collect results
            for await (plugins, error) in group {
                combinedPlugins.formUnion(plugins)
                if firstError == nil && error != nil {
                    firstError = error
                }
            }
        }
        return (combinedPlugins, firstError)
    }

    // Static, nonisolated function performing blocking I/O.
    // Receives necessary constant data (extensions) as parameters.
    static nonisolated private func getPluginsInBackground(directory: URL, isUserDomain: Bool, fileExtensions: Set<String>) -> (Set<Plugin>, Error?) {
         var plugins: Set<Plugin> = []
         do {
             // Check existence using fileManager directly
             guard FileManager.default.fileExists(atPath: directory.path) else {
                 // print("Directory does not exist (checked in background): \(directory.path)")
                 return ([], nil) // Not an error if standard dir doesn't exist
             }

             // Blocking call - okay here (nonisolated static func)
             let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey], options: [.skipsHiddenFiles])

             for fileURL in fileURLs {
                 // Skip if resource values can't be read or if hidden
                 guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isHiddenKey]),
                       resourceValues.isHidden == false else {
                     continue
                 }

                 let fileExtension = fileURL.pathExtension.lowercased()
                 // Use the passed-in fileExtensions set
                 if fileExtensions.contains(fileExtension) {
                     let name = fileURL.deletingPathExtension().lastPathComponent
                     if !name.starts(with: ".") {
                          let plugin = Plugin(name: name, type: fileExtension, path: fileURL.path, isUserDomain: isUserDomain) // Plugin is Sendable
                          plugins.insert(plugin)
                     }
                 }
             }
             return (plugins, nil) // Success
         } catch {
             print("Error scanning directory in background \(directory.path): \(error.localizedDescription)")
             // Return any plugins found so far along with the error
             return (plugins, error)
         }
     }

} // End of PluginManager class
