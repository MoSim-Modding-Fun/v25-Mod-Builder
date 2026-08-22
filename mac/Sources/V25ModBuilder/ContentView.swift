import SwiftUI
import AppKit

/// The wizard shell - mirrors renderer.js's showPage()/updateNav() logic: 3 pages,
/// step dots, and a bottom bar whose BACK/NEXT/START/CLOSE buttons swap per page.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var runner = BuildRunner()
    @State private var page = 0
    @State private var activeConsoleTab: PlatformTarget = .win64

    var body: some View {
        VStack(spacing: 6) {
            stepDots

            Group {
                switch page {
                case 0: ProjectPage()
                case 1: GroupsPage()
                default: BuildPage(runner: runner, activeTab: $activeConsoleTab)
                }
            }

            bottomBar
        }
        .padding(8)
        .background(Theme.background)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 620)
        .onAppear { appState.restoreLastProject() }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i == page ? Theme.accentBlue : Theme.dotInactive)
                    .overlay(Circle().stroke(i == page ? Theme.linkBlue : Theme.dotInactiveBorder, lineWidth: 1))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.top, 1)
        .padding(.bottom, 3)
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Button("BACK") { page -= 1 }
                .buttonStyle(RufusButtonStyle())
                .disabled(page == 0)

            Spacer()

            if page == 0 {
                let ready = appState.projectPath != nil && appState.unityPath != nil
                Button("NEXT") { page = 1 }
                    .buttonStyle(StartButtonStyle(enabled: ready))
                    .disabled(!ready)
            } else if page == 1 {
                Button("START") { startBuild() }
                    .buttonStyle(StartButtonStyle(enabled: appState.canBuild))
                    .disabled(!appState.canBuild)
            }

            Button("CLOSE") { NSApplication.shared.terminate(nil) }
                .buttonStyle(RufusButtonStyle())
        }
    }

    private func startBuild() {
        guard let projectPath = appState.projectPath, let unityPath = appState.unityPath else { return }
        let platforms = PlatformTarget.allCases.filter { appState.selectedPlatforms.contains($0) }
        activeConsoleTab = platforms.first ?? .win64
        page = 2
        Task {
            await runner.run(
                projectPath: projectPath,
                unityPath: unityPath,
                groups: appState.groups,
                platforms: platforms,
                outputDir: appState.outputDir
            )
        }
    }
}
