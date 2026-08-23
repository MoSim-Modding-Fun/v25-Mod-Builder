import SwiftUI

/// Page 2 of the wizard - mirrors #page-groups: Groups checklist (with per-group
/// Version/Zip name fields), Platforms checkboxes, and Output Folder. The zip-name
/// preview and GitHub release opt-in live on the following Output page.
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
                                        RufusEditableField(text: $group.version, placeholder: "none")
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Zip name override (optional)").font(.system(size: 10)).foregroundColor(Theme.dim)
                                        RufusEditableField(text: $group.zipName, placeholder: group.name)
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

        }
    }
}
