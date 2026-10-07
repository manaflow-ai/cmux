import CmuxTerminalRenderCore
import UIKit

/// One action path per terminal command (d1-terminal-ux.md section 4): the
/// hardware keyboard (listed in the iPad Command overlay), the screen's More
/// menu and the edit menu all run these. Command keys never reach the
/// terminal program; every other key does (Esc, Ctrl and Option included).
extension TerminalViewController {
    /// The Command-key shortcuts.
    func terminalKeyCommands() -> [UIKeyCommand] {
        var commands = [
            command(TerminalCommandText.copy, input: "c", action: #selector(copySelection)),
            command(TerminalCommandText.paste, input: "v", action: #selector(pasteText)),
            command(TerminalCommandText.selectAll, input: "a", action: #selector(selectAllText)),
            command(TerminalCommandText.larger, input: "=", action: #selector(zoomIn)),
            command(TerminalCommandText.larger, input: "+", action: #selector(zoomIn), discoverable: false),
            command(TerminalCommandText.smaller, input: "-", action: #selector(zoomOut)),
            command(TerminalCommandText.actualSize, input: "0", action: #selector(zoomReset)),
        ]
        if session.loadsHistory {
            commands.append(command(TerminalCommandText.olderHistory, input: UIKeyCommand.inputUpArrow,
                                    action: #selector(loadOlderHistory)))
        }
        if navigationController?.viewControllers.first !== self {
            commands.append(command(TerminalCommandText.close, input: "w", action: #selector(closeTerminal)))
        }
        return commands
    }

    private func command(_ title: String, input: String, action: Selector, discoverable: Bool = true) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: .command)
        if discoverable { command.discoverabilityTitle = title } else { command.attributes = .hidden }
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    /// The More menu: the same actions, with the history row's state.
    func moreItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeMenu())
        item.accessibilityLabel = TerminalCommandText.more
        moreButton = item
        return item
    }

    func refreshMenu() {
        moreButton?.menu = makeMenu()
    }

    private func makeMenu() -> UIMenu {
        var actions: [UIMenuElement] = [
            UIAction(title: TerminalCommandText.paste, image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.pasteText()
            },
        ]
        if session.loadsHistory {
            let history = UIAction(title: TerminalCommandText.olderHistory, image: UIImage(systemName: "clock.arrow.circlepath")) {
                [weak self] _ in self?.loadOlderHistory()
            }
            switch session.status.history {
            case .loading?:
                history.attributes = .disabled
                history.subtitle = TerminalCommandText.historyLoading
            case .unavailable?:
                history.attributes = .disabled
                history.subtitle = TerminalCommandText.historyUnavailable
            default:
                break
            }
            actions.append(history)
        }
        let size = UIMenu(title: TerminalCommandText.textSize, options: .displayInline, children: [
            UIAction(title: TerminalCommandText.larger, image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in
                self?.zoomIn()
            },
            UIAction(title: TerminalCommandText.smaller, image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in
                self?.zoomOut()
            },
            UIAction(title: TerminalCommandText.actualSize) { [weak self] _ in self?.zoomReset() },
        ])
        actions.append(size)
        return UIMenu(children: actions)
    }

    // MARK: Actions

    @objc func copySelection() { terminalView.copy(nil) }

    @objc func pasteText() { terminalView.paste(nil) }

    @objc func selectAllText() { terminalView.selectAll(nil) }

    @objc func zoomIn() { setZoom(terminalView.fontSizing.zoom(startZoom: terminalView.zoom, pinchScale: Self.zoomStep)) }

    @objc func zoomOut() { setZoom(terminalView.fontSizing.zoom(startZoom: terminalView.zoom, pinchScale: 1 / Self.zoomStep)) }

    @objc func zoomReset() { setZoom(1) }

    @objc func loadOlderHistory() { session.loadOlderHistory() }

    @objc func closeTerminal() { navigationController?.popViewController(animated: true) }

    static let zoomStep = 1.15

    /// A zoom from the keyboard or menu is a finished gesture: the new grid
    /// is reported at once (a pinch reports at its end the same way).
    private func setZoom(_ zoom: Double) {
        guard zoom != terminalView.zoom else { return }
        terminalView.zoom = zoom
        terminalView.reportViewport()
    }
}
