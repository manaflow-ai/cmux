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

    @Test("An OpenCode turn that runs a tool posts one notification")
    func openCodeTurnWithAToolStepPostsOnce() async throws {
        // A fake OpenCode server: one prompt is a tool step and an answer, each a finished
        // assistant message, then the session goes idle.
        let agent = try FakeClaudeExecutable(script: #"exec /usr/bin/python3 "$(dirname "$0")/fake_opencode.py""#)
        defer { agent.restore() }
        try Self.fakeOpenCode.write(
            to: agent.project.appendingPathComponent("fake_opencode.py", isDirectory: false), atomically: true, encoding: .utf8
        )
        let store = AgentSessionProcessStore()
        defer { store.closeAll() }
        var notices: [AgentSessionTurnNotifier.Notice] = []
        var started = false
        var seen: [String] = []
        let notifier = AgentSessionTurnNotifier(
            surfaceID: UUID(), workspaceID: { UUID() }, workingDirectory: { nil },
            deliver: { notices.append($0) }
        )
        store.eventSink = { event in
            notifier.observe(event)
            seen.append(["type", "stream", "text", "status"].compactMap { key in event[key].map { value in "\(value)" } }.joined(separator: " "))
            if event["type"] as? String == "provider.started" { started = true }
        }
        let session = try await store.start(
            plan: AgentSessionLaunchPlan(
                provider: .opencode,
                executableURL: agent.project.appendingPathComponent("claude", isDirectory: false),
                arguments: [],
                environment: ProcessInfo.processInfo.environment
            ),
            workingDirectory: agent.project.path
        )
        let deadline = ContinuousClock.now + .seconds(20)
        while !started, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(started, "the fake OpenCode session started: \(seen)")
        try await store.writeLine(sessionId: session.sessionId, text: "Read the file")
        // The turn's notice carries the final answer; a per-step notice comes before it.
        while !notices.contains(where: { $0.body.contains("All done.") }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(notices.count == 1, "one notification per OpenCode turn: \(notices.map(\.body)), events: \(seen)")
        #expect(notices.first?.body.contains("All done.") == true)
    }

    private static let fakeOpenCode = #"""
import json, queue
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

events = queue.Queue()

def emit(kind, **properties):
    events.put({"type": kind, "properties": properties})

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        path = self.path.split("?")[0]
        if path == "/session":
            return self.reply({"id": "ses1"})
        if path.endswith("/prompt_async"):
            self.reply({})
            # One turn: a tool step, then the answer, then the session goes idle.
            for step, (text, finish) in enumerate([("Reading the file.", "tool-calls"), ("All done.", "stop")]):
                info = {"id": "m%d" % step, "role": "assistant", "sessionID": "ses1"}
                emit("message.updated", info=info)
                emit("message.part.updated", part={"id": "p%d" % step, "messageID": info["id"],
                                                   "sessionID": "ses1", "type": "text", "text": text})
                emit("message.updated", info=dict(info, finish=finish, time={"created": 1, "completed": 2}))
            emit("session.idle", sessionID="ses1")
            return
        self.reply({}, 404)

    def do_GET(self):
        if self.path.split("?")[0] != "/event":
            return self.reply({}, 404)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        while True:
            self.wfile.write(("data: " + json.dumps(events.get()) + "\n\n").encode())
            self.wfile.flush()

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print("opencode server listening on http://127.0.0.1:%d" % server.server_address[1], flush=True)
server.serve_forever()
"""#

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
