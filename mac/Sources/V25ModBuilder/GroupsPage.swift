import SwiftUI

/// Page 2 of the wizard - mirrors #page-groups: Groups checklist (with per-group
/// Version/Zip name fields), Platforms checkboxes, Output Folder, and a live Preview
/// of the resulting zip filenames.
struct GroupsPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RufusGroupBox(title: "Groups") {
                if appState.groups.isEmpty {
                    Text(appState.projectPath == nil ? "No project selected yet." : "No addressable groups found in this project.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dim)
                } else {
                    ForEach($appState.groups) { $group in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(group.name, isOn: $group.checked)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                            if group.checked {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Version (optional)").font(.system(size: 10)).foregroundColor(Theme.dim)
                                        TextField("none", text: $group.version)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 11))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Zip name override (optional)").font(.system(size: 10)).foregroundColor(Theme.dim)
                                        TextField(group.name, text: $group.zipName)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 11))
                                    }
                                }
                                .padding(.leading, 20)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            RufusGroupBox(title: "Platforms") {
                HStack(spacing: 16) {
                    ForEach(PlatformTarget.allCases) { platform in
                        Toggle(platform.displayName, isOn: Binding(
                            get: { appState.selectedPlatforms.contains(platform) },
                            set: { isOn in
                                if isOn { appState.selectedPlatforms.insert(platform) }
                                else { appState.selectedPlatforms.remove(platform) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    }
                }
            }

            RufusGroupBox(title: "Output Folder") {
                HStack(spacing: 4) {
                    RufusField(text: appState.outputDir ?? "", placeholder: "Default: <project>/Mods")
                    Button("...") { appState.browseOutputFolder() }
                        .buttonStyle(RufusButtonStyle())
                        .frame(width: 34)
                    if appState.outputDir != nil {
                        Button("\u{21BA}") { appState.resetOutputDir() }
                            .buttonStyle(RufusButtonStyle())
                            .frame(width: 34)
                            .help("Reset to default")
                    }
                }
            }

            RufusGroupBox(title: "Preview") {
                previewList
            }
        }
    }

    /// Mirrors renderZipPreview() in renderer.js and ZipAndCleanup's archive-name
    /// logic in AddressablesModExporter.cs exactly.
    private var previewList: some View {
        let selectedGroups = appState.groups.filter { $0.checked }
        let platforms = PlatformTarget.allCases.filter { appState.selectedPlatforms.contains($0) }

        return Group {
            if selectedGroups.isEmpty || platforms.isEmpty {
                Text("Select a group and a platform to preview output filenames.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.dim)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(selectedGroups) { group in
                        ForEach(platforms) { platform in
                            Text(fileName(for: group, platform: platform))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.dim)
                        }
                    }
                }
            }
        }
    }

    private func fileName(for group: ModGroup, platform: PlatformTarget) -> String {
        let zipName = group.zipName.trimmingCharacters(in: .whitespaces).isEmpty ? group.name : group.zipName
        let version = group.version.trimmingCharacters(in: .whitespaces)
        let label = platform.zipLabel
        return version.isEmpty ? "\(zipName) \(label).zip" : "\(zipName) \(version) \(label).zip"
    }
}
