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
            let configuration = try CmuxConnectionConfiguration.parse(
                arguments: Array(CommandLine.arguments.dropFirst()),
                readFile: { path in
                    try String(contentsOfFile: path, encoding: .utf8)
                }
            )
            let transport = URLSessionWebSocketTransport(url: configuration.url)
            let client = CmuxProtocolClient(transport: transport)
            let frontend = CmuxFrontendSession(client: client, configuration: configuration)
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
