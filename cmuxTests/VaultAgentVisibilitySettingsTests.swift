import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class VaultAgentVisibilitySettingsTests: XCTestCase {
    func testDisabledVaultAgentIsFilteredFromSections() {
        let defaults = UserDefaults.standard
        let key = VaultAgentVisibilitySettings.key(for: .claude)
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set(false, forKey: key)

        let store = SessionIndexStore()
        store.grouping = .agent
        store.replaceEntriesForTesting([
            makeEntry(agent: .claude, sessionId: "claude-disabled", title: "Claude session"),
            makeEntry(agent: .codex, sessionId: "codex-visible", title: "Codex session"),
        ])

        let visibleAgents = store.sectionsForCurrentGrouping()
            .flatMap(\.entries)
            .map(\.agent)

        XCTAssertEqual(visibleAgents, [.codex])
    }

    func testVaultAgentVisibilitySettingsDefaultsKeysAndNotificationOnFlip() throws {
        let suiteName = "cmux-vault-agent-visibility-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(VaultAgentVisibilitySettings.key(for: .claude), "terminal.vaultShowClaudeSessions")
        XCTAssertEqual(VaultAgentVisibilitySettings.key(for: .codex), "terminal.vaultShowCodexSessions")
        XCTAssertEqual(VaultAgentVisibilitySettings.key(for: .opencode), "terminal.vaultShowOpenCodeSessions")
        XCTAssertEqual(VaultAgentVisibilitySettings.key(for: .rovodev), "terminal.vaultShowRovoDevSessions")

        for agent in SessionAgent.allCases {
            XCTAssertTrue(VaultAgentVisibilitySettings.isAgentEnabled(agent, defaults: defaults))
        }

        let notificationCenter = NotificationCenter()
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: VaultAgentVisibilitySettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        VaultAgentVisibilitySettings.setAgent(
            .opencode,
            enabled: false,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertFalse(VaultAgentVisibilitySettings.isAgentEnabled(.opencode, defaults: defaults))
        XCTAssertEqual(notificationCount, 1)

        VaultAgentVisibilitySettings.setAgent(
            .opencode,
            enabled: false,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(notificationCount, 1)

        VaultAgentVisibilitySettings.setAgent(
            .opencode,
            enabled: true,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertTrue(VaultAgentVisibilitySettings.isAgentEnabled(.opencode, defaults: defaults))
        XCTAssertEqual(notificationCount, 2)
    }

    func testDirectorySearchSkipsDisabledAgentScanner() async {
        let restoreDefaults = preserveVaultVisibilityDefaults()
        defer {
            restoreDefaults()
            SessionIndexStore.searchAgentOverrideForTesting = nil
        }

        let defaults = UserDefaults.standard
        for key in VaultAgentVisibilitySettings.allDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(false, forKey: VaultAgentVisibilitySettings.key(for: .claude))

        let recorder = AgentSearchRecorder()
        SessionIndexStore.searchAgentOverrideForTesting = { _, agent, _, _, _, _ in
            recorder.record(agent)
            return [
                SessionEntry(
                    id: "\(agent.rawValue):fake",
                    agent: agent,
                    sessionId: "fake-\(agent.rawValue)",
                    title: "\(agent.rawValue) fake",
                    cwd: "/tmp/project",
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: Date(timeIntervalSince1970: 1),
                    fileURL: nil,
                    specifics: agent.defaultSpecificsForTesting
                )
            ]
        }

        let store = SessionIndexStore()
        let outcome = await store.searchSessions(
            query: "",
            scope: .directory("/tmp/project"),
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(Set(recorder.snapshot()), Set([.codex, .opencode, .rovodev]))
        XCTAssertEqual(Set(outcome.entries.map(\.agent)), Set([.codex, .opencode, .rovodev]))
    }

    func testUnknownFolderSearchKeepsOnlyEntriesWithoutCwd() async {
        let restoreDefaults = preserveVaultVisibilityDefaults()
        defer {
            restoreDefaults()
            SessionIndexStore.searchAgentOverrideForTesting = nil
        }

        let defaults = UserDefaults.standard
        for key in VaultAgentVisibilitySettings.allDefaultsKeys {
            defaults.removeObject(forKey: key)
        }

        SessionIndexStore.searchAgentOverrideForTesting = { _, agent, _, _, _, _ in
            [
                SessionEntry(
                    id: "\(agent.rawValue):unknown",
                    agent: agent,
                    sessionId: "unknown-\(agent.rawValue)",
                    title: "\(agent.rawValue) unknown",
                    cwd: nil,
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: Date(timeIntervalSince1970: 2),
                    fileURL: nil,
                    specifics: agent.defaultSpecificsForTesting
                ),
                SessionEntry(
                    id: "\(agent.rawValue):project",
                    agent: agent,
                    sessionId: "project-\(agent.rawValue)",
                    title: "\(agent.rawValue) project",
                    cwd: "/tmp/project",
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: Date(timeIntervalSince1970: 1),
                    fileURL: nil,
                    specifics: agent.defaultSpecificsForTesting
                ),
            ]
        }

        let store = SessionIndexStore()
        let outcome = await store.searchSessions(
            query: "",
            scope: .directory(nil),
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(outcome.entries.count, SessionAgent.allCases.count)
        XCTAssertTrue(outcome.entries.allSatisfy { ($0.cwd ?? "").isEmpty })
    }

    private func preserveVaultVisibilityDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let snapshot: [String: Any?] = Dictionary(
            uniqueKeysWithValues: VaultAgentVisibilitySettings.allDefaultsKeys.map {
                ($0, defaults.object(forKey: $0))
            }
        )
        return {
            for (key, value) in snapshot {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    private func makeEntry(
        agent: SessionAgent,
        sessionId: String,
        title: String
    ) -> SessionEntry {
        SessionEntry(
            id: UUID().uuidString,
            agent: agent,
            sessionId: sessionId,
            title: title,
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: agent.defaultSpecificsForTesting
        )
    }
}

extension SessionAgent {
    var defaultSpecificsForTesting: AgentSpecifics {
        switch self {
        case .claude:
            return .claude(model: nil, permissionMode: nil)
        case .codex:
            return .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
        case .opencode:
            return .opencode(providerModel: nil, agentName: nil)
        case .rovodev:
            return .rovodev
        }
    }
}

private final class AgentSearchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [SessionAgent] = []

    func record(_ agent: SessionAgent) {
        lock.lock()
        defer { lock.unlock() }
        agents.append(agent)
    }

    func snapshot() -> [SessionAgent] {
        lock.lock()
        defer { lock.unlock() }
        return agents
    }
}
