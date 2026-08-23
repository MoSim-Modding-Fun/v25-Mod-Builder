import SwiftUI

/// Page 1 of the wizard - mirrors index.html's #page-project exactly: Project
/// groupbox (path field + SELECT) and Unity Editor groupbox (path field + "...").
struct ProjectPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RufusGroupBox(title: "Project") {
                HStack(spacing: 4) {
                    RufusField(text: appState.projectPath ?? "", placeholder: "No project selected")
                    Button("SELECT") { Task { await appState.selectProject() } }
                        .buttonStyle(RufusButtonStyle())
                }
                if let error = appState.projectError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.error)
                } else if let version = appState.unityVersion {
                    Text("Editor version required: \(version) \u{00B7} \(appState.groups.count) group(s) found")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.dim)
                }
            }

            RufusGroupBox(title: "Unity Editor") {
                HStack(spacing: 4) {
                    RufusField(text: appState.unityPath ?? "", placeholder: "No project selected")
                    Button("...") { appState.browseUnityPath() }
                        .buttonStyle(RufusButtonStyle())
                        .frame(width: 34)
                }
                if appState.unityPath != nil {
                    Text("Ready (\(appState.isUnityPathDetected ? "auto-detected" : "manually set"))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.ok)
                } else if appState.projectPath != nil {
                    Text("Not found for this project's version \u{2014} browse for it.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.error)
                }
            }
        }
    }
}
