import CmuxiOSFeatureKit

extension WorkspaceSurfaceKind {
    var symbolName: String {
        switch self {
        case .terminal: "terminal"
        case .browser: "globe"
        case .agent: "sparkles"
        case .other: "square.on.square"
        }
    }

    var label: String {
        switch self {
        case .terminal: WorkspacesText.kindTerminal
        case .browser: WorkspacesText.kindBrowser
        case .agent: WorkspacesText.kindAgent
        case .other: WorkspacesText.kindOther
        }
    }
}
