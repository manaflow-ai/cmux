import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("SSH cmux-tui migration")
struct SSHTuiMigrationTests {
    private func configuration(options: [String] = [], command: String? = nil, identityFile: String = "/tmp/key with spaces") -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "alice@example.invalid", port: 2222, identityFile: identityFile,
            sshOptions: options, localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: command,
            preserveAfterTerminalExit: true
        )
    }

    @Test("OpenSSH resolves the cmux-tui carrier as a non-PTY exec channel")
    func carrierOverridesInteractiveHostDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key with spaces")
        try Data().write(to: key)
        let connection = SSHTuiConnection(configuration: configuration(options: [
            "RequestTTY=force", "RemoteCommand=interactive-only", "StrictHostKeyChecking=yes",
        ], identityFile: key.path))
        let arguments = connection.arguments(stateDirectory: "/tmp/client state", deviceName: "test")
        let sshArguments = arguments.indices.compactMap { index -> String? in
            guard index > 0, arguments[index - 1] == "--ssh-arg" else { return nil }
            return arguments[index]
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", "/dev/null"] + sshArguments + [connection.configuration.destination]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let values = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(values.contains("requesttty false"))
        #expect(!values.contains(where: { $0.hasPrefix("remotecommand ") }))
        #expect(values.contains("port 2222"))
        #expect(values.contains("stricthostkeychecking true"))
        #expect(values.contains(Substring("identityfile " + key.path)))
    }

    @Test("Changing a ControlMaster path does not change persistent SSH terminal identity")
    func sessionIdentitySurvivesCarrierReplacement() {
        let first = SSHTuiConnection(configuration: configuration(options: ["ControlPath=/tmp/first", "ProxyJump=bastion"]))
        let replacement = SSHTuiConnection(configuration: configuration(options: ["ControlPath=/tmp/second", "ProxyJump=bastion"]))
        let otherRoute = SSHTuiConnection(configuration: configuration(options: ["ProxyJump=another-host"]))
        #expect(first.id == replacement.id)
        #expect(first.id != otherRoute.id)
        #expect(SurfaceMachineID(rawValue: first.id).isSSH)
        #expect(SurfaceMachineID(rawValue: first.id).cloudMachineID == nil)
    }

    @Test("Saved SSH connections restore without executing the retired PTY wrapper")
    func restorePreservesEndpointWithoutLegacyDaemonLaunch() throws {
        let original = configuration(options: ["ProxyJump=bastion"], command: "exec fish -l")
        let snapshot = try #require(original.sessionSnapshot())
        let persisted = try JSONEncoder().encode(snapshot)
        let restored = try #require(try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: persisted).workspaceConfiguration())
        #expect(restored.destination == original.destination)
        #expect(restored.port == original.port)
        #expect(restored.configuredRemoteCommand == original.configuredRemoteCommand)
        #expect(restored.preserveAfterTerminalExit)
        #expect(restored.terminalStartupCommand == nil)
        #expect(restored.relayPort == nil)
        #expect(restored.foregroundAuthToken == nil)
        #expect(SSHTuiConnection(configuration: original).id == SSHTuiConnection(configuration: restored).id)
    }

    @Test("SSH projection identities survive session serialization without becoming Cloud machines")
    func projectionRoundTripRetainsSSHBackend() throws {
        let id = SSHTuiConnection(configuration: configuration()).id
        let record = SurfaceProjectionRecord(panelID: UUID(), resource: SurfaceResourceID(
            machine: SurfaceMachineID(rawValue: id), kind: .terminal, key: "term_persistent"
        ), remoteWorkspaceID: "ws_persistent", remoteTabID: "tab_persistent")
        let decoded = try JSONDecoder().decode(SurfaceProjectionRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.resource == record.resource)
        #expect(decoded.remoteWorkspaceID == "ws_persistent")
        #expect(decoded.remoteTabID == "tab_persistent")
        #expect(decoded.resource.machine.isSSH)
    }
}
