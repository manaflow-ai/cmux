public import UIKit

/// Makes the optional composer bar a terminal screen hosts above the key
/// bar (e4-compose.md 3). The screen owns the bar's placement and
/// visibility; the bar sends through `TerminalViewController.sendComposed`.
@MainActor
public protocol TerminalComposerProviding: AnyObject {
    func makeComposer(for screen: TerminalViewController) -> UIViewController
}
