import CmuxiOSFeatureKit
import Foundation

/// SF Symbols per kind and resolution.
enum FeedGlyph {
    static func symbol(_ kind: FeedItemKind) -> String {
        switch kind {
        case .permission: "lock.shield"
        case .question: "questionmark.bubble"
        case .choice: "list.bullet.circle"
        case .planApproval: "list.bullet.clipboard"
        case .confirm: "exclamationmark.bubble"
        case .done: "checkmark.circle"
        case .unsupported: "desktopcomputer"
        }
    }

    static func resolutionSymbol(_ item: FeedItem) -> String {
        switch item.state {
        case .open: "circle"
        case .answered: "checkmark"
        case .cancelled: "xmark"
        case .expired: "clock"
        }
    }
}
