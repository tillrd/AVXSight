// ContentView.swift

import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var pluginManager = PluginManager.shared
    @State private var searchText: String = ""

    private var filteredPlugins: [Plugin] {
        pluginManager.fetchedPlugins.filter { searchText.isEmpty || $0.name.lowercased().contains(searchText.lowercased()) }
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                        .padding(.leading, 10)

                    TextField("Search Plug-Ins Here", text: $searchText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .padding(EdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 7))
                        .frame(height: 36)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.windowBackgroundColor))
                )
                .padding(.horizontal, 16)  // Increased horizontal padding
                .padding(.top, 10)         // Optional top padding


                List(filteredPlugins.sorted(by: { $0.name < $1.name })) { plugin in
                    NavigationLink(destination: PluginDetailView(plugin: plugin)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name).fontWeight(.bold)
                            Text(plugin.type).font(.subheadline).foregroundColor(.gray)
                        }
                    }
                }
            }
            .navigationTitle("Plugins")
        }
        .onAppear {
            pluginManager.requestLibraryFolderAccess()
        }
    }
}

struct PluginDetailView: View {
    let plugin: Plugin
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plugin Details").font(.title2).bold()

            Group {
                DetailRow(label: "Name:", value: plugin.name)
                DetailRow(label: "Type:", value: plugin.type)
                DetailRow(label: "Path:", value: plugin.path)
            }

            Spacer()

            Button(action: {
                showInFinder(plugin: plugin)
            }) {
                HStack {
                    Image(systemName: "folder")
                        .font(.title3)
                        .foregroundColor(.white)
                    Text("Show in Finder")
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(LinearGradient(gradient: Gradient(colors: [Color.blue, Color.purple]), startPoint: .leading, endPoint: .trailing))
                .cornerRadius(8)
                .shadow(radius: 5)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .navigationTitle(Text(plugin.name))
    }

    func showInFinder(plugin: Plugin) {
        let fileURL = URL(fileURLWithPath: plugin.path)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

struct DetailRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
