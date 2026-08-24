import SwiftUI

/// Page 3 of the wizard - mirrors #page-build: platform status pills, the segmented
/// progress bar with percentage, and the per-platform console tabs.
struct BuildPage: View {
    @ObservedObject var runner: BuildRunner
    @Binding var activeTab: ConsoleTabID
    @EnvironmentObject var appState: AppState

    private var activePlatforms: [PlatformTarget] {
        PlatformTarget.allCases.filter { appState.selectedPlatforms.contains($0) }
    }

    private var activeTabs: [ConsoleTabID] {
        var tabs = activePlatforms.map { ConsoleTabID.platform($0) }
        if appState.releaseEnabled { tabs.append(.release) }
        return tabs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RufusGroupBox(title: "Build Progress") {
                statusRow
                progressBar
            }

            RufusGroupBox(title: "Console") {
                HStack(spacing: 2) {
                    ForEach(activeTabs, id: \.self) { tab in
                        Button(tab.displayName) { activeTab = tab }
                            .buttonStyle(ConsoleTabButtonStyle(active: activeTab == tab))
                    }
                }
                ConsoleView(lines: consoleLines(for: activeTab))
            }
        }
    }

    private func consoleLines(for tab: ConsoleTabID) -> [ConsoleLine] {
        switch tab {
        case .platform(let p): return runner.consoleLines[p] ?? []
        case .release: return runner.releaseConsoleLines
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            ForEach(activePlatforms) { platform in
                HStack(spacing: 4) {
                    Text(platform.displayName).font(.system(size: 11))
                    Text((runner.platformStatus[platform] ?? .pending).rawValue.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(badgeColor(runner.platformStatus[platform] ?? .pending))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white)
                .overlay(Rectangle().stroke(Theme.badgeBorder, lineWidth: 1))
            }
            if appState.releaseEnabled {
                HStack(spacing: 4) {
                    Text("Release").font(.system(size: 11))
                    Text(runner.releaseStatus.rawValue.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(badgeColor(runner.releaseStatus))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white)
                .overlay(Rectangle().stroke(Theme.badgeBorder, lineWidth: 1))
            }
        }
    }

    private var progressBar: some View {
        let total = runner.progressSegments.count
        let done = runner.progressSegments.filter { $0.status == .success || $0.status == .failed }.count
        let pct = total > 0 ? Int((Double(done) / Double(total) * 100).rounded()) : 0

        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(runner.progressSegments) { seg in
                    Rectangle()
                        .fill(segmentColor(seg.status))
                        .frame(height: 10)
                        .help("\(seg.group) \u{2014} \(seg.platform.displayName)")
                }
            }
            .overlay(Rectangle().stroke(Theme.dotInactiveBorder, lineWidth: 1))
            Text("\(pct)%")
                .font(.system(size: 11))
                .foregroundColor(Theme.dim)
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    private func badgeColor(_ status: SegmentStatus) -> Color {
        switch status {
        case .pending: return Theme.dim
        case .running: return Theme.linkBlue
        case .success: return Theme.ok
        case .failed: return Theme.error
        }
    }

    private func segmentColor(_ status: SegmentStatus) -> Color {
        switch status {
        case .pending: return Theme.dotInactive
        case .running: return Theme.accentBlue
        case .success: return Theme.startGreen
        case .failed: return Theme.error
        }
    }
}

/// The dark live console - matches the Electron app's .console: monospace, per-line
/// timestamp, always-follows-the-tail while streaming.
///
/// Known simplification vs. the Electron app: this always auto-scrolls to the bottom
/// on new output, rather than pinning only while already at the bottom and offering a
/// "jump to bottom" button once scrolled away. Precise scroll-offset tracking needs
/// either macOS 14's `.scrollPosition` API or a custom NSScrollView wrapper, and this
/// couldn't be verified by actually running it - simpler and more likely to compile
/// correctly wins here. Worth revisiting once this builds successfully.
struct ConsoleView: View {
    let lines: [ConsoleLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.time).foregroundColor(Theme.consoleTime)
                            Text(line.text).foregroundColor(color(for: line.kind))
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.consoleBg)
            .frame(height: 220)
            .onChange(of: lines.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func color(for kind: ConsoleLine.Kind) -> Color {
        switch kind {
        case .normal: return Theme.consoleText
        case .success: return Theme.consoleSuccess
        case .failure: return Theme.consoleFailure
        }
    }
}
