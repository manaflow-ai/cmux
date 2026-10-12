import AppKit
import CmuxSettings
import Foundation
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An agent session panel (the in-app agent chat) notifies like a terminal
/// agent (cx-sg1qz): a finished turn posts "Completed in <project>" with the
/// agent's last message, and a provider that exits with a failure posts an
/// error, both on the panel's own surface, so the banner, Dock badge, focused
/// pane suppression and click-to-jump apply. Each test starts a fake Claude
/// Code through the panel's bridge, as the page does.
extension AgentNotificationRegressionTests {
    @Test("An agent session panel posts its finished turn on its own surface")
    func agentSessionPanelPostsItsFinishedTurn() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let reply = "Refactored the parser and every test passes."
        let agent = try FakeClaudeExecutable(script: """
        while IFS= read -r line; do
          printf '%s\\n' '{"type":"content_block_delta","delta":{"type":"text_delta","text":"\(reply)"}}'
          printf '%s\\n' '{"type":"message_stop"}'
          printf '%s\\n' '{"type":"result","subtype":"success","result":"\(reply)"}'
        done
        """)
        defer { agent.restore() }
        let (panel, coordinator) = try agentPanel(fixture, directory: agent.project)

        let started = try await coordinator.handleBridgeRequestForTesting(
            ["id": "1", "method": "provider.start", "params": ["providerId": "claude"]]
        )
        let session = try #require((started as? [String: Any])?["sessionId"] as? String)
        _ = try await coordinator.handleBridgeRequestForTesting(
            ["id": "2", "method": "provider.writeLine", "params": ["sessionId": session, "text": "Refactor the parser"]]
        )

