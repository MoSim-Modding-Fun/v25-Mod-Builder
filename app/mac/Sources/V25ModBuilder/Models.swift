import Foundation

struct ModGroup: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var checked: Bool = false
    var version: String = ""
    var zipName: String = ""
}

/// Must match PLATFORM_TARGETS in the Electron app's main.js and the Windows-side
/// ZipPlatformLabel() in AddressablesModExporter.cs - these three strings are exactly
/// what Unity's -buildTarget argument expects.
enum PlatformTarget: String, CaseIterable, Identifiable, Equatable {
    case win64, osx, linux64

    var id: String { rawValue }
    var buildTargetArg: String { rawValue }

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
