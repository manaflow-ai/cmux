@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class WorkspaceRemoteConfigurationTransportKeyTests: XCTestCase {
    func testProxyBrokerTransportKeyIgnoresControlPath() {
        let first = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "Compression=yes",
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-64000-%C",
            ],
            localProxyPort: 9000,
            relayPort: 64000,
            relayID: "relay-a",
            relayToken: "token-a",
            localSocketPath: "/tmp/cmux-a.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let second = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "Compression=yes",
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-64001-%C",
            ],
            localProxyPort: 9000,
            relayPort: 64001,
            relayID: "relay-b",
            relayToken: "token-b",
            localSocketPath: "/tmp/cmux-b.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        XCTAssertEqual(first.proxyBrokerTransportKey, second.proxyBrokerTransportKey)
    }

    func testProxyBrokerTransportKeyIgnoresEphemeralAgentSocketPath() {
        let first = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "ForwardAgent=yes",
                "ControlMaster=auto",
            ],
            localProxyPort: 9000,
            relayPort: 64000,
            relayID: "relay-a",
            relayToken: "token-a",
            localSocketPath: "/tmp/cmux-a.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            agentSocketPath: "/tmp/cmux-agent-a.sock"
        )
        let second = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "ForwardAgent=yes",
                "ControlMaster=auto",
            ],
            localProxyPort: 9000,
            relayPort: 64000,
            relayID: "relay-b",
            relayToken: "token-b",
            localSocketPath: "/tmp/cmux-b.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            agentSocketPath: "/tmp/cmux-agent-b.sock"
        )

        XCTAssertEqual(first.proxyBrokerTransportKey, second.proxyBrokerTransportKey)
    }

    func testPersistentPTYIdentityRequiresSameRelayPort() {
        let first = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "Compression=yes",
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-64000-%C",
            ],
            localProxyPort: nil,
            relayPort: 64000,
            relayID: "relay-a",
            relayToken: "token-a",
            localSocketPath: "/tmp/cmux-a.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test-slot"
        )
        let second = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "Compression=yes",
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-64001-%C",
            ],
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-b",
            relayToken: "token-b",
            localSocketPath: "/tmp/cmux-b.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test-slot"
        )

        XCTAssertFalse(first.hasSamePersistentPTYIdentity(as: second))
        XCTAssertFalse(second.hasSamePersistentPTYIdentity(as: first))
    }

    func testPersistentPTYIdentityIgnoresEphemeralAgentSocketPath() {
        let first = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "ForwardAgent=yes",
                "ControlMaster=auto",
            ],
            localProxyPort: nil,
            relayPort: 64000,
            relayID: "relay-a",
            relayToken: "token-a",
            localSocketPath: "/tmp/cmux-a.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            agentSocketPath: "/tmp/cmux-agent-a.sock",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test-slot"
        )
        let second = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 22,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "ForwardAgent=yes",
                "ControlMaster=auto",
            ],
            localProxyPort: nil,
            relayPort: 64000,
            relayID: "relay-b",
            relayToken: "token-b",
            localSocketPath: "/tmp/cmux-b.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            agentSocketPath: "/tmp/cmux-agent-b.sock",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test-slot"
        )

        XCTAssertTrue(first.hasSamePersistentPTYIdentity(as: second))
        XCTAssertTrue(second.hasSamePersistentPTYIdentity(as: first))
    }
}

