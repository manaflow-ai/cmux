import CmuxFoundation
import CmuxSettingsUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private actor AgentIntegrationScriptedRunner: CommandRunning {
    var results: [CommandResult]
    private(set) var arguments: [[String]] = []

    init(results: [CommandResult]) { self.results = results }

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        self.arguments.append(arguments)
        return results.isEmpty
            ? CommandResult(stdout: nil, stderr: "unexpected invocation", exitStatus: 1, timedOut: false, executionError: nil)
            : results.removeFirst()
    }
}

@Suite("Agent integration installer adapter")
struct AgentIntegrationSettingsControllerTests {
    @Test(arguments: [
        ("missing", AgentIntegrationInstallState.missing),
        ("installed", AgentIntegrationInstallState.installed),
        ("stale", AgentIntegrationInstallState.stale),
        ("conflict", AgentIntegrationInstallState.conflict),
        ("unavailable", AgentIntegrationInstallState.unavailable),
    ])
    func readsAuthoritativeStatus(state: String, expected: AgentIntegrationInstallState) async {
        let runner = AgentIntegrationScriptedRunner(results: [
            CommandResult(
                stdout: #"{"integration":"amp","state":"\#(state)"}"#,
                stderr: nil,
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        ])
        let controller = AgentIntegrationSettingsController(
            commands: runner,
            executablePath: "/tmp/cmux",
            environment: ["HOME": "/tmp"]
        )
        #expect(await controller.installState(.amp) == expected)
        #expect(await runner.arguments == [["hooks", "amp", "install", "--status-json"]])
    }

    @Test(arguments: [
        (AgentIntegrationInstallAction.install, ["hooks", "amp", "install", "--yes"]),
        (AgentIntegrationInstallAction.repair, ["hooks", "amp", "install", "--yes"]),
        (AgentIntegrationInstallAction.remove, ["hooks", "amp", "uninstall"]),
    ])
    func delegatesLifecycleActions(action: AgentIntegrationInstallAction, expectedArguments: [String]) async {
        let runner = AgentIntegrationScriptedRunner(results: [
            CommandResult(stdout: nil, stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
        ])
        let controller = AgentIntegrationSettingsController(commands: runner, executablePath: "/tmp/cmux", environment: ["HOME": "/tmp"])
        #expect(await controller.perform(action, for: .amp) == .success)
        #expect(await runner.arguments == [expectedArguments])
    }

    @Test func reportsFailureWithoutLeakingInstallerDiagnostics() async {
        let runner = AgentIntegrationScriptedRunner(results: [
            CommandResult(stdout: nil, stderr: "secret diagnostic", exitStatus: 2, timedOut: false, executionError: nil)
        ])
        let controller = AgentIntegrationSettingsController(commands: runner, executablePath: "/tmp/cmux", environment: ["HOME": "/tmp"])
        let result = await controller.perform(.install, for: .amp)
        #expect(!result.succeeded)
        #expect(result.message?.contains("secret diagnostic") == false)
    }

    /// An unreadable hook must disable installation until a later probe succeeds.
    @Test func failedStatusCanRecoverWithoutRunningAnInstaller() async {
        let runner = AgentIntegrationScriptedRunner(results: [
            CommandResult(stdout: nil, stderr: "private hook path", exitStatus: 1, timedOut: false, executionError: nil),
            CommandResult(stdout: #"{"integration":"amp","state":"missing"}"#, stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
        ])
        let controller = AgentIntegrationSettingsController(commands: runner, executablePath: "/tmp/cmux", environment: ["HOME": "/tmp"])
        #expect(await controller.installState(.amp) == .unavailable)
        #expect(await controller.installState(.amp) == .missing)
        #expect(await runner.arguments == Array(repeating: ["hooks", "amp", "install", "--status-json"], count: 2))
    }
}
