import CmuxiOSDesign
import CmuxiOSFeatureKit
import UIKit

extension WorkspaceStatus {
    var symbolName: String {
        switch self {
        case .idle: "circle"
        case .running: "play.circle.fill"
        case .waitingForInput: "exclamationmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var tint: UIColor {
        switch self {
        case .idle: ShellPalette.statusIdle
        case .running: ShellPalette.statusRunning
        case .waitingForInput: ShellPalette.statusWaiting
        case .failed: ShellPalette.statusFailed
        }
    }

    var label: String {
        switch self {
        case .idle: WorkspacesText.statusIdle
        case .running: WorkspacesText.statusRunning
        case .waitingForInput: WorkspacesText.statusWaiting
        case .failed: WorkspacesText.statusFailed
        }
    }
}
