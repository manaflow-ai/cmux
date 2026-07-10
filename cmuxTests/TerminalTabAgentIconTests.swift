import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct TerminalTabAgentIconTests {
    private func liveAgent(
        _ statusKey: String,
        startSeconds: Int64? = nil,
        startMicroseconds: Int64 = 0
    ) -> TerminalTabAgentIconResolver.LiveAgent {
        TerminalTabAgentIconResolver.LiveAgent(
            statusKey: statusKey,
            processStart: startSeconds.map {
                AgentPIDProcessIdentity(pid: 100, startSeconds: $0, startMicroseconds: startMicroseconds)
            }
        )
    }

    @Test(arguments: [
        ("claude_code", "AgentIcons/Claude"),
        ("codex", "AgentIcons/Codex"),
        ("opencode", "AgentIcons/OpenCode"),
        ("pi", "AgentIcons/Pi"),
        ("omp", "AgentIcons/Pi"),
        ("grok", "AgentIcons/Grok"),
        ("rovodev", "AgentIcons/RovoDev"),
        ("antigravity", "AgentIcons/Antigravity"),
        ("hermes-agent", "AgentIcons/HermesAgent"),
    ])
    func liveStatusKeyMapsToAsset(statusKey: String, expectedAsset: String) {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent(statusKey)],
            restoredAgent: nil
        )

        #expect(asset == expectedAsset)
    }

    @Test(arguments: [
        "amp",
        "gemini",
        "cursor",
        "copilot",
        "codebuddy",
        "factory",
        "kiro",
        "qoder",
    ])
    func unsupportedAgentsUseSystemTerminalIcon(statusKey: String) {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent(statusKey)],
            restoredAgent: nil
        )

        #expect(asset == nil)
    }

    @Test func restoredAgentIsUsedWhenNoLiveAgentHasBrandAsset() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("amp")],
            restoredAgent: .init(kind: "codex", registrationIconAssetName: nil)
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func liveAgentWinsOverRestoredAgent() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("opencode")],
            restoredAgent: .init(kind: "codex", registrationIconAssetName: nil)
        )

        #expect(asset == "AgentIcons/OpenCode")
    }

    @Test func newestLiveAgentProcessWinsRegardlessOfKeyOrder() {
        // "grok" sorts after "codex" alphabetically but started later, so the
        // tab shows the agent the user launched most recently.
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [
                liveAgent("codex", startSeconds: 1_000),
                liveAgent("grok", startSeconds: 2_000),
            ],
            restoredAgent: nil
        )

        #expect(asset == "AgentIcons/Grok")
    }

    @Test func processStartMicrosecondsBreakSameSecondTies() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [
                liveAgent("grok", startSeconds: 1_000, startMicroseconds: 10),
                liveAgent("codex", startSeconds: 1_000, startMicroseconds: 20),
            ],
            restoredAgent: nil
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func agentWithRecordedStartWinsOverAgentWithoutOne() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [
                liveAgent("claude_code"),
                liveAgent("rovodev", startSeconds: 1),
            ],
            restoredAgent: nil
        )

        #expect(asset == "AgentIcons/RovoDev")
    }

    @Test func agentsWithoutRecordedStartsFallBackToDeterministicKeyOrder() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("grok"), liveAgent("codex")],
            restoredAgent: nil
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func rawAgentPIDKeysAreNormalizedBeforeResolvingAssets() {
        let asset = TerminalTabAgentIconResolver().assetName(
            agentPIDKeys: ["codex.12345"],
            restoredAgent: nil
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func rawAgentPIDKeyIdentitiesOrderConcurrentAgentsByRecency() {
        let asset = TerminalTabAgentIconResolver().assetName(
            agentPIDKeys: ["codex.101", "grok.102"],
            processIdentities: [
                "codex.101": AgentPIDProcessIdentity(pid: 101, startSeconds: 5, startMicroseconds: 0),
                "grok.102": AgentPIDProcessIdentity(pid: 102, startSeconds: 9, startMicroseconds: 0),
            ],
            restoredAgent: nil
        )

        #expect(asset == "AgentIcons/Grok")
    }

    @Test func dottedRegisteredAgentIdsAreNotTruncatedToAWrongBuiltInBrand() {
        // "claude.wrapper" is a legal vault registration id. Without the
        // known-status-key exact match it would truncate to "claude" and show
        // the wrong brand mark.
        let asset = TerminalTabAgentIconResolver().assetName(
            agentPIDKeys: ["claude.wrapper"],
            knownStatusKeys: ["claude.wrapper"],
            restoredAgent: nil
        )

        #expect(asset == nil)
    }

    @Test(arguments: [
        ("claude", "claude"),
        ("codex --yolo", "codex"),
        ("opencode", "opencode"),
        ("pi", "pi"),
        ("omp", "omp"),
        ("claude --resume", "claude"),
    ])
    func terminalTitleClassifierRecognizesFirstExecutableToken(title: String, expectedStatusKey: String) {
        let statusKey = TerminalTabAgentIconResolver().titleDerivedStatusKey(title: title)

        #expect(statusKey == expectedStatusKey)
    }

    @Test(arguments: [
        "vim claude-notes.md",
        "~/fun/claude",
        "lawrence@host:~/fun",
        "/usr/bin/codex",
        "",
    ])
    func terminalTitleClassifierRejectsNonExecutableTitles(title: String) {
        let statusKey = TerminalTabAgentIconResolver().titleDerivedStatusKey(title: title)

        #expect(statusKey == nil)
    }

    @Test func hookDerivedLiveAgentWinsOverTitleDerivedAgent() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("opencode")],
            titleDerivedStatusKey: "codex",
            restoredAgent: .init(kind: "grok", registrationIconAssetName: nil)
        )

        #expect(asset == "AgentIcons/OpenCode")
    }

    @Test func titleDerivedAgentWinsOverRestoredAgent() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [],
            titleDerivedStatusKey: "codex",
            restoredAgent: .init(kind: "grok", registrationIconAssetName: nil)
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @MainActor
    @Test(arguments: [
        ("claude", "AgentIcons/Claude"), ("codex", "AgentIcons/Codex"),
        ("opencode", "AgentIcons/OpenCode"), ("pi", "AgentIcons/Pi"),
    ])
    func promptIdleTitleDoesNotBecomeAgentIdentity(title: String, expectedAsset: String) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        #expect(workspace.updatePanelTitle(panelId: panel.id, title: title))
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == nil)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == nil)
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == expectedAsset)
        let runningPayload = workspace.terminalTabAgentIconPayload(forPanelId: panel.id)
        #expect(workspace.bonsplitController.tab(tabId)?.iconImageData == runningPayload.imageData)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == runningPayload.assetName)
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == nil)
        #expect(workspace.bonsplitController.tab(tabId)?.iconImageData == nil)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == nil)
    }

    @MainActor
    @Test func terminalTitleChangeReplacesStaleClaudeRuntimeIconWithCodex() throws {
        try assertStaleAgentIconTransition(
            stalePIDKey: "claude_code.old-session",
            staleAsset: "AgentIcons/Claude",
            title: "codex --yolo",
            expectedAsset: "AgentIcons/Codex"
        )
    }

    @MainActor
    @Test func terminalTitleChangeReplacesStaleCodexRuntimeIconWithClaude() throws {
        try assertStaleAgentIconTransition(
            stalePIDKey: "codex.old-session",
            staleAsset: "AgentIcons/Codex",
            title: "claude --resume",
            expectedAsset: "AgentIcons/Claude"
        )
    }

    @MainActor
    @Test func terminalTitleChangeClearsStaleAgentRuntimeIconForPlainShell() throws {
        try assertStaleAgentIconTransition(
            stalePIDKey: "claude_code.old-session",
            staleAsset: "AgentIcons/Claude",
            title: "zsh",
            expectedAsset: nil
        )
    }

    @MainActor
    @Test(arguments: [
        (RestorableAgentKind.claude, "AgentIcons/Claude"), (RestorableAgentKind.codex, "AgentIcons/Codex"),
    ])
    func plainShellTitleClearsObservedRestoredAgentIcon(kind: RestorableAgentKind, expectedAsset: String) throws {
        try assertPlainShellTitleClearsObservedRestoredAgentIcon(
            kind: kind,
            expectedAsset: expectedAsset
        )
    }

    @MainActor
    @Test(arguments: [false, true])
    func plainShellTitleKeepsAutoResumeRestoredAgentIcon(willRunStartupCommand: Bool) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let snapshot = restoredAgentSnapshot(kind: .claude)
        let expectedState: Workspace.RestoredAgentResumeState = willRunStartupCommand
            ? .autoResumeCommandRunning
            : .awaitingAutoResumeCommand

        workspace.seedSessionRestoredAgentIconState(
            panelId: panel.id,
            restorableAgent: snapshot,
            willRunStartupCommand: willRunStartupCommand,
            willRunStartupInput: !willRunStartupCommand
        )

        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == expectedState)
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == "AgentIcons/Claude")
        let pendingPayload = workspace.terminalTabAgentIconPayload(forPanelId: panel.id)
        #expect(workspace.bonsplitController.tab(tabId)?.iconImageData == pendingPayload.imageData)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == pendingPayload.assetName)

        #expect(workspace.updatePanelTitle(panelId: panel.id, title: "~/manaflow/cmuxterm-hq"))

        #expect(workspace.restoredAgentSnapshotForTesting(panelId: panel.id)?.sessionId == snapshot.sessionId)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == expectedState)
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == "AgentIcons/Claude")
        let retainedPayload = workspace.terminalTabAgentIconPayload(forPanelId: panel.id)
        #expect(workspace.bonsplitController.tab(tabId)?.iconImageData == retainedPayload.imageData)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == retainedPayload.assetName)
    }

    @Test func liveRegisteredAgentResolvesThroughRegistrationLookup() {
        var lookedUpKeys: [String] = []
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("my-custom-agent")],
            restoredAgent: nil,
            registrationIconAssetName: { key in
                lookedUpKeys.append(key)
                return key == "my-custom-agent" ? "AgentIcons/Pi" : nil
            }
        )

        #expect(asset == "AgentIcons/Pi")
        #expect(lookedUpKeys == ["my-custom-agent"])
    }

    @Test func liveRegistrationIconOverridesBuiltInBrand() {
        // Registry semantics: config registrations can override built-in
        // agents, so the registration icon wins over the hard-coded switch.
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("pi")],
            restoredAgent: nil,
            registrationIconAssetName: { key in
                key == "pi" ? "AgentIcons/Grok" : nil
            }
        )

        #expect(asset == "AgentIcons/Grok")
    }

    @Test func builtInBrandStillResolvesWhenRegistrationLookupMisses() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("codex")],
            restoredAgent: nil,
            registrationIconAssetName: { _ in nil }
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func restoredRegisteredAgentPrefersRegistrationIconOverBuiltInSwitch() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [],
            restoredAgent: .init(kind: "pi", registrationIconAssetName: "AgentIcons/Grok")
        )

        #expect(asset == "AgentIcons/Grok")
    }

    @Test func restoredCustomRegisteredAgentUsesRegistrationIcon() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [],
            restoredAgent: .init(kind: "my-custom-agent", registrationIconAssetName: "AgentIcons/HermesAgent")
        )

        #expect(asset == "AgentIcons/HermesAgent")
    }

    @MainActor
    private func assertStaleAgentIconTransition(
        stalePIDKey: String,
        staleAsset: String,
        title: String,
        expectedAsset: String?
    ) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let notificationStore = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let previousNotificationStore = appDelegate.notificationStore
        let previousNotifications = notificationStore.notifications
        appDelegate.notificationStore = notificationStore
        defer {
            notificationStore.replaceNotificationsForTesting(previousNotifications)
            appDelegate.notificationStore = previousNotificationStore
        }

        workspace.recordAgentPID(key: stalePIDKey, pid: 0, panelId: panel.id, refreshPorts: false)
        let staleAgentPort = 54_321
        workspace.agentListeningPorts = [staleAgentPort]
        workspace.recomputeListeningPorts()
        let staleNotification = TerminalNotification(
            id: UUID(), tabId: workspace.id, surfaceId: panel.id,
            title: "Stale agent", subtitle: "", body: "Needs input",
            createdAt: Date(), isRead: false
        )
        let siblingNotification = TerminalNotification(
            id: UUID(), tabId: workspace.id, surfaceId: UUID(),
            title: "Sibling", subtitle: "", body: "Keep me",
            createdAt: Date(), isRead: false
        )
        notificationStore.replaceNotificationsForTesting([staleNotification, siblingNotification])

        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == staleAsset)
        let stalePayload = workspace.terminalTabAgentIconPayload(forPanelId: panel.id)
        #expect(workspace.bonsplitController.tab(tabId)?.iconImageData == stalePayload.imageData)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == stalePayload.assetName)
        #expect(workspace.listeningPorts.contains(staleAgentPort))
        #expect(notificationStore.notifications.contains { $0.id == staleNotification.id })

        #expect(workspace.updatePanelTitle(panelId: panel.id, title: title))
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == expectedAsset)
        let expectedPayload = workspace.terminalTabAgentIconPayload(forPanelId: panel.id)
        #expect(workspace.bonsplitController.tab(tabId)?.iconImageData == expectedPayload.imageData)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == expectedPayload.assetName)
        #expect(workspace.agentPIDs[stalePIDKey] == nil)
        #expect(workspace.agentPIDKeysByPanelId[panel.id]?.contains(stalePIDKey) != true)
        #expect(workspace.agentListeningPorts.isEmpty)
        #expect(!workspace.listeningPorts.contains(staleAgentPort))
        #expect(!notificationStore.notifications.contains { $0.id == staleNotification.id })
        #expect(notificationStore.notifications.contains { $0.id == siblingNotification.id })
    }

    @MainActor
    private func assertPlainShellTitleClearsObservedRestoredAgentIcon(
        kind: RestorableAgentKind,
        expectedAsset: String
    ) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let snapshot = restoredAgentSnapshot(kind: kind)
        let stalePIDKey = "\(kind.rawValue).old-session"

        workspace.seedSessionRestoredAgentIconState(
            panelId: panel.id,
            restorableAgent: snapshot,
            willRunStartupCommand: false,
            willRunStartupInput: false
        )
        workspace.restoredAgentResumeStatesByPanelId[panel.id] = .observedAgentCommandRunning
        workspace.recordAgentPID(key: stalePIDKey, pid: 0, panelId: panel.id, refreshPorts: false)

        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == expectedAsset)
        let observedPayload = workspace.terminalTabAgentIconPayload(forPanelId: panel.id)
        #expect(workspace.bonsplitController.tab(tabId)?.iconImageData == observedPayload.imageData)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == observedPayload.assetName)

        #expect(workspace.updatePanelTitle(panelId: panel.id, title: "~/manaflow/cmuxterm-hq"))

        #expect(workspace.restoredAgentSnapshotForTesting(panelId: panel.id)?.sessionId == snapshot.sessionId)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == .observedAgentCommandRunning)
        #expect(workspace.agentPIDs[stalePIDKey] == nil)
        #expect(workspace.agentPIDKeysByPanelId[panel.id]?.contains(stalePIDKey) != true)
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == nil)
        let clearedPayload = workspace.terminalTabAgentIconPayload(forPanelId: panel.id)
        #expect(workspace.bonsplitController.tab(tabId)?.iconImageData == clearedPayload.imageData)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == clearedPayload.assetName)
    }

    private func restoredAgentSnapshot(kind: RestorableAgentKind) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: "\(kind.rawValue)-terminal-tab-icon-session",
            workingDirectory: "/tmp/cmux-terminal-tab-icon",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: kind.rawValue,
                executablePath: "/usr/local/bin/\(kind.rawValue)",
                arguments: ["/usr/local/bin/\(kind.rawValue)"],
                workingDirectory: "/tmp/cmux-terminal-tab-icon",
                environment: nil,
                capturedAt: 1_777_777_777,
                source: "test"
            )
        )
    }

    @Test func payloadUsesRenderedImageDataWhenAvailable() {
        let rendered = Data([0x63, 0x6d, 0x75, 0x78])
        let payload = TerminalTabAgentIconResolver().payload(assetName: "AgentIcons/Codex") { assetName in
            assetName == "AgentIcons/Codex" ? rendered : nil
        }

        #expect(payload.imageData == rendered)
        #expect(payload.assetName == nil)
    }

    @Test func payloadFallsBackToAssetNameWhenRenderingMisses() {
        let payload = TerminalTabAgentIconResolver().payload(assetName: "AgentIcons/Claude") { _ in nil }

        #expect(payload.imageData == nil)
        #expect(payload.assetName == "AgentIcons/Claude")
    }

    @Test func payloadClearsBothIconFieldsWhenNoAssetIsResolved() {
        let payload = TerminalTabAgentIconResolver().payload(assetName: nil) { _ in Data([1]) }

        #expect(payload.imageData == nil)
        #expect(payload.assetName == nil)
    }
}