        let onPanel: (TerminalNotification) -> Bool = { $0.tabId == fixture.source.id && $0.surfaceId == panel.id }
        await waitForDrainedNotifications(in: fixture.store, matching: onPanel)
        let posted = fixture.store.notifications.filter(onPanel)
        #expect(posted.count == 1, "one notification per finished turn: \(posted.map(\.subtitle))")
        #expect(posted.first?.title == "Claude Code")
        #expect(posted.first?.subtitle == "Completed in \(agent.project.lastPathComponent)")
        #expect(posted.first?.body == reply)
        _ = try? await coordinator.handleBridgeRequestForTesting(
            ["id": "3", "method": "provider.stop", "params": ["sessionId": session]]
        )
    }

    @Test("An agent session panel posts an error when its agent fails")
    func agentSessionPanelPostsItsAgentFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let agent = try FakeClaudeExecutable(script: """
        IFS= read -r line
        exit 3
        """)
        defer { agent.restore() }
        let (panel, coordinator) = try agentPanel(fixture, directory: agent.project)

        let started = try await coordinator.handleBridgeRequestForTesting(
            ["id": "1", "method": "provider.start", "params": ["providerId": "claude"]]
        )
        let session = try #require((started as? [String: Any])?["sessionId"] as? String)
        _ = try await coordinator.handleBridgeRequestForTesting(
            ["id": "2", "method": "provider.writeLine", "params": ["sessionId": session, "text": "Fix the build"]]
        )

        let onPanel: (TerminalNotification) -> Bool = { $0.tabId == fixture.source.id && $0.surfaceId == panel.id }
        await waitForDrainedNotifications(in: fixture.store, matching: onPanel)
        let posted = fixture.store.notifications.filter(onPanel)
        #expect(posted.count == 1)
        #expect(posted.first?.title == "Claude Code")
        #expect(posted.first?.subtitle == "Error")
        #expect(posted.first?.body == "Provider exited 3")
    }

    @Test("Stopping or closing an agent session posts no error")
    func stoppingOrClosingAnAgentSessionPostsNoError() async throws {
        let agent = try FakeClaudeExecutable(script: """
        while IFS= read -r line; do
          printf '%s\\n' '{"type":"content_block_delta","delta":{"type":"text_delta","text":"Done."}}'
          printf '%s\\n' '{"type":"result","subtype":"success","result":"Done."}'
        done
        """)
        defer { agent.restore() }
        let store = AgentSessionProcessStore()
        defer { store.closeAll() }
        var notices: [AgentSessionTurnNotifier.Notice] = []
        var exits: [String] = []
        let notifier = AgentSessionTurnNotifier(
            surfaceID: UUID(), workspaceID: { UUID() }, workingDirectory: { nil },
            deliver: { notices.append($0) }
        )
        store.eventSink = { event in
            notifier.observe(event)
            if event["type"] as? String == "provider.exit" { exits.append("\(event["status"] ?? "")") }
        }
        let executable = agent.project.appendingPathComponent("claude", isDirectory: false)
        let plan = AgentSessionLaunchPlan(
            provider: .claude, executableURL: executable, arguments: [], environment: ProcessInfo.processInfo.environment
        )
        // Stop (the panel's Stop button), then closing the panel (closeAll), each after a finished turn.
        let closes: [(String) -> Void] = [{ _ = try? store.stop(sessionId: $0) }, { _ in store.closeAll() }]
        for close in closes {
            let started = try await store.start(plan: plan, workingDirectory: agent.project.path)
            let before = (notices.count, exits.count)
            try await store.writeLine(sessionId: started.sessionId, text: "Say done")
            let deadline = ContinuousClock.now + .seconds(10)
            while notices.count == before.0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            close(started.sessionId)
            while exits.count == before.1, ContinuousClock.now < deadline + .seconds(10) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(exits.count == before.1 + 1, "the agent exited")
        }
        #expect(notices.map(\.category) == [.turnComplete, .turnComplete], "\(notices.map(\.body)); exits \(exits)")
    }

    @Test("An agent session reports a Claude turn while the agent keeps running")
    func agentSessionReportsTurnWhileAgentRuns() async throws {
        let agent = try FakeClaudeExecutable(script: """
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$0.received"
          printf '%s\\n' '{"type":"content_block_delta","delta":{"type":"text_delta","text":"Done."}}'
          printf '%s\\n' '{"type":"message_stop"}'
        done
        """)
        defer { agent.restore() }
        let store = AgentSessionProcessStore()
        defer { store.closeAll() }
        var events: [String] = []
        store.eventSink = { event in
            let fields = ["type", "stream", "text", "status"].compactMap { key in event[key].map { value in "\(value)" } }
            events.append(fields.joined(separator: " "))
        }
        let executable = agent.project.appendingPathComponent("claude", isDirectory: false)
        let started = try await store.start(
            plan: AgentSessionLaunchPlan(
                provider: .claude,
                executableURL: executable,
                arguments: [],
                environment: ProcessInfo.processInfo.environment
            ),
            workingDirectory: agent.project.path
        )
        try await store.writeLine(sessionId: started.sessionId, text: "Say done")

        let deadline = ContinuousClock.now + .seconds(10)
        while !events.contains(where: { $0.hasPrefix("provider.turnComplete") }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let received = (try? String(contentsOf: executable.appendingPathExtension("received"), encoding: .utf8)) ?? "<nothing>"
        #expect(
            events.contains(where: { $0.hasPrefix("provider.turnComplete") }),
            "events: \(events); agent received: \(received)"
        )
    }

    /// A Claude Code agent panel in the fixture's workspace and its bound
    /// bridge, the way the panel's view binds it.
    private func agentPanel(
        _ fixture: Fixture,
        directory: URL
    ) throws -> (AgentSessionPanel, AgentSessionWebRendererCoordinator) {
        let pane = try #require(fixture.source.bonsplitController.allPaneIds.first)
        let panel = try #require(fixture.source.newAgentSessionSurface(
            inPane: pane,
            providerID: .claude,
            rendererKind: .react,
            workingDirectory: directory.path,
            focus: false
        ))
        let coordinator = panel.rendererSession.coordinator(
            panelId: panel.id,
            workspaceId: fixture.source.id,
            rendererKind: .react,
            initialProviderID: .claude,
            workingDirectory: directory.path,
            theme: .resolve(appearance: PanelAppearance(
                backgroundColor: .black, foregroundColor: .white,
                dividerColor: .gray, unfocusedOverlayNSColor: .black,
                unfocusedOverlayOpacity: 0, usesClearContentBackground: false
            )),
            isFocused: false
        )
        return (panel, coordinator)
    }

    /// Delivers queued notifications until one matches (or fifteen seconds pass).
    private func waitForDrainedNotifications(
        in store: TerminalNotificationStore,
        matching predicate: (TerminalNotification) -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(15)
        repeat {
            TerminalMutationBus.shared.drainForTesting()
            if store.notifications.contains(where: predicate) {
                // A second post for the same turn would land right behind the first.
                try? await Task.sleep(for: .milliseconds(300))
                TerminalMutationBus.shared.drainForTesting()
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
    }
}

/// A shell script installed as the custom Claude Code executable, in its own
/// project folder.
private struct FakeClaudeExecutable {
    let project: URL
    private let key = "claudeCodeCustomClaudePath"
    private let previous: Any?

    init(script: String) throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-panel-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let executable = project.appendingPathComponent("claude", isDirectory: false)
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(executable.path, forKey: key)
    }

    func restore() {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: project)
    }
}
