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
        do {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            let environment = ProcessInfo.processInfo.environment
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
            let ghosttyConfigText = (try? String(
                contentsOfFile: ghosttyConfigPath,
                encoding: .utf8
            )) ?? ""
            let controller = CmuxLiteWindowController(
                frontend: frontend,
                ghosttyViewConfiguration: .parse(ghosttyConfigText),
                ghosttyConfigPath: FileManager.default.fileExists(atPath: ghosttyConfigPath)
                    ? ghosttyConfigPath
                    : nil
            )
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
