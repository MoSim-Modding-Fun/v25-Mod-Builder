import SwiftUI
import AppKit

/// Electron never restores previous-session window state on launch, so neither should
/// this app - without this, macOS's window-state restoration reconstructs the SwiftUI
/// view hierarchy's @State (which wizard page was active, etc.) across relaunches.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
}

@main
struct V25ModBuilderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 480, height: 300)
    }
}
