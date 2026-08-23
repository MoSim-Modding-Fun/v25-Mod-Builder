import SwiftUI

/// Page 3 of the wizard - mirrors #page-output: the zip-name preview (moved here from
/// the Groups page) plus the GitHub Release opt-in.
struct OutputPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RufusGroupBox(title: "Output") {
                previewList
            }

            RufusGroupBox(title: "GitHub Release") {
                Toggle("Create a GitHub release after a successful build", isOn: $appState.releaseEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                if appState.releaseEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        RufusEditableField(text: $appState.releaseTag, placeholder: "Tag (e.g. v1.0.0)")
                        RufusEditableField(text: $appState.releaseTitle, placeholder: "Title (optional, defaults to the tag)")
                        RufusEditableField(text: $appState.releaseNotes, placeholder: "Notes (optional)")
                        Text("Releases to \(BuildRunner.githubReleaseRepo) via the local gh CLI.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.dim)
                    }
                }
            }
        }
    }

    /// Mirrors renderZipPreview() in renderer.js and ZipAndCleanup's archive-name
    /// logic in AddressablesModExporter.cs exactly - same computation GroupsPage used
    /// to show inline, now living on its own page.
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
