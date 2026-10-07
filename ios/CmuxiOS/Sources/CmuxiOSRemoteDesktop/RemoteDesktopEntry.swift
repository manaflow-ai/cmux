public import CmuxiOSFeatureKit
public import CmuxiOSRemoteDesktopCore
import CmuxRemoteDesktop
public import UIKit

/// Opens remote desktop from anywhere a paired Mac shows (Hosts, the
/// workspace detail): a sheet with Show Screen and Connect to VNC Server,
/// then the screen full screen. The composition root makes one per shell.
@MainActor
public final class RemoteDesktopEntry {
    private let connector: any RemoteDesktopConnector

    public init(connector: any RemoteDesktopConnector) {
        self.connector = connector
    }

    /// The localized action title for menus that offer this entry.
    public static var actionTitle: String { RemoteDesktopText.entryTitle }

    /// Asks what to show on `host`, then opens it.
    public func present(host: HostID, hostName: String, from presenter: UIViewController, sourceView: UIView? = nil) {
        let sheet = UIAlertController(title: RemoteDesktopText.entryTitle, message: RemoteDesktopText.entryMessage,
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: RemoteDesktopText.entryScreen, style: .default) { [weak self, weak presenter] _ in
            guard let presenter else { return }
            self?.open(host: host, hostName: hostName, target: .display(nil), title: hostName, from: presenter)
        })
        sheet.addAction(UIAlertAction(title: RemoteDesktopText.entryVnc, style: .default) { [weak self, weak presenter] _ in
            guard let presenter else { return }
            self?.askVncServer(host: host, hostName: hostName, from: presenter)
        })
        sheet.addAction(UIAlertAction(title: RemoteDesktopText.cancel, style: .cancel))
        if let popover = sheet.popoverPresentationController {
            let anchor = sourceView ?? presenter.view!
            popover.sourceView = anchor
            popover.sourceRect = CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
        }
        presenter.present(sheet, animated: true)
    }

    /// Opens a target directly (deep links, tests).
    public func open(host: HostID, hostName: String, target: DesktopTarget, title: String, from presenter: UIViewController) {
        let size = presenter.view.window?.bounds.size ?? presenter.view.bounds.size
        let scale = presenter.traitCollection.displayScale
        let screen = DesktopScreen(pixelWidth: max(16, Int(size.width * scale)), pixelHeight: max(16, Int(size.height * scale)),
                                   scale: min(max(scale, 1), 4))
        let params = RemoteDesktopChannelParams(target: target, mode: .control, screen: screen)
        guard let client = connector.makeClient(host: host, params: params) else {
            let alert = UIAlertController(title: RemoteDesktopText.entryTitle, message: RemoteDesktopFailure.unreachable.message,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: RemoteDesktopText.close, style: .cancel))
            presenter.present(alert, animated: true)
            return
        }
        let screenController = RemoteDesktopViewController(client: client, hostName: hostName, title: title)
        let navigation = UINavigationController(rootViewController: screenController)
        navigation.modalPresentationStyle = .fullScreen
        navigation.navigationBar.barStyle = .black
        navigation.toolbar.barStyle = .black
        presenter.present(navigation, animated: true)
    }

    private func askVncServer(host: HostID, hostName: String, from presenter: UIViewController, invalid: Bool = false) {
        let alert = UIAlertController(title: RemoteDesktopText.vncTitle,
                                      message: invalid ? RemoteDesktopText.vncInvalid : RemoteDesktopText.vncMessage,
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = RemoteDesktopText.vncHost
            field.keyboardType = .URL
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addTextField { field in
            field.placeholder = RemoteDesktopText.vncPort
            field.text = String(VncAddress.defaultPort)
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: RemoteDesktopText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: RemoteDesktopText.vncConnect, style: .default) { [weak self, weak alert, weak presenter] _ in
            guard let self, let presenter, let fields = alert?.textFields, fields.count == 2 else { return }
            let port = Int(fields[1].text ?? "") ?? -1
            guard let address = try? VncAddress(host: fields[0].text ?? "", port: port) else {
                askVncServer(host: host, hostName: hostName, from: presenter, invalid: true)
                return
            }
            open(host: host, hostName: hostName, target: .vnc(address), title: address.host, from: presenter)
        })
        presenter.present(alert, animated: true)
    }
}
