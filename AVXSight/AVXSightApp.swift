//
//  AVXSightApp.swift
//  AVXSight
//
//  Created by Richard Tillard on 1/30/24.
//

import SwiftUI
import AppKit

struct Plugin: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: String
    let path: String
}

class PluginManager: ObservableObject {
    static let shared = PluginManager()
    
    private let fileExtensions = ["component", "vst3", "vst", "aaxplugin"]
    
    @Published var fetchedPlugins: Set<Plugin> = []

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
                self?.scanLibraryFolder(selectedURL)
            } else {
                print("Access denied for \(url.path)")
            }
        }
    }

    private func scanLibraryFolder(_ libraryURL: URL) {
        let pluginDirectories = [
            libraryURL.appendingPathComponent("Audio/Plug-Ins/Components"),
            libraryURL.appendingPathComponent("Audio/Plug-Ins/VST3"),
            libraryURL.appendingPathComponent("Audio/Plug-Ins/VST"),
            libraryURL.appendingPathComponent("Application Support/Avid/Audio/Plug-Ins")
        ]
        
        for directory in pluginDirectories {
            let plugins = getPlugins(in: directory)
            DispatchQueue.main.async {
                self.fetchedPlugins.formUnion(plugins)
            }
        }
    }

    func getPlugins(in directory: URL) -> Set<Plugin> {
        var plugins: Set<Plugin> = []
        
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            for file in files {
                for ext in fileExtensions {
                    if file.hasSuffix(ext) {
                        let name = file.replacingOccurrences(of: "." + ext, with: "")
                        let path = directory.appendingPathComponent(file).path
                        plugins.insert(Plugin(name: name, type: ext, path: path))
                    }
                }
            }
        } catch {
            print("Error fetching files at path \(directory.path): \(error.localizedDescription)")
        }
        
        return plugins
    }
}

@main
struct APCheckerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
