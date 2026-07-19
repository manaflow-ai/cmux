import CmuxLiteCore
import Foundation

/// A shared server mutation invoked by clicks or keyboard actions.
enum CmuxWindowMutation {
    case workspace(UInt64)
    case screen(UInt64)
    case newWorkspace(pane: UInt64)
    case newScreen(pane: UInt64)
    case selectTab(pane: UInt64, index: Int)
    case newTab(pane: UInt64)
    case split(pane: UInt64, direction: CmuxSplitDirection)
    case closeTab(surface: UInt64)
    case setRatio(target: CmuxSplitTarget, ratio: Double, requestID: UInt64)

    var followsServerActivePane: Bool {
        switch self {
        case .workspace, .screen, .newWorkspace, .newScreen, .split:
            true
        case .selectTab, .newTab, .closeTab, .setRatio:
            false
        }
    }
}
