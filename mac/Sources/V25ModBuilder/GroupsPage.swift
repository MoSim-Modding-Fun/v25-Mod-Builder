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
                            HStack(spacing: 0) {
                                Toggle(group.name, isOn: $group.checked)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 12))
                                if appState.unregisteredModFolders.contains(group.name) {
                                    NewBadge()
                                }
                            }
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

                // DETECT NEW MODS: a pure filesystem read (see ProjectService.
                // detectUnregisteredModFolders) - it never launches Unity and never
                // creates a group itself. A folder only becomes a real group if the user
                // checks it above and builds it (EnsureModGroupRegistered on the Unity
                // side does the actual creation at build time). Mirrors renderer.js's
                // detect-row/detect-mods-btn/detect-status.
                HStack(spacing: 8) {
                    Button("DETECT NEW MODS") { appState.detectNewMods() }
                        .buttonStyle(RufusButtonStyle())
                        .disabled(appState.projectPath == nil)
                    Text(appState.detectStatus)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.dim)
                }
                .padding(.top, 6)
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

/// Marks a mod folder DETECT found that has no addressable group yet - one only gets
/// created if the user actually builds it. Mirrors the Electron app's `.new-badge`
/// (small blue pill, uppercase white text) in styles.css.
private struct NewBadge: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.accentBlue)
            .cornerRadius(2)
            .padding(.leading, 6)
            .help("Not an addressable group yet - one gets created if you build it.")
    }
}
