import AppKit
import CmuxLiteCore

@main
@MainActor
final class CmuxLiteApp: NSObject, NSApplicationDelegate {
    private var windowController: CmuxLiteWindowController?

    static func main() {
        let application = NSApplication.shared
        let delegate = CmuxLiteApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_: Notification) {
        do {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            let configuration = try CmuxConnectionConfiguration.parse(
                arguments: Array(CommandLine.arguments.dropFirst()),
                readFile: { path in
                    try String(contentsOfFile: path, encoding: .utf8)
                }
            )
            let transport = FallbackWebSocketTransport(url: configuration.url)
            let client = CmuxProtocolClient(transport: transport)
            let attachmentClientFactory = FallbackCmuxProtocolClientFactory(
                url: configuration.url
            )
            let frontend = CmuxFrontendSession(
                client: client,
                attachmentClientFactory: attachmentClientFactory,
                configuration: configuration
            )
            let controller = CmuxLiteWindowController(frontend: frontend)
            windowController = controller
            controller.showWindow(nil)
            controller.start(hostname: ProcessInfo.processInfo.hostName)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            NSApp.presentError(error)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
