@testable import CmuxComputerUse
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Host settings shortcut notifications", .serialized)
struct HostSettingsShortcutNotificationTests {
    @Test
    func changedSettingsFilePostsOneShortcutNotification() throws {
        try withSettingsFile(
            initialContents: #"{"shortcuts":{"openBrowser":"cmd+b"}}"#,
            updatedContents: #"{"shortcuts":{"openBrowser":"cmd+n"}}"#,
            expectedNotificationCount: 1
        )
    }

    @Test
    func unchangedSettingsFileStillPostsOneShortcutNotification() throws {
        let contents = #"{"shortcuts":{"openBrowser":"cmd+b"}}"#
        try withSettingsFile(
            initialContents: contents,
            updatedContents: contents,
            expectedNotificationCount: 1
        )
    }

    @Test
    func agentIntegrationActionDoesNotExposeCommandDiagnostics() async {
        let diagnostics = "token=private-hook-secret"
        let controller = AgentIntegrationSettingsController(
            commands: AgentIntegrationStubCommandRunner(result: CommandResult(
                stdout: nil,
                stderr: diagnostics,
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )),
            executablePath: "/tmp/cmux",
            environment: ["HOME": "/tmp"]
        )

        let result = await controller.perform(.install, for: .amp)

        #expect(!result.succeeded)
        #expect(result.message == String(
            localized: "settings.automation.integration.install.failed",
            defaultValue: "The hook installer could not complete the requested action."
        ))
        #expect(result.message?.contains("private-hook-secret") == false)
    }

    private func withSettingsFile(
        initialContents: String,
        updatedContents: String,
        expectedNotificationCount: Int
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-host-shortcut-notifications-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try initialContents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        defer { KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore }

        let counter = ShortcutChangeNotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.object as? URL == settingsFileURL else { return }
            counter.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try updatedContents.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        HostSettingsActions(
            configFileURL: settingsFileURL,
            computerUseRuntimeService: ComputerUseRuntimeService()
        ).notifyShortcutSettingsDidChange()

        #expect(counter.value == expectedNotificationCount)
    }
}

private final class ShortcutChangeNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}


private struct AgentIntegrationStubCommandRunner: CommandRunning {
    let result: CommandResult

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        result
    }
}
