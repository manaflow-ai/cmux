import AppKit
import CMUXAgentLaunch
import CmuxCore
import CmuxSidebar
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class RemoteResumeHookCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    func append(_ command: String) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}

private enum RemoteResumeHookSocketServer {
    static func start(
        listenerFD: Int32,
        capture: RemoteResumeHookCapture,
        surfaceID: UUID
    ) -> DispatchSemaphore {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.signal() }
            var clientAddress = sockaddr_un()
            var clientAddressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(listenerFD, socketAddress, &clientAddressLength)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)

                while let newline = pending.firstIndex(of: 0x0A) {
                    let lineData = pending.subdata(in: 0..<newline)
                    pending.removeSubrange(0...newline)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    capture.append(line)
                    write(response(for: line, surfaceID: surfaceID), to: clientFD)
                }
            }
        }
        return finished
    }

    private static func response(for line: String, surfaceID: UUID) -> String {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String,
              let method = request["method"] as? String else {
            return "OK"
        }
        let result: [String: Any]
        switch method {
        case "surface.list":
            result = [
                "id": id,
                "ok": true,
                "result": [
                    "surfaces": [[
                        "id": surfaceID.uuidString,
                        "ref": "surface:1",
                        "index": 1,
                        "focused": true,
                    ]],
                ],
            ]
        case "surface.resume.set", "feed.push":
            result = ["id": id, "ok": true, "result": ["ok": true]]
        default:
            result = [
                "id": id,
                "ok": false,
                "error": [
                    "code": "unrecognized_method",
                    "message": "unexpected method: \(method)",
                ],
            ]
        }
        let responseData = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        return String(decoding: responseData, as: UTF8.self)
    }

    private static func write(_ response: String, to fileDescriptor: Int32) {
        let bytes = Array((response + "\n").utf8)
        bytes.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(fileDescriptor, cursor, remaining)
                if count > 0 {
                    cursor = cursor.advanced(by: count)
                    remaining -= count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

@Suite(.serialized)
@MainActor
struct RemoteResumeBindingTests {
    private let relayPort = 64_089

    private struct HookRunResult {
        let status: Int32
        let stderr: String
        let timedOut: Bool
        let commands: [String]
    }

    @Test
    func emptyPersistentSessionIDsNeverMatch() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let context = SurfaceResumeRemoteContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: ""
        )

        #expect(!context.matches(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: "   "
        ))
    }

    @Test
    func escapedResumeMethodRetainsAuthenticatedRemoteProvenance() throws {
        let workspaceID = UUID()
        let relayToken = String(repeating: "b", count: 64)
        let commandLine = Data(
            #"{"id":"escaped-resume","method":"surface.resume\u002eset","params":{"command":"codex resume escaped-session"}}"#.utf8
        )

        let rewritten = WorkspaceRemoteRelayCommandRewriter(
            remoteWorkspaceID: workspaceID,
            remoteRelayTokenHex: relayToken
        ).rewriteRemoteRelayCommandLine(
            commandLine,
            workspaceAliases: [:],
            surfaceAliases: [:]
        )
        let request = try #require(
            JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        let params = try #require(request["params"] as? [String: Any])

        #expect(params["_cmux_remote_workspace_id"] as? String == workspaceID.uuidString)
        #expect(WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
            params,
            remoteRelayTokenHex: relayToken
        ))
    }

    @Test
    func relayDeliveryTargetProvenanceOverridesSpoofedWorkspace() throws {
        let workspaceID = UUID()
        let spoofedWorkspaceID = UUID()
        let request: [String: Any] = [
            "id": "relay-delivery-target",
            "method": "agent.resolve_delivery_target",
            "params": [
                "tty_name": "0",
                "tty_resolution": "reported_tty",
                "_cmux_remote_workspace_id": spoofedWorkspaceID.uuidString,
            ],
        ]

        let rewritten = WorkspaceRemoteRelayCommandRewriter(
            remoteWorkspaceID: workspaceID,
            remoteRelayTokenHex: String(repeating: "a", count: 64)
        ).rewriteRemoteRelayCommandLine(
            try requestData(request),
            workspaceAliases: [:],
            surfaceAliases: [:]
        )
        let rewrittenRequest = try jsonRequest(rewritten)
        let params = try #require(rewrittenRequest["params"] as? [String: Any])

        #expect(params["_cmux_remote_workspace_id"] as? String == workspaceID.uuidString)
        #expect(params["tty_name"] as? String == "0")
        #expect(params["tty_resolution"] as? String == "reported_tty")
    }

    @Test
    func remoteResumeProvenanceRequiresExactMethodAndUntamperedAuthentication() throws {
        let workspaceID = UUID()
        let relayToken = String(repeating: "c", count: 64)
        let rewriter = WorkspaceRemoteRelayCommandRewriter(
            remoteWorkspaceID: workspaceID,
            remoteRelayTokenHex: relayToken
        )
        let request: [String: Any] = [
            "id": "authenticated-resume",
            "method": "surface.resume.set",
            "params": [
                "workspace_id": workspaceID.uuidString,
                "surface_id": UUID().uuidString,
                "command": "codex resume authenticated-session",
            ],
        ]
        let rewritten = rewriter.rewriteRemoteRelayCommandLine(
            try requestData(request),
            workspaceAliases: [:],
            surfaceAliases: [:]
        )
        let rewrittenRequest = try jsonRequest(rewritten)
        let authenticatedParams = try #require(rewrittenRequest["params"] as? [String: Any])

        #expect(authenticatedParams["_cmux_remote_workspace_id"] as? String == workspaceID.uuidString)
        #expect(WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
            authenticatedParams,
            remoteRelayTokenHex: relayToken
        ))

        for authenticationCode in [nil, "", "0", "not-hex", String(repeating: "0", count: 64)] as [String?] {
            var invalidParams = authenticatedParams
            invalidParams["_cmux_remote_relay_authentication_code"] = authenticationCode
            #expect(!WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
                invalidParams,
                remoteRelayTokenHex: relayToken
            ))
        }

        var missingProvenance = authenticatedParams
        missingProvenance.removeValue(forKey: "_cmux_remote_workspace_id")
        #expect(!WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
            missingProvenance,
            remoteRelayTokenHex: relayToken
        ))

        var tampered = authenticatedParams
        tampered["command"] = "codex resume attacker-session"
        #expect(!WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
            tampered,
            remoteRelayTokenHex: relayToken
        ))

        for method in ["surface.resume.get", "surface.resume.set.backup", "surface.resume.setter", "custom.surface.resume.set"] {
            let unrelated: [String: Any] = [
                "id": "unrelated-\(method)",
                "method": method,
                "params": ["command": "must remain unauthenticated"],
            ]
            let original = try requestData(unrelated)
            let unrelatedResult = rewriter.rewriteRemoteRelayCommandLine(
                original,
                workspaceAliases: [:],
                surfaceAliases: [:]
            )
            #expect(unrelatedResult == original)
            let unrelatedParams = try #require(try jsonRequest(unrelatedResult)["params"] as? [String: Any])
            #expect(unrelatedParams["_cmux_remote_workspace_id"] == nil)
            #expect(unrelatedParams["_cmux_remote_relay_authentication_code"] == nil)
        }
    }

    @Test
    func remoteContextRejectsWrongOwnersAndBlankPersistentSessions() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let context = SurfaceResumeRemoteContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: "session-owned"
        )

        #expect(context.matches(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: "  session-owned\n"
        ))
        #expect(!context.matches(
            workspaceID: UUID(),
            surfaceID: surfaceID,
            persistentPTYSessionID: "session-owned"
        ))
        #expect(!context.matches(
            workspaceID: workspaceID,
            surfaceID: UUID(),
            persistentPTYSessionID: "session-owned"
        ))
        #expect(!context.matches(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: "session-other"
        ))
        #expect(!context.matches(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: " \t\n "
        ))
        let blankStoredContext = SurfaceResumeRemoteContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: " \t\n "
        )
        #expect(!blankStoredContext.matches(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: "session-owned"
        ))
    }

    @Test
    func bundledKiroSessionStartRegistersAuthenticatedRemoteBinding() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false)

        let relayedWorkspaceID = UUID()
        let relayedSurfaceID = UUID()
        let remotePTYSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: relayedWorkspaceID,
            panelId: relayedSurfaceID
        )
        workspace.remotePTYSessionIDsByPanelId[surfaceID] = remotePTYSessionID
        workspace.registerRemoteRelayIDAliases(
            remotePTYSessionID: remotePTYSessionID,
            restoredPanelId: surfaceID
        )

        let hook = try runBundledKiroSessionStart(
            workspaceID: relayedWorkspaceID,
            surfaceID: relayedSurfaceID
        )
        #expect(!hook.timedOut, Comment(rawValue: hook.stderr))
        #expect(hook.status == 0, Comment(rawValue: hook.stderr))
        let resumeRequests = hook.commands.compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return request["method"] as? String == "surface.resume.set" ? request : nil
        }
        #expect(resumeRequests.count == 1, "\(hook.commands)")
        let resumeRequest = try #require(resumeRequests.first)
        let hookParams = try #require(resumeRequest["params"] as? [String: Any])
        #expect(hookParams["workspace_id"] as? String == relayedWorkspaceID.uuidString)
        #expect(hookParams["surface_id"] as? String == relayedSurfaceID.uuidString)
        #expect(hookParams["source"] as? String == "agent-hook")
        #expect(hookParams["kind"] as? String == "kiro")
        #expect(hookParams["checkpoint_id"] as? String == "kiro-remote-session")
        #expect(hookParams["auto_resume"] as? Bool == true)

        let relayedData = workspace.rewriteRemoteRelayCommandLine(try requestData(resumeRequest))
        let remoteResult = try v2Result(requestData: relayedData)
        let remoteBinding = try #require(remoteResult["resume_binding"] as? [String: Any])
        #expect(remoteBinding["execution_location"] as? String == "remote_ssh")
        #expect(remoteBinding["remote_workspace_id"] as? String == workspace.id.uuidString)
        #expect(remoteBinding["remote_surface_id"] as? String == surfaceID.uuidString)
        #expect(remoteBinding["remote_pty_session_id"] as? String == remotePTYSessionID)
        #expect((remoteBinding["command"] as? String)?.contains("kiro-remote-session") == true)
    }

    @Test
    func remoteRegistrationRejectsMissingProvenanceAndInvalidPersistentOwnership() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false)
        let relayToken = try #require(workspace.remoteConfiguration?.relayToken)

        var missingAuthenticationParams = remoteResumeParams(
            workspaceID: workspace.id,
            surfaceID: surfaceID,
            command: "codex resume missing-authentication"
        )
        missingAuthenticationParams["_cmux_remote_workspace_id"] = workspace.id.uuidString
        let missingAuthentication = try v2Envelope(request: [
            "id": "missing-authentication",
            "method": "surface.resume.set",
            "params": missingAuthenticationParams,
        ])
        #expect(missingAuthentication["ok"] as? Bool == false)

        var malformedProvenanceParams = remoteResumeParams(
            workspaceID: workspace.id,
            surfaceID: surfaceID,
            command: "codex resume malformed-provenance"
        )
        malformedProvenanceParams["_cmux_remote_workspace_id"] = "not-a-workspace-id"
        malformedProvenanceParams["_cmux_remote_relay_authentication_code"] = String(repeating: "0", count: 64)
        let malformedProvenance = try v2Envelope(request: [
            "id": "malformed-provenance",
            "method": "surface.resume.set",
            "params": malformedProvenanceParams,
        ])
        #expect(malformedProvenance["ok"] as? Bool == false)

        let wrongClaimRequest: [String: Any] = [
            "id": "wrong-remote-owner",
            "method": "surface.resume.set",
            "params": remoteResumeParams(
                workspaceID: workspace.id,
                surfaceID: surfaceID,
                command: "codex resume wrong-owner"
            ),
        ]
        let wrongClaimData = WorkspaceRemoteRelayCommandRewriter(
            remoteWorkspaceID: UUID(),
            remoteRelayTokenHex: relayToken
        ).rewriteRemoteRelayCommandLine(
            try requestData(wrongClaimRequest),
            workspaceAliases: [:],
            surfaceAliases: [:]
        )
        let wrongClaim = try v2Envelope(requestData: wrongClaimData)
        #expect(wrongClaim["ok"] as? Bool == false)

        workspace.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false, persistentDaemonSlot: nil),
            autoConnect: false
        )
        let nonPersistentRequest: [String: Any] = [
            "id": "non-persistent-owner",
            "method": "surface.resume.set",
            "params": remoteResumeParams(
                workspaceID: workspace.id,
                surfaceID: surfaceID,
                command: "codex resume non-persistent"
            ),
        ]
        let nonPersistentData = WorkspaceRemoteRelayCommandRewriter(
            remoteWorkspaceID: workspace.id,
            remoteRelayTokenHex: relayToken
        ).rewriteRemoteRelayCommandLine(
            try requestData(nonPersistentRequest),
            workspaceAliases: [:],
            surfaceAliases: [:]
        )
        let nonPersistent = try v2Envelope(requestData: nonPersistentData)
        #expect(nonPersistent["ok"] as? Bool == false)

        let bindingAfterRejectedRegistrations = try v2Result(request: [
            "id": "binding-after-rejections",
            "method": "surface.resume.get",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])["resume_binding"]
        #expect(bindingAfterRejectedRegistrations is NSNull)
    }

    @Test
    func relayedRegistrationUsesExplicitRemoteFlavorAfterAliasRewrite() throws {
        let fixture = try makeRelayedFixture()

        #expect(fixture.localBinding["execution_location"] as? String == "local")
        #expect(fixture.localBinding["remote_workspace_id"] is NSNull)
        #expect(fixture.spoofedRelayRegistrationRejected)
        #expect(fixture.remoteBinding["execution_location"] as? String == "remote_ssh")
        #expect(fixture.remoteBinding["remote_workspace_id"] as? String == fixture.workspaceID.uuidString)
        #expect(fixture.remoteBinding["remote_surface_id"] as? String == fixture.surfaceID.uuidString)
        #expect(fixture.remoteBinding["remote_pty_session_id"] as? String == fixture.remotePTYSessionID)
        #expect(fixture.remoteBinding["cwd"] as? String == "/srv/remote project")
        #expect(fixture.remoteBinding["auto_resume"] as? Bool == true)

        let environment = try #require(fixture.remoteBinding["environment"] as? [String: Any])
        #expect(environment["REMOTE_FLAG"] as? String == "value with spaces")
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
    }

    @Test
    func persistentRestoreRunsRemoteResumeOnlyWhenSessionMustBeCreated() throws {
        let fixture = try makeRelayedFixture()
        let suiteName = "cmux-remote-resume-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let socketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(socketPath) }

        let restoredWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let restoredIDs = restoredWorkspace.restoreSessionSnapshot(fixture.snapshot)
        let restoredSurfaceID = try #require(restoredIDs[fixture.surfaceID])
        let restoredPanel = try #require(restoredWorkspace.terminalPanel(for: restoredSurfaceID))
        let liveFirstCommand = try #require(restoredPanel.surface.debugInitialCommand())

        #expect(liveFirstCommand.contains("ssh-pty-attach"), "\(liveFirstCommand)")
        #expect(liveFirstCommand.contains("--require-existing"), "\(liveFirstCommand)")
        let liveFirstRemoteCommand = try decodedRemoteCommand(from: liveFirstCommand)
        try expectRemoteResumeBootstrap(liveFirstRemoteCommand)
        #expect(restoredPanel.surface.debugInitialInputForTesting() == nil)

        let roundTrip = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let roundTripBinding = try #require(
            roundTrip.panels.first { $0.id == restoredSurfaceID }?.terminal?.resumeBinding
        )
        let encodedBinding = try JSONEncoder().encode(roundTripBinding)
        let bindingObject = try #require(
            JSONSerialization.jsonObject(with: encodedBinding) as? [String: Any]
        )
        let launchFlavor = try #require(bindingObject["launchFlavor"] as? [String: Any])
        #expect(launchFlavor["kind"] as? String == "persistentSSH")
        let remoteContext = try #require(launchFlavor["remoteContext"] as? [String: Any])
        #expect(remoteContext["workspaceID"] as? String == restoredWorkspace.id.uuidString)
        #expect(remoteContext["surfaceID"] as? String == restoredSurfaceID.uuidString)
        #expect(remoteContext["persistentPTYSessionID"] as? String == fixture.remotePTYSessionID)

        let ended = restoredWorkspace.markRemotePTYAttachEnded(
            surfaceId: restoredSurfaceID,
            sessionID: fixture.remotePTYSessionID
        )
        #expect(ended.clearedRemotePTYSession)
        restoredWorkspace.markPersistentRemotePTYAttachFailed(surfaceId: restoredSurfaceID)
        let restarted = restoredWorkspace.reattachPersistentRemotePTYPanels(
            requestedSurfaceId: restoredSurfaceID,
            restartEndedSessions: true
        )
        #expect(restarted == [restoredSurfaceID])

        let gonePTYCommand = try #require(
            restoredWorkspace.terminalPanel(for: restoredSurfaceID)?.surface.debugInitialCommand()
        )
        #expect(!gonePTYCommand.contains("--require-existing"), "\(gonePTYCommand)")
        let gonePTYRemoteCommand = try decodedRemoteCommand(from: gonePTYCommand)
        try expectRemoteResumeBootstrap(gonePTYRemoteCommand)
    }

    @Test
    func persistentBindingOnlyRestoreTracksStartupCommandUntilPromptReturns() throws {
        let fixture = try makeRelayedFixture(verifyingPromptSelectiveRuntimeCleanup: true)
        let suiteName = "cmux-remote-resume-lifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let socketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(socketPath) }

        let restoredWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restoredWorkspace.teardownAllPanels() }
        let restoredIDs = restoredWorkspace.restoreSessionSnapshot(fixture.snapshot)
        let restoredSurfaceID = try #require(restoredIDs[fixture.surfaceID])

        #expect(
            restoredWorkspace.restoredAgentResumeStatesByPanelId[restoredSurfaceID]
                == .autoResumeCommandRunning
        )
        let runningBinding = try #require(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredSurfaceID }?.terminal?.resumeBinding
        )
        #expect(runningBinding.autoResume == true)

        restoredWorkspace.updatePanelShellActivityState(
            panelId: restoredSurfaceID,
            state: .promptIdle
        )

        #expect(restoredWorkspace.restoredAgentResumeStatesByPanelId[restoredSurfaceID] == nil)
        let retiredBinding = try #require(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredSurfaceID }?.terminal?.resumeBinding
        )
        #expect(retiredBinding.autoResume == false)
    }

    @Test
    func transferredPersistentSSHAgentRuntimeNeverUsesLocalPIDNamespace() throws {
        let source = Workspace()
        defer { source.teardownAllPanels() }
        let configuration = remoteConfiguration()
        source.configureRemoteConnection(configuration, autoConnect: false)
        let sourcePanelID = try #require(source.focusedPanelId)
        source.trackRemoteTerminalSurface(sourcePanelID)
        let authority = try #require(WorkspaceRemoteTerminalAuthority(configuration: configuration))
        #expect(source.markRemoteTerminalSessionConnected(
            surfaceId: sourcePanelID,
            authority: authority
        ))

        let sessionID = "transferred-remote-session"
        let runtimeKey = "codex.\(sessionID)"
        source.recordAgentPID(
            key: runtimeKey,
            pid: getpid(),
            panelId: sourcePanelID,
            refreshPorts: false
        )
        source.updatePanelShellActivityState(panelId: sourcePanelID, state: .commandRunning)
        let detached = try #require(source.detachSurface(panelId: sourcePanelID))

        let destination = Workspace()
        defer { destination.teardownAllPanels() }
        let destinationPaneID = try #require(destination.bonsplitController.allPaneIds.first)
        let destinationPanelID = try #require(
            destination.attachDetachedSurface(
                detached,
                inPane: destinationPaneID,
                focus: false
            )
        )
        #expect(!destination.isRemoteTerminalSurface(destinationPanelID))
        #expect(
            destination.surfaceRegistry
                .remoteTTYReportOriginWorkspaceIDs[destinationPanelID] == source.id
        )

        // A later hook arrives after the remote panel moved into a local
        // workspace. Its PID is still from the SSH host and must remain opaque.
        destination.recordAgentPID(
            key: runtimeKey,
            pid: getpid(),
            panelId: destinationPanelID,
            refreshPorts: false
        )
        #expect(destination.agentPIDs[runtimeKey] == nil)
        #expect(
            destination.confirmedRuntimeAgentProcessIdentities(
                kind: .codex,
                sessionId: sessionID,
                panelId: destinationPanelID,
                currentProcessIdentity: { pid in
                    Workspace.agentPIDProcessIdentity(pid: pid_t(pid))
                }
            ).isEmpty
        )

        destination.recordAgentPID(
            key: runtimeKey,
            pid: .max,
            panelId: destinationPanelID,
            refreshPorts: false
        )
        #expect(!destination.clearStaleAgentPIDs(
            panelId: destinationPanelID,
            refreshPorts: false
        ))
        #expect(destination.agentPIDKeysByPanelId[destinationPanelID]?.contains(runtimeKey) == true)
    }

    @Test(arguments: ["codex", "acme.agent"])
    func structuredReplacementKeepsCurrentAliasesAndEvictsLegacyRuntime(
        agentKind: String
    ) throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let staleRuntimeKey = "\(agentKind).legacy-session"
        #expect(!workspace.recordAgentPID(
            key: staleRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        ))
        let status = SidebarStatusEntry(
            key: agentKind,
            value: "Running",
            icon: "bolt.fill",
            color: nil,
            timestamp: .distantPast
        )
        workspace.statusEntries[agentKind] = status
        workspace.setAgentLifecycle(
            key: agentKind,
            panelId: panelID,
            lifecycle: .running
        )

        let activeSessionID = "structured-session"
        let binding = SurfaceResumeBindingSnapshot(
            name: agentKind,
            kind: agentKind,
            command: "\(agentKind) resume \(activeSessionID)",
            cwd: "/srv/project",
            checkpointId: activeSessionID,
            source: "agent-hook",
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))
        let activeRuntimeKeys = AgentRuntimeSessionKey(
            statusKey: agentKind,
            sessionID: activeSessionID
        ).compatibleRawValues
        #expect(workspace.recordAgentPID(
            key: activeRuntimeKeys[0],
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        ))
        _ = workspace.recordAgentPID(
            key: activeRuntimeKeys[1],
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        )

        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(staleRuntimeKey) == false)
        #expect(activeRuntimeKeys.allSatisfy {
            workspace.agentPIDKeysByPanelId[panelID]?.contains($0) == true
        })
        #expect(workspace.statusEntries[agentKind] == status)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?[agentKind] == .running)
        #expect(workspace.logicalAgentPIDs() == [activeRuntimeKeys[0]: .max])

        let otherAgentKind = agentKind == "codex" ? "grok" : "codex"
        let otherLegacyRuntimeKey = "\(otherAgentKind).delayed-session"
        #expect(!workspace.recordAgentPID(
            key: otherLegacyRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        ))
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(otherLegacyRuntimeKey) != true)
        #expect(activeRuntimeKeys.allSatisfy {
            workspace.agentPIDKeysByPanelId[panelID]?.contains($0) == true
        })
        #expect(workspace.statusEntries[agentKind] == status)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?[agentKind] == .running)
    }

    @Test
    func compatibleRuntimeAliasesValidateEveryCurrentProcessIdentity() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "compatible-runtime-identities"
        let runtimeKeys = AgentRuntimeSessionKey(
            statusKey: "codex",
            sessionID: sessionID
        ).compatibleRawValues
        let encodedIdentity = AgentPIDProcessIdentity(
            pid: 41_001,
            startSeconds: 101,
            startMicroseconds: 1
        )
        let legacyIdentity = AgentPIDProcessIdentity(
            pid: 41_002,
            startSeconds: 102,
            startMicroseconds: 2
        )
        workspace.agentPIDKeysByPanelId[panelID] = Set(runtimeKeys)
        workspace.agentPIDs[runtimeKeys[0]] = encodedIdentity.pid
        workspace.agentPIDs[runtimeKeys[1]] = legacyIdentity.pid
        workspace.agentPIDProcessIdentitiesByKey[runtimeKeys[0]] = encodedIdentity
        workspace.agentPIDProcessIdentitiesByKey[runtimeKeys[1]] = legacyIdentity

        let identities = workspace.confirmedRuntimeAgentProcessIdentities(
            kind: .codex,
            sessionId: sessionID,
            panelId: panelID,
            currentProcessIdentity: { pid in
                switch pid {
                case Int(encodedIdentity.pid): return encodedIdentity
                case Int(legacyIdentity.pid): return legacyIdentity
                default: return nil
                }
            }
        )

        #expect(identities == Set([encodedIdentity, legacyIdentity]))
    }

    @Test
    func retiredDottedBindingResolvesLegacyRuntimeCleanup() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let agentKind = "acme.agent"
        let sessionID = "legacy-session"
        let runtimeKey = "\(agentKind).\(sessionID)"
        let binding = SurfaceResumeBindingSnapshot(
            name: "Acme Agent",
            kind: agentKind,
            command: "acme-agent resume \(sessionID)",
            cwd: "/srv/project",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))
        workspace.recordAgentPID(
            key: runtimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        )
        workspace.statusEntries[agentKind] = SidebarStatusEntry(
            key: agentKind,
            value: "Running"
        )
        workspace.setAgentLifecycle(
            key: agentKind,
            panelId: panelID,
            lifecycle: .running
        )

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelID))
        #expect(workspace.clearAgentPID(
            key: runtimeKey,
            panelId: panelID,
            clearStatus: true,
            requireOwnedKey: true,
            refreshPorts: false
        ))
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(runtimeKey) != true)
        #expect(workspace.statusEntries[agentKind] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?[agentKind] == nil)
    }

    @Test(arguments: ["codex", "acme.agent"])
    func metadataOnlyBindingClearAllowsLiveSessionPIDPublication(
        agentKind: String
    ) throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "live-after-resume-clear"
        let binding = SurfaceResumeBindingSnapshot(
            name: agentKind,
            kind: agentKind,
            command: "\(agentKind) resume \(sessionID)",
            cwd: "/srv/project",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true
        )
        let runtimeKeys = AgentRuntimeSessionKey(
            statusKey: agentKind,
            sessionID: sessionID
        ).compatibleRawValues

        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))
        #expect(workspace.clearSurfaceResumeBinding(panelId: panelID))
        for runtimeKey in runtimeKeys {
            _ = workspace.recordAgentPID(
                key: runtimeKey,
                pid: .max,
                panelId: panelID,
                refreshPorts: false
            )
        }
        #expect(runtimeKeys.allSatisfy {
            workspace.agentPIDKeysByPanelId[panelID]?.contains($0) == true
        })

        let mismatchedRuntimeKey = AgentRuntimeSessionKey(
            statusKey: agentKind,
            sessionID: "unexpected-session"
        ).rawValue
        _ = workspace.recordAgentPID(
            key: mismatchedRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        )
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(mismatchedRuntimeKey) != true)
        #expect(runtimeKeys.allSatisfy {
            workspace.agentPIDKeysByPanelId[panelID]?.contains($0) == true
        })

        #expect(workspace.clearSurfaceResumeBinding(
            panelId: panelID,
            agentSessionEnded: true
        ))
        for runtimeKey in runtimeKeys {
            _ = workspace.clearAgentPID(
                key: runtimeKey,
                panelId: panelID,
                clearStatus: true,
                requireOwnedKey: true,
                refreshPorts: false
            )
        }
        _ = workspace.recordAgentPID(
            key: runtimeKeys[0],
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        )
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(runtimeKeys[0]) != true)
    }

    @Test
    func controlSurfaceEndRevokesMetadataClearedBinding() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "control-retired-session-end"
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: "/srv/project",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))
        #expect(workspace.clearSurfaceResumeBinding(panelId: panelID))

        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: manager,
            workspace: workspace,
            surfaceID: panelID
        )
        let retiredBinding = try #require(target.bindingForClear(
            expectedCheckpointID: sessionID,
            expectedSource: "agent-hook",
            runtimeStatusKey: nil,
            runtimeGeneration: nil,
            agentSessionEnded: true
        ))
        target.clearBinding(retiredBinding, agentSessionEnded: true)

        let runtimeKey = AgentRuntimeSessionKey(
            statusKey: "codex",
            sessionID: sessionID
        ).rawValue
        _ = workspace.recordAgentPID(
            key: runtimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        )
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(runtimeKey) != true)
    }

    @Test
    func staleGeneratedMetadataClearPreservesCurrentBinding() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "generated-metadata-clear"
        let currentGeneration: TimeInterval = 200
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: "/srv/project",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            runtimeGeneration: currentGeneration
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))

        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: manager,
            workspace: workspace,
            surfaceID: panelID
        )
        #expect(target.bindingForClear(
            expectedCheckpointID: sessionID,
            expectedSource: "agent-hook",
            runtimeStatusKey: nil,
            runtimeGeneration: 100,
            agentSessionEnded: false
        ) == nil)
        #expect(target.binding == binding)

        let authorized = try #require(target.bindingForClear(
            expectedCheckpointID: sessionID,
            expectedSource: "agent-hook",
            runtimeStatusKey: nil,
            runtimeGeneration: currentGeneration,
            agentSessionEnded: false
        ))
        #expect(target.clearBinding(authorized, agentSessionEnded: false))
        #expect(target.binding == nil)
    }

    @Test
    func generationOnlyClearCannotConsumeLegacyBinding() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let panelID = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            name: "Manual",
            kind: "codex",
            command: "codex resume legacy-clear",
            cwd: "/srv/project",
            checkpointId: "legacy-clear",
            source: "manual",
            autoResume: false
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))

        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: manager,
            workspace: workspace,
            surfaceID: panelID
        )
        #expect(target.bindingForClear(
            expectedCheckpointID: "legacy-clear",
            expectedSource: "manual",
            runtimeStatusKey: nil,
            runtimeGeneration: 500,
            agentSessionEnded: false
        ) == nil)
        #expect(target.binding == binding)
    }

    @Test
    func controllerRejectsGeneratedClearWithoutMatchingGeneration() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume controller-generation-clear",
            cwd: "/srv/project",
            checkpointId: "controller-generation-clear",
            source: "agent-hook",
            autoResume: true,
            runtimeGeneration: 200
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: surfaceID))

        let result = try v2Result(request: [
            "id": "stale-generated-resume-clear",
            "method": "surface.resume.clear",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
                "runtime_generation": 100,
            ],
        ])

        #expect(result["cleared"] as? Bool == false)
        let returnedBinding = try #require(result["resume_binding"] as? [String: Any])
        #expect(returnedBinding["checkpoint_id"] as? String == binding.checkpointId)
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID) == binding)
    }

    @Test
    func metadataRetiredReplacementClearsRuntimeAndRejectsSupersededPublication() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let agentKind = "acme.agent"
        let makeBinding: (String) -> SurfaceResumeBindingSnapshot = { sessionID in
            SurfaceResumeBindingSnapshot(
                name: agentKind,
                kind: agentKind,
                command: "\(agentKind) resume \(sessionID)",
                cwd: "/srv/project",
                checkpointId: sessionID,
                source: "agent-hook",
                autoResume: true
            )
        }
        let firstSessionID = "live-after-resume-clear-a"
        let firstRuntimeKey = "\(agentKind).\(firstSessionID)"
        let secondSessionID = "live-after-resume-clear-b"
        let secondRuntimeKey = "\(agentKind).\(secondSessionID)"
        let firstBinding = makeBinding(firstSessionID)
        let secondBinding = makeBinding(secondSessionID)

        #expect(workspace.setSurfaceResumeBinding(firstBinding, panelId: panelID))
        #expect(workspace.clearSurfaceResumeBinding(panelId: panelID))
        _ = workspace.recordAgentPID(
            key: firstRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        )
        workspace.statusEntries[agentKind] = SidebarStatusEntry(
            key: agentKind,
            value: "Running"
        )
        workspace.setAgentLifecycle(
            key: agentKind,
            panelId: panelID,
            lifecycle: .running
        )

        #expect(workspace.setSurfaceResumeBinding(secondBinding, panelId: panelID))
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(firstRuntimeKey) != true)
        #expect(workspace.statusEntries[agentKind] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?[agentKind] == nil)
        #expect(workspace.clearSurfaceResumeBinding(panelId: panelID))
        #expect(workspace.recordAgentPID(
            key: secondRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        ))
        workspace.statusEntries[agentKind] = SidebarStatusEntry(
            key: agentKind,
            value: "Running"
        )
        workspace.setAgentLifecycle(
            key: agentKind,
            panelId: panelID,
            lifecycle: .running
        )

        _ = workspace.recordAgentPID(
            key: firstRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        )
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(firstRuntimeKey) != true)
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(secondRuntimeKey) == true)
        #expect(workspace.statusEntries[agentKind]?.value == "Running")
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?[agentKind] == .running)
    }

    @Test
    func metadataClearPreservesPendingReplacementDelivery() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let makeBinding: (String) -> SurfaceResumeBindingSnapshot = { sessionID in
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume \(sessionID)",
                cwd: "/srv/project",
                checkpointId: sessionID,
                source: "agent-hook",
                autoResume: true
            )
        }
        let firstBinding = makeBinding("pending-replacement-a")
        let replacementBinding = makeBinding("pending-replacement-b")

        #expect(workspace.setSurfaceResumeBinding(firstBinding, panelId: panelID))
        #expect(workspace.setSurfaceResumeBinding(replacementBinding, panelId: panelID))
        #expect(workspace.clearSurfaceResumeBinding(
            panelId: panelID,
            binding: firstBinding,
            agentSessionEnded: true
        ))
        #expect(workspace.clearSurfaceResumeBinding(panelId: panelID))

        let replacementRuntimeKey = AgentRuntimeSessionKey(
            statusKey: "codex",
            sessionID: "pending-replacement-b"
        ).rawValue
        #expect(workspace.recordAgentPID(
            key: replacementRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        ))
    }

    @Test
    func customPersistentSSHAgentRuntimeEndsWithItsPrompt() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let configuration = remoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let panelID = try #require(workspace.focusedPanelId)
        workspace.trackRemoteTerminalSurface(panelID)
        let authority = try #require(WorkspaceRemoteTerminalAuthority(configuration: configuration))
        #expect(workspace.markRemoteTerminalSessionConnected(
            surfaceId: panelID,
            authority: authority
        ))

        let remotePTYSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: workspace.id,
            panelId: panelID
        )
        workspace.remotePTYSessionIDsByPanelId[panelID] = remotePTYSessionID
        let agentKind = "acme.agent"
        let initialSessionID = "remote-session-a"
        let initialRuntimeKey = "\(agentKind).\(initialSessionID)"
        let unrelatedRuntimeKey = "remote-build-helper"
        let agentStatus = SidebarStatusEntry(
            key: agentKind,
            value: "Running",
            icon: "bolt.fill",
            color: nil,
            timestamp: .distantPast
        )
        let makeBinding: (String) -> SurfaceResumeBindingSnapshot = { sessionID in
            SurfaceResumeBindingSnapshot(
                name: "Acme Agent",
                kind: agentKind,
                command: "acme-agent resume \(sessionID)",
                cwd: "/srv/project",
                checkpointId: sessionID,
                source: "agent-hook",
                autoResume: true,
                launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                    workspaceID: workspace.id,
                    surfaceID: panelID,
                    persistentPTYSessionID: remotePTYSessionID
                ))
            )
        }
        #expect(workspace.setSurfaceResumeBinding(makeBinding(initialSessionID), panelId: panelID))
        workspace.recordAgentPID(
            key: initialRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        )
        workspace.recordAgentPID(
            key: unrelatedRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        )
        workspace.statusEntries[agentKind] = agentStatus
        workspace.setAgentLifecycle(key: agentKind, panelId: panelID, lifecycle: .running)

        // A same-kind replacement must consume the prior exact-session key;
        // remote PID values cannot age it out through the local process table.
        let replacementSessionID = "remote-session-b"
        #expect(workspace.setSurfaceResumeBinding(makeBinding(replacementSessionID), panelId: panelID))
        #expect(
            workspace.agentPIDKeysByPanelId[panelID]?.contains(initialRuntimeKey) == false
        )

        // A replacement also retires status/lifecycle-only state when no PID
        // key was published for the superseded session.
        workspace.statusEntries[agentKind] = agentStatus
        workspace.setAgentLifecycle(key: agentKind, panelId: panelID, lifecycle: .running)
        let activeSessionID = "remote-session-c"
        let activeRuntimeKey = "\(agentKind).\(activeSessionID)"
        #expect(workspace.setSurfaceResumeBinding(makeBinding(activeSessionID), panelId: panelID))
        #expect(workspace.statusEntries[agentKind] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?[agentKind] == nil)
        #expect(workspace.recordAgentPID(
            key: activeRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        ))
        workspace.statusEntries[agentKind] = agentStatus
        workspace.setAgentLifecycle(key: agentKind, panelId: panelID, lifecycle: .running)

        // A delayed PID event for session A cannot replace authoritative
        // session C merely because both share the same custom-agent kind.
        #expect(!workspace.recordAgentPID(
            key: initialRuntimeKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        ))
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(initialRuntimeKey) == false)
        let unknownStructuredKey = AgentRuntimeSessionKey(
            statusKey: agentKind,
            sessionID: "remote-session-unknown"
        ).rawValue
        #expect(!workspace.recordAgentPID(
            key: unknownStructuredKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        ))
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(unknownStructuredKey) == false)
        let otherKindStructuredKey = AgentRuntimeSessionKey(
            statusKey: "codex",
            sessionID: "other-agent-session"
        ).rawValue
        #expect(!workspace.recordAgentPID(
            key: otherKindStructuredKey,
            pid: .max,
            panelId: panelID,
            refreshPorts: false
        ))
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(otherKindStructuredKey) == false)
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(activeRuntimeKey) == true)
        #expect(workspace.statusEntries[agentKind] == agentStatus)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?[agentKind] == .running)
        #expect(!workspace.clearAgentPID(
            key: initialRuntimeKey,
            panelId: panelID,
            clearStatus: true,
            refreshPorts: false
        ))
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(initialRuntimeKey) == false)
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(activeRuntimeKey) == true)
        #expect(workspace.statusEntries[agentKind] == agentStatus)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?[agentKind] == .running)
        workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        #expect(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == panelID }?.terminal?.wasAgentRunning == true
        )

        workspace.updatePanelShellActivityState(panelId: panelID, state: .promptIdle)

        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(activeRuntimeKey) == false)
        #expect(workspace.agentPIDKeysByPanelId[panelID]?.contains(unrelatedRuntimeKey) == true)
        #expect(workspace.statusEntries[agentKind] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?[agentKind] == nil)

        // A later unrelated command must not revive the ended custom agent
        // from an exact-session runtime key left behind by prompt cleanup.
        workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        #expect(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == panelID }?.terminal?.wasAgentRunning == false
        )
    }

    @Test
    func mismatchedRemoteBindingNeverFallsBackToLocalExecution() throws {
        let fixture = try makeRelayedFixture()
        let mismatchedSnapshot = try snapshotByReplacingRemoteContext(
            fixture.snapshot,
            persistentPTYSessionID: "different-persistent-session"
        )
        let suiteName = "cmux-mismatched-remote-resume-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let socketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(socketPath) }

        let restoredWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let restoredIDs = restoredWorkspace.restoreSessionSnapshot(mismatchedSnapshot)
        let restoredSurfaceID = try #require(restoredIDs[fixture.surfaceID])
        let restoredPanel = try #require(restoredWorkspace.terminalPanel(for: restoredSurfaceID))
        let startupCommand = try #require(restoredPanel.surface.debugInitialCommand())

        #expect(startupCommand.contains("ssh-pty-attach"), "\(startupCommand)")
        #expect(startupCommand.contains("--require-existing"), "\(startupCommand)")
        #expect(restoredPanel.surface.debugInitialInputForTesting() == nil)
        #expect(!startupCommand.contains("--command-b64"), "\(startupCommand)")
        #expect(!startupCommand.contains("session-remote-7989"), "\(startupCommand)")
        #expect(!startupCommand.contains("REMOTE_FLAG"), "\(startupCommand)")
    }

    @Test
    func legacyRemoteSnapshotWithoutWorkspaceIDMigratesBindingIntoPersistentSSHContext() throws {
        let fixture = try makeRelayedFixture()
        let legacySnapshot = try snapshotWithoutLaunchFlavorOrWorkspaceID(fixture.snapshot)
        let suiteName = "cmux-legacy-remote-resume-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let socketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(socketPath) }

        let restoredWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let restoredIDs = restoredWorkspace.restoreSessionSnapshot(legacySnapshot)
        let restoredSurfaceID = try #require(restoredIDs[fixture.surfaceID])
        let startupCommand = try #require(
            restoredWorkspace.terminalPanel(for: restoredSurfaceID)?.surface.debugInitialCommand()
        )
        let remoteCommand = try decodedRemoteCommand(from: startupCommand)
        try expectRemoteResumeBootstrap(remoteCommand)

        let roundTripBinding = try #require(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredSurfaceID }?.terminal?.resumeBinding
        )
        guard case .persistentSSH(let context) = roundTripBinding.launchFlavor else {
            Issue.record("Legacy remote binding was not migrated to persistent SSH")
            return
        }
        #expect(context.workspaceID == restoredWorkspace.id)
        #expect(context.surfaceID == restoredSurfaceID)
        #expect(context.persistentPTYSessionID == fixture.remotePTYSessionID)
    }

    @Test
    func legacyBindingMigrationStopsAtPersistentSSHOwnershipBoundaries() throws {
        let binding = try legacyLocalBinding()
        #expect(binding.wasDecodedWithoutLaunchFlavor)
        let snapshotWorkspaceID = UUID()
        let snapshotSurfaceID = UUID()
        let sessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: snapshotWorkspaceID,
            panelId: snapshotSurfaceID
        )

        let localWorkspace = Workspace()
        let nonPersistentSSH = Workspace()
        nonPersistentSSH.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false, persistentDaemonSlot: nil),
            autoConnect: false
        )
        let missingDaemonSlot = Workspace()
        missingDaemonSlot.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: true, persistentDaemonSlot: nil),
            autoConnect: false
        )
        let freestyleBakedDaemon = Workspace()
        freestyleBakedDaemon.configureRemoteConnection(
            remoteConfiguration(skipDaemonBootstrap: true),
            autoConnect: false
        )
        let websocketCloud = Workspace()
        websocketCloud.configureRemoteConnection(
            remoteConfiguration(transport: .websocket),
            autoConnect: false
        )
        let moshTerminal = Workspace()
        moshTerminal.configureRemoteConnection(
            remoteConfiguration(terminalTransport: .mosh),
            autoConnect: false
        )
        let eligiblePersistentSSH = Workspace()
        eligiblePersistentSSH.configureRemoteConnection(remoteConfiguration(), autoConnect: false)

        let cases: [(name: String, workspace: Workspace, sessionID: String?, restoresRemoteTerminal: Bool)] = [
            ("local workspace", localWorkspace, sessionID, true),
            ("non-persistent SSH", nonPersistentSSH, sessionID, true),
            ("missing daemon slot", missingDaemonSlot, sessionID, true),
            ("Freestyle baked daemon", freestyleBakedDaemon, sessionID, true),
            ("WebSocket Cloud VM", websocketCloud, sessionID, true),
            ("Mosh terminal", moshTerminal, sessionID, true),
            ("local terminal inside persistent SSH workspace", eligiblePersistentSSH, sessionID, false),
            ("missing persistent PTY", eligiblePersistentSSH, nil, true),
            ("blank persistent PTY", eligiblePersistentSSH, " \t\n ", true),
        ]

        for item in cases {
            let migrated = item.workspace.migratingLegacyPersistentSSHResumeBinding(
                binding,
                snapshotWorkspaceID: snapshotWorkspaceID,
                snapshotSurfaceID: snapshotSurfaceID,
                persistentPTYSessionID: item.sessionID,
                restoresRemoteTerminal: item.restoresRemoteTerminal
            )
            #expect(migrated?.launchFlavor == .local, Comment(rawValue: item.name))
        }
    }

    private func makeRelayedFixture(
        verifyingPromptSelectiveRuntimeCleanup: Bool = false
    ) throws -> (
        snapshot: SessionWorkspaceSnapshot,
        workspaceID: UUID,
        surfaceID: UUID,
        remotePTYSessionID: String,
        localBinding: [String: Any],
        spoofedRelayRegistrationRejected: Bool,
        remoteBinding: [String: Any]
    ) {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        let notificationStore = TerminalNotificationStore.shared
        let previousNotificationStore = app.notificationStore
        let previousNotifications = notificationStore.notifications
        defer {
            notificationStore.replaceNotificationsForTesting(previousNotifications)
            app.notificationStore = previousNotificationStore
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let configuration = remoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.trackRemoteTerminalSurface(surfaceID)
        let remoteAuthority = try #require(
            WorkspaceRemoteTerminalAuthority(configuration: configuration)
        )
        #expect(workspace.markRemoteTerminalSessionConnected(
            surfaceId: surfaceID,
            authority: remoteAuthority
        ))

        let localResult = try v2Result(
            request: [
                "id": "local-resume-set",
                "method": "surface.resume.set",
                "params": remoteResumeParams(
                    workspaceID: workspace.id,
                    surfaceID: surfaceID,
                    command: "codex resume local-session"
                ),
            ]
        )
        let localBinding = try #require(localResult["resume_binding"] as? [String: Any])

        var spoofedParams = remoteResumeParams(
            workspaceID: workspace.id,
            surfaceID: surfaceID,
            command: "codex resume forged-local-request"
        )
        spoofedParams["_cmux_remote_workspace_id"] = workspace.id.uuidString
        spoofedParams["_cmux_remote_relay_authentication_code"] = String(repeating: "0", count: 64)
        let spoofedEnvelope = try v2Envelope(request: [
            "id": "spoofed-relay-resume-set",
            "method": "surface.resume.set",
            "params": spoofedParams,
        ])
        let bindingAfterSpoof = try v2Result(request: [
            "id": "resume-get-after-spoof",
            "method": "surface.resume.get",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])["resume_binding"] as? [String: Any]
        let spoofedRelayRegistrationRejected = spoofedEnvelope["ok"] as? Bool == false
            && (bindingAfterSpoof?["command"] as? String) == (localBinding["command"] as? String)

        let staleWorkspaceID = UUID()
        let staleSurfaceID = UUID()
        let remotePTYSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: staleWorkspaceID,
            panelId: staleSurfaceID
        )
        workspace.remotePTYSessionIDsByPanelId[surfaceID] = remotePTYSessionID
        workspace.registerRemoteRelayIDAliases(
            remotePTYSessionID: remotePTYSessionID,
            restoredPanelId: surfaceID
        )

        let relayedRequest: [String: Any] = [
            "id": "relayed-resume-set",
            "method": "surface.resume.set",
            "params": remoteResumeParams(
                workspaceID: staleWorkspaceID,
                surfaceID: staleSurfaceID,
                command: "cd '/srv/remote project' && '/home/dev/.nvm/versions/node/v24/bin/codex' resume session-remote-7989"
            ),
        ]
        var relayedData = try JSONSerialization.data(withJSONObject: relayedRequest)
        relayedData.append(0x0A)
        let rewrittenData = workspace.rewriteRemoteRelayCommandLine(relayedData)
        let remoteResult = try v2Result(requestData: rewrittenData)
        let remoteBinding = try #require(remoteResult["resume_binding"] as? [String: Any])

        // An authenticated binding and live persistent PTY are ownership, not
        // liveness. The app must also observe the shell running and the exact
        // session-scoped hook runtime key before persisting an automatic restart.
        #expect(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == surfaceID }?.terminal?.wasAgentRunning == false
        )
        workspace.updatePanelShellActivityState(
            panelId: surfaceID,
            state: .commandRunning
        )
        #expect(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == surfaceID }?.terminal?.wasAgentRunning == false
        )
        workspace.setAgentLifecycle(
            key: "codex",
            panelId: surfaceID,
            lifecycle: .running
        )
        #expect(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == surfaceID }?.terminal?.wasAgentRunning == false
        )
        workspace.setAgentLifecycle(
            key: "codex",
            panelId: surfaceID,
            lifecycle: .unknown
        )
        let remoteRuntimeKey = "codex.session-remote-7989"
        workspace.recordAgentPID(
            key: remoteRuntimeKey,
            pid: .max,
            panelId: surfaceID,
            refreshPorts: false
        )

        // A remote hook PID belongs to the SSH host. The periodic local PID
        // sweep must preserve its exact-session ownership key until the remote
        // prompt or terminal lifecycle authoritatively consumes it.
        #expect(!workspace.clearStaleAgentPIDs(refreshPorts: false))
        #expect(workspace.agentPIDKeysByPanelId[surfaceID]?.contains(remoteRuntimeKey) == true)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(
            snapshot.panels.first { $0.id == surfaceID }?.terminal?.wasAgentRunning == true
        )

        let unrelatedRuntimeKey = "remote-build-helper"
        let unrelatedLifecycleKey = "remote-build-lifecycle"
        let unrelatedStatusKey = "remote-build-status"
        let unrelatedStatus = SidebarStatusEntry(
            key: unrelatedStatusKey,
            value: "Building",
            icon: "hammer.fill",
            color: nil,
            timestamp: .distantPast
        )
        if verifyingPromptSelectiveRuntimeCleanup {
            workspace.recordAgentPID(
                key: unrelatedRuntimeKey,
                pid: .max,
                panelId: surfaceID,
                refreshPorts: false
            )
            workspace.setAgentLifecycle(
                key: unrelatedLifecycleKey,
                panelId: surfaceID,
                lifecycle: .running
            )
            workspace.statusEntries[unrelatedStatusKey] = unrelatedStatus
            app.notificationStore = notificationStore
            notificationStore.replaceNotificationsForTesting([
                TerminalNotification(
                    id: UUID(),
                    tabId: workspace.id,
                    surfaceId: surfaceID,
                    title: "Remote agent",
                    subtitle: "",
                    body: "Needs input",
                    createdAt: Date(),
                    isRead: false
                ),
            ])
            #expect(notificationStore.hasUnreadNotification(
                forTabId: workspace.id,
                surfaceId: surfaceID
            ))
        }

        // SessionEnd can consume its hook record while surface.resume.clear
        // fails. Keep the binding armed to model that failure and prove the
        // later prompt callback prevents a dead agent from being auto-resumed.
        workspace.updatePanelShellActivityState(panelId: surfaceID, state: .promptIdle)
        if verifyingPromptSelectiveRuntimeCleanup {
            #expect(notificationStore.hasUnreadNotification(
                forTabId: workspace.id,
                surfaceId: surfaceID
            ))
            #expect(workspace.agentPIDKeysByPanelId[surfaceID]?.contains(remoteRuntimeKey) == false)
            #expect(workspace.agentPIDKeysByPanelId[surfaceID]?.contains(unrelatedRuntimeKey) == true)
            #expect(
                workspace.agentLifecycleStatesByPanelId[surfaceID]?[unrelatedLifecycleKey] == .running
            )
            #expect(workspace.statusEntries[unrelatedStatusKey] == unrelatedStatus)
        }
        let promptSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        let promptTerminal = try #require(
            promptSnapshot.panels.first { $0.id == surfaceID }?.terminal
        )
        #expect(promptTerminal.resumeBinding?.autoResume == true)
        #expect(promptTerminal.wasAgentRunning == false)

        // A later unrelated command plus a kind-only lifecycle write (for
        // example Feed attention) cannot revive the consumed session key.
        workspace.setAgentLifecycle(
            key: "codex",
            panelId: surfaceID,
            lifecycle: .running
        )
        workspace.updatePanelShellActivityState(
            panelId: surfaceID,
            state: .commandRunning
        )
        #expect(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == surfaceID }?.terminal?.wasAgentRunning == false
        )

        return (
            snapshot,
            workspace.id,
            surfaceID,
            remotePTYSessionID,
            localBinding,
            spoofedRelayRegistrationRejected,
            remoteBinding
        )
    }

    private func remoteConfiguration(
        transport: WorkspaceRemoteTransport = .ssh,
        terminalTransport: WorkspaceRemoteTerminalTransport = .ssh,
        preserveAfterTerminalExit: Bool = true,
        persistentDaemonSlot: String? = "ssh-issue-7989",
        skipDaemonBootstrap: Bool = false
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            transport: transport,
            terminalTransport: terminalTransport,
            destination: "dev@example.com",
            port: 22,
            identityFile: nil,
            sshOptions: ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: "relay-issue-7989",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-issue-7989.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(requireExisting: false),
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot,
            skipDaemonBootstrap: skipDaemonBootstrap
        )
    }

    private func remoteResumeParams(
        workspaceID: UUID,
        surfaceID: UUID,
        command: String
    ) -> [String: Any] {
        [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "name": "Codex",
            "kind": "codex",
            "checkpoint_id": "session-remote-7989",
            "source": "agent-hook",
            "command": command,
            "cwd": "/srv/remote project",
            "environment": [
                "REMOTE_FLAG": "value with spaces",
                "ANTHROPIC_API_KEY": "must-not-persist",
            ],
            "auto_resume": true,
        ]
    }

    private func requestData(_ request: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        return data
    }

    private func jsonRequest(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func v2Result(request: [String: Any]) throws -> [String: Any] {
        let envelope = try v2Envelope(request: request)
        #expect(envelope["ok"] as? Bool == true, "\(envelope)")
        return try #require(envelope["result"] as? [String: Any])
    }

    private func v2Envelope(request: [String: Any]) throws -> [String: Any] {
        try v2Envelope(requestData: requestData(request))
    }

    private func v2Envelope(requestData: Data) throws -> [String: Any] {
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let response = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(response.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func v2Result(requestData: Data) throws -> [String: Any] {
        let envelope = try v2Envelope(requestData: requestData)
        #expect(envelope["ok"] as? Bool == true, "\(envelope)")
        return try #require(envelope["result"] as? [String: Any])
    }

    private func decodedRemoteCommand(from startupCommand: String) throws -> String {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(startupCommand).map(\.value)
        let script = try #require(words.dropFirst(2).first)
        let range = try #require(
            script.range(of: #"--command-b64 [A-Za-z0-9+/=]+"#, options: .regularExpression)
        )
        let encoded = String(script[range]).split(separator: " ", maxSplits: 1).last.map(String.init)
        let data = try #require(encoded.flatMap { Data(base64Encoded: $0) })
        return try #require(String(data: data, encoding: .utf8))
    }

    private func snapshotWithoutLaunchFlavorOrWorkspaceID(
        _ snapshot: SessionWorkspaceSnapshot
    ) throws -> SessionWorkspaceSnapshot {
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "workspaceId")
        var panels = try #require(object["panels"] as? [[String: Any]])
        let panelIndex = try #require(panels.firstIndex { $0["terminal"] != nil })
        var panel = panels[panelIndex]
        var terminal = try #require(panel["terminal"] as? [String: Any])
        var binding = try #require(terminal["resumeBinding"] as? [String: Any])
        binding.removeValue(forKey: "launchFlavor")
        terminal["resumeBinding"] = binding
        panel["terminal"] = terminal
        panels[panelIndex] = panel
        object["panels"] = panels
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: legacyData)
    }

    private func snapshotByReplacingRemoteContext(
        _ snapshot: SessionWorkspaceSnapshot,
        persistentPTYSessionID: String
    ) throws -> SessionWorkspaceSnapshot {
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var panels = try #require(object["panels"] as? [[String: Any]])
        let panelIndex = try #require(panels.firstIndex { $0["terminal"] != nil })
        var panel = panels[panelIndex]
        var terminal = try #require(panel["terminal"] as? [String: Any])
        var binding = try #require(terminal["resumeBinding"] as? [String: Any])
        var launchFlavor = try #require(binding["launchFlavor"] as? [String: Any])
        var remoteContext = try #require(launchFlavor["remoteContext"] as? [String: Any])
        remoteContext["persistentPTYSessionID"] = persistentPTYSessionID
        launchFlavor["remoteContext"] = remoteContext
        binding["launchFlavor"] = launchFlavor
        terminal["resumeBinding"] = binding
        panel["terminal"] = terminal
        panels[panelIndex] = panel
        object["panels"] = panels
        return try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func legacyLocalBinding() throws -> SurfaceResumeBindingSnapshot {
        let object: [String: Any] = [
            "name": "Codex",
            "kind": "codex",
            "command": "codex resume legacy-session",
            "cwd": "/tmp/legacy-project",
            "checkpointId": "legacy-session",
            "source": "agent-hook",
            "autoResume": true,
            "updatedAt": 10.0,
        ]
        return try JSONDecoder().decode(
            SurfaceResumeBindingSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func expectRemoteResumeBootstrap(_ command: String) throws {
        #expect(command.contains("export CMUX_SOCKET_PATH=127.0.0.1:\(relayPort)"), "\(command)")
        #expect(command.contains("__CMUX_WORKSPACE_ID__"), "\(command)")
        #expect(command.contains("__CMUX_SURFACE_ID__"), "\(command)")
        let initialCommand = try decodedInitialCommand(from: command)
        #expect(initialCommand.contains("/srv/remote project"), "\(initialCommand)")
        #expect(initialCommand.contains("REMOTE_FLAG=value with spaces"), "\(initialCommand)")
        #expect(initialCommand.contains("session-remote-7989"), "\(initialCommand)")
        #expect(!initialCommand.contains("ANTHROPIC_API_KEY"), "\(initialCommand)")
    }

    private func decodedInitialCommand(from bootstrap: String) throws -> String {
        let payloadLine = try #require(bootstrap.split(separator: "\n").first { line in
            line.contains("printf %s '") && line.contains("> \"$cmux_initial_command_tmp\"")
        })
        let prefixRange = try #require(payloadLine.range(of: "printf %s '"))
        let encodedSuffix = payloadLine[prefixRange.upperBound...]
        let closingQuote = try #require(encodedSuffix.firstIndex(of: "'"))
        let encodedCommand = String(encodedSuffix[..<closingQuote])
        let data = try #require(Data(base64Encoded: encodedCommand))
        return try #require(String(data: data, encoding: .utf8))
    }

    private func runBundledKiroSessionStart(
        workspaceID: UUID,
        surfaceID: UUID
    ) throws -> HookRunResult {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-remote-kiro-hook-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("remote project", isDirectory: true)
        let socketPath = "/tmp/rb-\(UUID().uuidString.prefix(8)).sock"
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let listenerFD = try bindHookSocket(at: socketPath)
        let capture = RemoteResumeHookCapture()
        let serverFinished = RemoteResumeHookSocketServer.start(
            listenerFD: listenerFD,
            capture: capture,
            surfaceID: surfaceID
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? fileManager.removeItem(at: root)
        }

        let executable = "/Users/example/.cargo/bin/kiro-cli"
        let launchArguments = [
            executable,
            "chat",
            "--agent",
            "cmux",
            "--trust-tools",
            "fs_read,fs_write",
        ]
        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": workingDirectory.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceID.uuidString,
            "CMUX_SURFACE_ID": surfaceID.uuidString,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_LAUNCH_KIND": "kiro",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": executable,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(launchArguments),
            "CMUX_AGENT_LAUNCH_CWD": workingDirectory.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        let inputObject: [String: Any] = [
            "session_id": "kiro-remote-session",
            "cwd": workingDirectory.path,
            "hook_event_name": "SessionStart",
        ]
        let input = String(
            decoding: try JSONSerialization.data(withJSONObject: inputObject),
            as: UTF8.self
        )
        let processResult = runHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "kiro", "session-start"],
            environment: environment,
            standardInput: input,
            timeout: 5
        )
        _ = serverFinished.wait(timeout: .now() + 5)
        return HookRunResult(
            status: processResult.status,
            stderr: processResult.stderr,
            timedOut: processResult.timedOut,
            commands: capture.snapshot()
        )
    }

    private func bindHookSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < pathCapacity else {
            Darwin.close(fileDescriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { buffer in
                for index in pathBytes.indices {
                    buffer[index] = CChar(bitPattern: pathBytes[index])
                }
                buffer[pathBytes.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    fileDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(fileDescriptor, 1) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(fileDescriptor)
            throw error
        }
        return fileDescriptor
    }

    private func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func runHookProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String,
        timeout: TimeInterval
    ) -> (status: Int32, stderr: String, timedOut: Bool) {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return (-1, String(describing: error), false)
        }
        inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try? inputPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
        }
        process.waitUntilExit()
        _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return (process.terminationStatus, stderr, timedOut)
    }

    private func reserveRemoteRestoreSocket() -> String {
        TerminalController.shared.stop()
        let requestedPath = "/tmp/cmux-remote-resume-\(UUID().uuidString).sock"
        return TerminalController.shared.reserveStartupSocketPath(requestedPath)
    }

    private func cleanupRemoteRestoreSocket(_ path: String) {
        TerminalController.shared.stop()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".lock")
    }

    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }
}
