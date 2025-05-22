// ContentView.swift

import SwiftUI
import AppKit // Needed for NSWorkspace

struct ContentView: View {
    // Use StateObject for the singleton PluginManager instance
    // This ensures the view observes changes published by the manager
    @StateObject private var pluginManager = PluginManager.shared
    @State private var searchText: String = ""
    @State private var selectedPluginId: Plugin.ID?

    // Computed property derived from the manager's state
    // This runs on the MainActor because it accesses pluginManager (MainActor)
    private var sortedPlugins: [Plugin] {
        pluginManager.fetchedPlugins // Access @MainActor property
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Body also runs on the MainActor
    var body: some View {
        NavigationSplitView {
            // Sidebar List
            VStack(spacing: 0) {
                List(selection: $selectedPluginId) {
                    // Use the computed sortedPlugins which is derived from MainActor state
                    if pluginManager.isLoading && sortedPlugins.isEmpty {
                         ProgressView("Scanning for plugins...")
                             .frame(maxWidth: .infinity, alignment: .center)
                             .padding()
                    } else if !pluginManager.isLoading && sortedPlugins.isEmpty {
                        if pluginManager.systemLibraryURL == nil && pluginManager.userLibraryURL == nil {
                            Text("No access to plugin folders.\nPlease grant access via the Refresh button or check System Settings > Privacy & Security > Files and Folders.")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else {
                            Text("No plugins found in accessible locations.\nTry the Refresh button or check your plugin folders.")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        }
                    } else {
                        // Iterate over the MainActor-safe computed property
                        ForEach(sortedPlugins) { plugin in
                            NavigationLink(value: plugin.id) {
                                PluginListItemView(plugin: plugin) // Use dedicated list item view
                            }
                            .tag(plugin.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $searchText, prompt: "Search Plugins")

                // Status Bar
                StatusBarView(
                    pluginCount: pluginManager.fetchedPlugins.count, // Access MainActor state
                    isLoading: pluginManager.isLoading // Access MainActor state
                )
            }
            .navigationTitle("Audio Plugins")
            .toolbar {
                 ToolbarItem(placement: .automatic) {
                    Button {
                        // Create an asynchronous Task to call the async func
                        Task {
                            await pluginManager.scanForPlugins() // Call MainActor function
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Scan for plugins again")
                    .disabled(pluginManager.isLoading) // Access MainActor state
                 }
            }

        } detail: {
            // Detail View Pane
            if let pluginId = selectedPluginId,
               // Access fetchedPlugins (MainActor state) to find the selected plugin
               let plugin = pluginManager.fetchedPlugins.first(where: { $0.id == pluginId }) {
                PluginDetailView(plugin: plugin)
            } else {
                 DetailPlaceholderView() // Use dedicated placeholder view
            }
        }
        .onAppear {
             // Remove all automatic scanning and error prompts on launch
        }
        // Only show error alerts if triggered by manual scan
        .alert(item: $pluginManager.errorAlert) { alertItem in
            Alert(title: Text("Error"), message: Text(alertItem.message), dismissButton: .default(Text("OK")))
        }
    }
}

// MARK: - Helper Views (Keep UI logic separate)

struct PluginListItemView: View {
    let plugin: Plugin

    var body: some View {
         VStack(alignment: .leading, spacing: 3) {
             Text(plugin.name).fontWeight(.medium)
                 .lineLimit(1)
                 .truncationMode(.tail)

             HStack(spacing: 4) {
                 PluginTypeBadge(type: plugin.type)
                 // Only system Library
                 Image(systemName: "desktopcomputer")
                      .foregroundColor(.secondary)
                      .imageScale(.small)
                      .help("System Library (/Library)")
             }
         }
         .padding(.vertical, 3)
    }
}

struct PluginTypeBadge: View {
    let type: String

    var body: some View {
        Text(type.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(pluginTypeColor(type).opacity(0.9), in: Capsule())
    }
}

struct StatusBarView: View {
    let pluginCount: Int
    let isLoading: Bool

    var body: some View {
         HStack {
             Text("\(pluginCount) plugins")
                 .font(.caption)
                 .foregroundColor(.secondary)
             Spacer()
             if isLoading {
                 ProgressView().scaleEffect(0.5).padding(.trailing, 5)
             }
         }
         .padding(.horizontal)
         .padding(.vertical, 5)
         .background(.bar)
    }
}

struct DetailPlaceholderView: View {
    var body: some View {
        VStack {
             Image(systemName: "music.note.list")
                 .font(.system(size: 50))
                 .foregroundColor(.secondary)
                 .padding(.bottom)
             Text("Select a plugin from the list")
                 .font(.title2)
                 .foregroundColor(.secondary)
              Text("Details will be shown here.")
                  .foregroundColor(.secondary)
         }
         .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail View

struct PluginDetailView: View {
    let plugin: Plugin

    var body: some View {
        ScrollView {
             VStack(alignment: .leading, spacing: 15) {
                 HStack(alignment: .top) {
                     Text(plugin.name)
                         .font(.title)
                         .lineLimit(3)
                     Spacer()
                     PluginTypeBadge(type: plugin.type)
                         .padding(.top, 4)
                 }
                 .padding(.bottom, 10)

                 DetailRow(label: "Type", value: pluginTypeDescription(plugin.type))
                 DetailRow(label: "Location", value: "System Library (/Library)")
                 DetailRow(label: "Path", value: plugin.path)
                    .environment(\.layoutDirection, .leftToRight)
                 if let version = plugin.version {
                     DetailRow(label: "Version", value: version)
                 }
                 if let manufacturer = plugin.manufacturer {
                     DetailRow(label: "Manufacturer", value: manufacturer)
                 }
                 if let desc = plugin.pluginDescription {
                     DetailRow(label: "Description", value: desc)
                 }
                 Spacer(minLength: 20)
                 Button {
                     showInFinder(plugin: plugin)
                 } label: {
                     Label("Show in Finder", systemImage: "folder")
                         .frame(maxWidth: .infinity)
                 }
                 .buttonStyle(.borderedProminent)
                 .controlSize(.large)
                 .padding(.vertical)
                 HStack {
                     Button {
                         copyPathToClipboard(plugin: plugin)
                     } label: {
                         Label("Copy Path", systemImage: "doc.on.doc")
                     }
                     Button {
                         revealInTerminal(plugin: plugin)
                     } label: {
                         Label("Reveal in Terminal", systemImage: "terminal")
                     }
                 }
             }
             .padding()
             .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    func showInFinder(plugin: Plugin) {
        let fileURL = URL(fileURLWithPath: plugin.path)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
    func copyPathToClipboard(plugin: Plugin) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plugin.path, forType: .string)
    }
    func revealInTerminal(plugin: Plugin) {
        let folderURL = URL(fileURLWithPath: plugin.path).deletingLastPathComponent()
        // Try to open Terminal at the folder using NSWorkspace
        let configuration = NSWorkspace.OpenConfiguration()
        let terminalAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([folderURL], withApplicationAt: terminalAppURL, configuration: configuration) { app, error in
            if let error = error {
                print("Failed to open Terminal: \(error.localizedDescription). Trying AppleScript fallback.")
                // Fallback to AppleScript if direct open fails
                let script = "tell application \"Terminal\"\nactivate\ndo script \"cd \" & quoted form of \"\(folderURL.path)\"\nend tell"
                if let appleScript = NSAppleScript(source: script) {
                    var error: NSDictionary?
                    appleScript.executeAndReturnError(&error)
                }
            }
        }
    }
}

// MARK: - Detail Row Helper View

struct DetailRow: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(value)
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


// MARK: - Global Helper Functions (for UI)

// Moved outside of specific views for reusability
func pluginTypeColor(_ type: String) -> Color {
     switch type.lowercased() {
     case "component": return .blue
     case "vst3": return .purple
     case "vst": return .orange
     case "aaxplugin": return .green
     default: return .gray
     }
}

func pluginTypeDescription(_ type: String) -> String {
     switch type.lowercased() {
     case "component": return "Audio Unit (AU)"
     case "vst3": return "VST3"
     case "vst": return "VST (Legacy)"
     case "aaxplugin": return "AAX (Pro Tools)"
     default: return type.uppercased()
     }
 }
