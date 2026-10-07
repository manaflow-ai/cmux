import CmuxiOSSSHCore
import CmuxiOSTerminal
import CmuxTerminalRenderCore
import UIKit

/// An SSH terminal: the A2 terminal screen fed by `SSHTerminalByteSource`
/// (`.local`), with a status banner driven by the source's state stream.
/// Returning to the foreground skips any reconnect backoff.
@MainActor
final class SSHTerminalViewController: UIViewController {
    private let source: SSHTerminalByteSource
    private let terminal: TerminalViewController
    private let banner = SSHSessionBanner()
    private let editLogin: () -> Void
    private var observation: Task<Void, Never>?
    private var foreground: Task<Void, Never>?

    init(source: SSHTerminalByteSource, title: String, editLogin: @escaping () -> Void) {
        self.source = source
        self.editLogin = editLogin
        terminal = TerminalViewController(source: source, title: title)
        super.init(nibName: nil, bundle: nil)
        self.title = title
        navigationItem.largeTitleDisplayMode = .never
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(terminal)
        terminal.view.frame = view.bounds
        terminal.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(terminal.view)
        terminal.didMove(toParent: self)
        view.backgroundColor = terminal.view.backgroundColor
        navigationItem.rightBarButtonItem = terminal.navigationItem.rightBarButtonItem

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if observation == nil {
            let source = self.source
            observation = Task { [weak self] in
                for await state in await source.states() {
                    self?.render(state)
                }
            }
        }
        if foreground == nil {
            let source = self.source
            foreground = Task {
                for await _ in NotificationCenter.default.notifications(named: UIScene.willEnterForegroundNotification) {
                    await source.retryNow()
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observation?.cancel()
        observation = nil
        foreground?.cancel()
        foreground = nil
    }

    private func render(_ state: SSHSessionState) {
        let source = self.source
        switch state {
        case .idle, .live:
            setBannerHidden(true)
            return
        case .connecting:
            banner.show(SSHText.connecting, busy: true, actionTitle: nil, action: nil)
        case .reconnecting(let attempt, _):
            banner.show(String(format: SSHText.reconnecting, Int64(attempt)), busy: true, actionTitle: SSHText.retry) {
                Task { await source.retryNow() }
            }
        case .exited:
            banner.show(SSHText.exited, busy: false, actionTitle: SSHText.reconnect) { [weak self] in self?.restart() }
        case .closed:
            banner.show(SSHText.closed, busy: false, actionTitle: SSHText.reconnect) { [weak self] in self?.restart() }
        case .failed(let failure):
            switch failure {
            case .authenticationFailed, .missingCredentials, .missingUser:
                banner.show(SSHText.failure(failure), busy: false, actionTitle: SSHText.editLogin) { [weak self] in self?.editLogin() }
            default:
                banner.show(SSHText.failure(failure), busy: false, actionTitle: SSHText.reconnect) { [weak self] in self?.restart() }
            }
        }
        setBannerHidden(false)
    }

    /// A new connection through the same session (the grid is kept).
    private func restart() {
        terminal.session.stop()
        terminal.session.start()
    }

    private func setBannerHidden(_ hidden: Bool) {
        guard banner.isHidden != hidden else { return }
        if UIAccessibility.isReduceMotionEnabled {
            banner.isHidden = hidden
            return
        }
        if !hidden {
            banner.alpha = 0
            banner.isHidden = false
        }
        UIView.animate(withDuration: 0.2, animations: { self.banner.alpha = hidden ? 0 : 1 }, completion: { _ in
            if hidden, self.banner.alpha == 0 { self.banner.isHidden = true }
        })
    }
}
