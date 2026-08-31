import Foundation

struct ModGroup: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var checked: Bool = false
    var version: String = ""
    var zipName: String = ""
}

/// Must match PLATFORM_TARGETS in the Electron app's main.js and ZipPlatformLabel() in
/// AddressablesModExporter.cs. The raw values are *our* identifiers (persisted, shown in
/// logs); they are not the vocabulary Unity's -buildTarget uses - see buildTargetArg.
enum PlatformTarget: String, CaseIterable, Identifiable, Equatable {
    case win64, osx, linux64

    var id: String { rawValue }

    /// What Unity's -buildTarget actually accepts. macOS is "OSXUniversal", not "osx":
    /// an unrecognized name leaves the Editor on its previous active build target, so the
    /// exporter rebuilds that platform's zip and the requested one never appears.
    var buildTargetArg: String {
        switch self {
        case .win64: return "win64"
        case .osx: return "OSXUniversal"
        case .linux64: return "linux64"
        }
    }

    /// Matches AddressablesModExporter.cs's ZipPlatformLabel - used in the zip filename.
    var zipLabel: String {
        switch self {
        case .win64: return "Windows"
        case .osx: return "MacOS"
        case .linux64: return "Linux"
        }
    }

    var displayName: String {
        switch self {
        case .win64: return "Windows"
        case .osx: return "macOS"
        case .linux64: return "Linux"
        }
    }
}

enum SegmentStatus: String {
    case pending, running, success, failed
}

/// Identifies a console/status tab on the Build page: either a real platform build or
/// the synthetic GitHub release step tacked on after them.
enum ConsoleTabID: Hashable {
    case platform(PlatformTarget)
    case release

    var displayName: String {
        switch self {
        case .platform(let p): return p.displayName
        case .release: return "Release"
        }
    }
}

struct ProgressSegment: Identifiable, Equatable {
    let id = UUID()
    let platform: PlatformTarget
    let group: String
    let zipName: String
    let version: String
    var status: SegmentStatus = .pending
}

struct ConsoleLine: Identifiable {
    let id = UUID()
    let time: String
    let text: String
    var kind: Kind = .normal
    enum Kind { case normal, success, failure }
}
