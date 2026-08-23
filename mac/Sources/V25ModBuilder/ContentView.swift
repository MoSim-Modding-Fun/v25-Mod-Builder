import SwiftUI
import AppKit

/// The wizard shell - mirrors renderer.js's showPage()/updateNav() logic: 4 pages
/// (Project, Groups, Output, Build), step dots, and a bottom bar whose
/// BACK/NEXT/START/CLOSE buttons swap per page.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var runner = BuildRunner()
    @State private var page = 0
    @State private var activeConsoleTab: ConsoleTabID = .platform(.win64)

    var body: some View {
        VStack(spacing: 6) {
            stepDots

            Group {
                switch page {
                case 0: ProjectPage()
                case 1: GroupsPage()
                case 2: OutputPage()
                default: BuildPage(runner: runner, activeTab: $activeConsoleTab)
                }
            }

            bottomBar
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(Theme.background)
        .frame(minWidth: 420, minHeight: 260)
        .onAppear {
            resizeForCurrentPage()
            Task { await appState.restoreLastProject() }
        }
        .onChange(of: page) { _ in resizeForCurrentPage() }
        .onChange(of: appState.groups) { _ in if page == 1 || page == 2 { resizeForCurrentPage() } }
        .onChange(of: appState.selectedPlatforms) { _ in if page != 0 { resizeForCurrentPage() } }
        .onChange(of: appState.releaseEnabled) { _ in if page == 2 { resizeForCurrentPage() } }
        .onChange(of: runner.currentPlatform) { newValue in
            if let newValue { activeConsoleTab = .platform(newValue) }
        }
    }

    /// Estimates the active page's natural height from its known content (group count,
    /// expanded rows, selected platforms) and fits the window to it - mirrors what
    /// main.js's `resize-window-height` achieves by measuring the live DOM, since this
    /// SwiftUI/macOS beta toolchain doesn't reliably re-report GeometryReader-based
    /// ideal-size changes on page navigation (verified empirically: only fires once,
    /// before layout settles).
    private func resizeForCurrentPage() {
        let height: CGFloat
        switch page {
        case 0:
            height = 312
        case 1:
            let baseline: CGFloat = 272
            let perGroup: CGFloat = 24
            let perExpandedExtra: CGFloat = 66
            height = baseline + appState.groups.reduce(0) { $0 + perGroup + ($1.checked ? perExpandedExtra : 0) }
        case 2:
            let baseline: CGFloat = 210
            let perOutputLine: CGFloat = 14
            let selectedGroups = appState.groups.filter { $0.checked }.count
            let selectedPlatforms = appState.selectedPlatforms.count
            let releaseExtra: CGFloat = appState.releaseEnabled ? 130 : 0
            height = baseline + CGFloat(selectedGroups * selectedPlatforms) * perOutputLine + releaseExtra
        default:
            height = 442
        }
        WindowSizer.resizeHeight(to: height)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
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
                Button("NEXT") { page = 2 }
                    .buttonStyle(StartButtonStyle(enabled: appState.canBuild))
                    .disabled(!appState.canBuild)
            } else if page == 2 {
                Button("START") { startBuild() }
                    .buttonStyle(StartButtonStyle(enabled: appState.canStartBuild))
                    .disabled(!appState.canStartBuild)
            }

            Button("CLOSE") { NSApplication.shared.terminate(nil) }
                .buttonStyle(RufusButtonStyle())
        }
    }

    /// Mirrors main.js's `resize-window-height` handler: fits the window's height to
    /// whatever the active page actually needs (so nothing ever needs to scroll),
    /// keeping the current width and clamping to [260, current screen's work area - 40].
    private enum WindowSizer {
        static func resizeHeight(to height: CGFloat) {
            guard height > 1,
                  let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil })
            else { return }
            let currentWidth = window.contentView?.frame.width ?? window.frame.width
            let workAreaHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
            let maxHeight = max(260, workAreaHeight - 40)
            let clamped = max(260, min(maxHeight, height.rounded()))
            if abs(clamped - (window.contentView?.frame.height ?? 0)) > 0.5 {
                window.setContentSize(NSSize(width: currentWidth, height: clamped))
            }
        }
    }

    private func startBuild() {
        guard let projectPath = appState.projectPath, let unityPath = appState.unityPath else { return }
        let platforms = PlatformTarget.allCases.filter { appState.selectedPlatforms.contains($0) }
        activeConsoleTab = .platform(platforms.first ?? .win64)
        page = 3
        Task {
            await runner.run(
                projectPath: projectPath,
                unityPath: unityPath,
                groups: appState.groups,
                platforms: platforms,
                outputDir: appState.outputDir
            )
            if appState.releaseEnabled {
                if runner.allRequestedPlatformsSucceeded {
                    activeConsoleTab = .release
                    await runner.createGitHubRelease(
                        tag: appState.releaseTag,
                        title: appState.releaseTitle,
                        notes: appState.releaseNotes
                    )
                } else {
                    runner.releaseStatus = .failed
                }
            }
        }
    }
}
