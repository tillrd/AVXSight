// AVXSight.swift

import SwiftUI
import AppKit

@main
struct AVXSightApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(DefaultWindowStyle()) // Use the default window style
        .commands {
            CommandGroup(replacing: CommandGroupPlacement.newItem, addition: {})
        }
    }
}

// Plugin model with identifiable and hashable conformance for unique identification
struct Plugin: Identifiable, Hashable {
    let id: UUID
    let name: String
    let type: String
    let path: String
    
    init(name: String, type: String, path: String) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.path = path
    }
}

// PluginManager class for handling plugin-related operations
class PluginManager: ObservableObject {
    static let shared = PluginManager()
    private let fileExtensions: Set<String> = ["component", "vst3", "vst", "aaxplugin"]
    
    @Published var fetchedPlugins: Set<Plugin> = []
    @Published var errorMessage: String? // For user-friendly error messages
    
    // Request access to the Library folder with user's consent
    func requestLibraryFolderAccess() {
        let url = URL(fileURLWithPath: "/Library")
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = url
        openPanel.message = "Please grant access to the Library directory"
        openPanel.prompt = "Grant Access"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.begin { [weak self] response in
            if response == .OK, let selectedURL = openPanel.url {
                Task {
                    await self?.scanLibraryFolder(selectedURL)
                }
            } else {
                self?.errorMessage = "Access denied for \(url.path)"
            }
        }
    }
    
    // Scan the Library folder for plugins asynchronously
    private func scanLibraryFolder(_ libraryURL: URL) async {
        let pluginDirectories = [
            libraryURL.appendingPathComponent("Audio/Plug-Ins/Components"),
            libraryURL.appendingPathComponent("Audio/Plug-Ins/VST3"),
            libraryURL.appendingPathComponent("Audio/Plug-Ins/VST"),
            libraryURL.appendingPathComponent("Application Support/Avid/Audio/Plug-Ins")
        ]
        
        await withTaskGroup(of: Set<Plugin>.self) { group in
            for directory in pluginDirectories {
                group.addTask {
                    return await self.getPlugins(in: directory)
                }
            }
            
            var allPlugins: Set<Plugin> = []
            for await plugins in group {
                allPlugins.formUnion(plugins)
            }
            
            DispatchQueue.main.async {
                self.fetchedPlugins.formUnion(allPlugins)
            }
        }
    }
    
    // Retrieve plugins from a specified directory asynchronously
    func getPlugins(in directory: URL) async -> Set<Plugin> {
        var plugins: Set<Plugin> = []
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                let fileExtension = fileURL.pathExtension
                if fileExtensions.contains(fileExtension) {
                    let name = fileURL.deletingPathExtension().lastPathComponent
                    let plugin = Plugin(name: name, type: fileExtension, path: fileURL.path)
                    plugins.insert(plugin)
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Error fetching files at path \(directory.path): \(error.localizedDescription)"
            }
        }
        
        return plugins
    }
}
