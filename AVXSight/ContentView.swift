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
                    } else if !pluginManager.isLoading && sortedPlugins.isEmpty && pluginManager.errorAlert == nil {
                         Text("No plugins found.\nTry the Refresh button.")
                             .foregroundColor(.secondary)
                             .multilineTextAlignment(.center)
                             .frame(maxWidth: .infinity, alignment: .center)
                             .padding()
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
             // Access manager state (MainActor)
             if pluginManager.systemLibraryURL == nil && pluginManager.userLibraryURL == nil && pluginManager.fetchedPlugins.isEmpty {
                  print("onAppear: No bookmarks found and no plugins loaded, triggering initial scan.")
                 // Create Task to call async func
                 Task {
                     await pluginManager.scanForPlugins() // Call MainActor function
                 }
             } else if !pluginManager.fetchedPlugins.isEmpty {
                  print("onAppear: Plugins already loaded (\(pluginManager.fetchedPlugins.count)). Skipping automatic scan.")
             } else {
                  print("onAppear: Bookmarks exist but no plugins loaded. User action required (Refresh).")
             }
        }
        // Use the manager's errorAlert (MainActor state)
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
                 PluginTypeBadge(type: plugin.type) // Use badge view

                 Image(systemName: plugin.isUserDomain ? "person.circle" : "desktopcomputer")
                      .foregroundColor(.secondary)
                      .imageScale(.small)
                      .help(plugin.isUserDomain ? "User Library (~/Library)" : "System Library (/Library)")
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
                 HStack(alignment: .top) { // Align top for potentially wrapping title
                     Text(plugin.name)
                         .font(.title)
                         .lineLimit(3) // Allow name to wrap slightly more
                     Spacer()
                     PluginTypeBadge(type: plugin.type) // Use badge view
                         .padding(.top, 4) // Adjust badge position slightly
                 }
                 .padding(.bottom, 10)

                 DetailRow(label: "Type", value: pluginTypeDescription(plugin.type))
                 DetailRow(label: "Location", value: plugin.isUserDomain ? "User Library (~/Library)" : "System Library (/Library)")
                 DetailRow(label: "Path", value: plugin.path)
                    .environment(\.layoutDirection, .leftToRight)

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
             }
             .padding()
             .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // NavigationSplitView handles the detail title implicitly based on selection
    }

    // Action method (runs on MainActor as it's part of a View)
    func showInFinder(plugin: Plugin) {
        let fileURL = URL(fileURLWithPath: plugin.path)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL]) // AppKit call, safe on MainActor
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
