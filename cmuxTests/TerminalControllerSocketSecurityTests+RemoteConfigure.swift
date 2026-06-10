import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Remote status and remote.configure validation
extension TerminalControllerSocketSecurityTests {
    func testRemoteStatusPayloadOmitsSensitiveSSHConfiguration() {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: false, eagerLoadTerminal: false)

        workspace.configureRemoteConnection(
            .init(
                destination: "example.com",
                port: 2222,
                identityFile: "/Users/test/.ssh/id_ed25519",
                sshOptions: ["ControlMaster=auto", "ControlPersist=600"],
                localProxyPort: 1080,
                relayPort: 4444,
                relayID: "relay-id",
                relayToken: "relay-token",
                localSocketPath: "/tmp/cmux-test.sock",
                terminalStartupCommand: "ssh example.com"
            ),
            autoConnect: false
        )

        let payload = workspace.remoteStatusPayload()
        XCTAssertNil(payload["identity_file"])
        XCTAssertNil(payload["ssh_options"])
        XCTAssertEqual(payload["has_identity_file"] as? Bool, true)
        XCTAssertEqual(payload["has_ssh_options"] as? Bool, true)
    }

    func testRemoteConfigureRejectsInvalidPersistentDaemonSlot() throws {
        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": UUID().uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "persistent_daemon_slot": "../bad",
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        XCTAssertEqual(
            error["message"] as? String,
            "persistent_daemon_slot must contain only letters, numbers, '.', '_' or '-'"
        )
    }

    func testRemoteConfigureDefaultsPersistentDaemonSlotForBootstrapSSH() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "preserve_after_terminal_exit": true,
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(workspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        XCTAssertEqual(
            workspace.remoteConfiguration?.persistentDaemonSlot,
            "ssh-\(workspace.id.uuidString.lowercased())"
        )
    }

    func testRemoteConfigureDerivesAgentSocketPathFromForwardAgentOption() throws {
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        let agentSocketPath = try makeExistingAgentSocketPath()
        setenv("SSH_AUTH_SOCK", agentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "ssh_options": ["ForwardAgent=yes"],
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(workspace.remoteConfiguration?.agentSocketPath, agentSocketPath)
        XCTAssertEqual(workspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(workspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
    }

    func testRemoteConfigureExplicitEmptyAgentSocketSuppressesForwardAgentFallback() throws {
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        let agentSocketPath = try makeExistingAgentSocketPath()
        setenv("SSH_AUTH_SOCK", agentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "ssh_options": ["ForwardAgent=yes"],
                "ssh_auth_sock": "",
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertNil(workspace.remoteConfiguration?.agentSocketPath)
        XCTAssertNil(workspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"])
        XCTAssertNil(workspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"])
    }

    func testRemoteConfigureUsesLastForwardAgentOption() throws {
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        let agentSocketPath = try makeExistingAgentSocketPath()
        setenv("SSH_AUTH_SOCK", agentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "ssh_options": ["ForwardAgent=yes", "ForwardAgent=no"],
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertNil(workspace.remoteConfiguration?.agentSocketPath)
        XCTAssertNil(workspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"])
        XCTAssertNil(workspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"])
    }

    func testRemoteConfigureRejectsPersistentDaemonSlotWithoutPreserve() throws {
        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": UUID().uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "persistent_daemon_slot": "ssh-test-slot",
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        XCTAssertEqual(
            error["message"] as? String,
            "preserve_after_terminal_exit is required when persistent_daemon_slot is set"
        )
    }

}
