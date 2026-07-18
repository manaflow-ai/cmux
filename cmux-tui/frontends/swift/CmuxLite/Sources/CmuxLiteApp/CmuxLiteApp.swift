import AppKit
import CmuxLiteCore
import Darwin

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
        let environment = ProcessInfo.processInfo.environment
        Task { [weak self] in
            await self?.launch(environment: environment)
        }
    }

    private func launch(environment: [String: String]) async {
        do {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            let configuration = try CmuxConnectionConfiguration.parse(
                arguments: Array(CommandLine.arguments.dropFirst()),
                environment: environment,
                userID: getuid(),
                readFile: { path in
                    try String(contentsOfFile: path, encoding: .utf8)
                },
                listDirectory: { directory in
                    try FileManager.default.contentsOfDirectory(atPath: directory).map {
                        URL(fileURLWithPath: directory, isDirectory: true)
                            .appendingPathComponent($0, isDirectory: false)
                            .path
                    }
                }
            )
            let transport = configuration.endpoint.makeTransport()
            let client = CmuxProtocolClient(transport: transport)
            let attachmentClientFactory = ConfiguredCmuxProtocolClientFactory(
                endpoint: configuration.endpoint
            )
            let frontend = CmuxFrontendSession(
                client: client,
                attachmentClientFactory: attachmentClientFactory,
                configuration: configuration
            )
            let homeDirectory = environment["HOME"] ?? NSHomeDirectory()
            let ghosttyConfigPath = CmuxGhosttyViewConfiguration.configPath(
                homeDirectory: homeDirectory
            )
            let ghosttyViewConfiguration = await CmuxGhosttyConfigurationResolver(
                environment: environment,
                homeDirectory: homeDirectory
            ).resolve(configPath: ghosttyConfigPath)
            CmuxPalette.configure(with: ghosttyViewConfiguration)
            let controller = CmuxLiteWindowController(
                frontend: frontend,
                ghosttyViewConfiguration: ghosttyViewConfiguration
            )
            windowController = controller
            controller.showWindow(nil)
            controller.start(hostname: ProcessInfo.processInfo.hostName)
            CmuxStateDump.installIfConfigured()
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
