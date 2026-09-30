import CmuxCloud
import CmuxControlSocket
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("CodeRouter sidebar accounts")
struct CoderouterAccountsPanelModelTests {
    @Test("A team switch clears the previous team's accounts before reading the new team")
    func teamSwitchDropsStaleRows() async {
        let operations = makeOperations()
        let model = CoderouterAccountsPanelModel(operations: operations)

        await model.reloadNow(teamID: "team-a")
        #expect(model.teamID == "team-a")
        #expect(model.accounts.map(\.rawID) == ["claude-team-a", "shared-team-a"])

        await model.reloadNow(teamID: "team-b")
        #expect(model.teamID == "team-b")
        #expect(model.accounts.map(\.rawID) == ["claude-team-b", "shared-team-b"])
        #expect(!model.accounts.contains { $0.rawID == "claude-team-a" })
    }

    @Test("A partial backend failure keeps accounts from healthy sources visible")
    func partialFailurePreservesHealthyAccounts() async {
        let operations = CoderouterAccountsPanelModel.Operations(
            listClaude: { _ in throw TestError.failed },
            listNative: { _ in .object(["accounts": .array([])]) },
            listShared: { teamID in
                [
                    .object([
                        "id": .string("shared-\(teamID)"),
                        "kind": .string("codex"),
                        "label": .string("Work"),
                    ])
                ]
            },
            addClaude: { _, _, _ in .object([:]) },
            addShared: { _, _ in .object([:]) },
            removeClaude: { _, _ in .object([:]) },
            removeShared: { _, _ in .object([:]) },
            updateClaude: { _, _, _ in .object([:]) },
            addNative: { _, _, _, _ in .object([:]) },
            removeNative: { _, _ in .object([:]) },
            loadUsage: { _ in throw TestError.failed }
        )
        let model = CoderouterAccountsPanelModel(operations: operations)

        await model.reloadNow(teamID: "team-a")

        #expect(model.accounts.map(\.rawID) == ["shared-team-a"])
        #expect(model.failedSources == [.claude, .usage])
        #expect(model.state == .loaded)
    }

    @Test("An account-source outage stays retryable even when usage is available")
    func accountSourceOutageIsFailed() async {
        let operations = CoderouterAccountsPanelModel.Operations(
            listClaude: { _ in throw TestError.failed },
            listNative: { _ in throw TestError.failed },
            listShared: { _ in throw TestError.failed },
            addClaude: { _, _, _ in .object([:]) },
            addShared: { _, _ in .object([:]) },
            removeClaude: { _, _ in .object([:]) },
            removeShared: { _, _ in .object([:]) },
            updateClaude: { _, _, _ in .object([:]) },
            addNative: { _, _, _, _ in .object([:]) },
            removeNative: { _, _ in .object([:]) },
            loadUsage: { _ in TestState.emptyUsage }
        )
        let model = CoderouterAccountsPanelModel(operations: operations)

        await model.reloadNow(teamID: "team-a")

        #expect(model.accounts.isEmpty)
        #expect(model.state == .failed)
        #expect(model.failedSources == [.claude, .native, .shared])
    }

    @Test("Adding an account refreshes from the authoritative team list")
    func addRefreshesAuthoritativeState() async throws {
        let state = TestState()
        let operations = CoderouterAccountsPanelModel.Operations(
            listClaude: { teamID in await state.claudePayload(teamID: teamID) },
            listNative: { _ in .object(["accounts": .array([])]) },
            listShared: { _ in [] },
            addClaude: { _, _, _ in
                await state.markAdded()
                return .object([:])
            },
            addShared: { _, _ in .object([:]) },
            removeClaude: { _, _ in .object([:]) },
            removeShared: { _, _ in .object([:]) },
            updateClaude: { _, _, _ in .object([:]) },
            addNative: { _, _, _, _ in .object([:]) },
            removeNative: { _, _ in .object([:]) },
            loadUsage: { _ in TestState.emptyUsage }
        )
        let model = CoderouterAccountsPanelModel(operations: operations)
        await model.reloadNow(teamID: "team-a")

        try await model.addClaude(.anthropicAPIKey("redacted-test-key"), label: "New")

        let added = await state.isAdded
        #expect(added)
        #expect(model.accounts.map(\.rawID) == ["new-account"])
    }

    private func makeOperations() -> CoderouterAccountsPanelModel.Operations {
        CoderouterAccountsPanelModel.Operations(
            listClaude: { teamID in
                .object([
                    "accounts": .array([
                        .object([
                            "id": .string("claude-\(teamID)"),
                            "kind": .string("anthropic_oauth"),
                            "label": .string("Team Claude"),
                            "identifier": .string("sk-ant-…1234"),
                            "state": .string("active"),
                        ])
                    ]),
                    "teamId": .string(teamID),
                ])
            },
            listNative: { _ in .object(["accounts": .array([])]) },
            listShared: { teamID in
                [
                    .object([
                        "id": .string("shared-\(teamID)"),
                        "kind": .string("codex"),
                        "label": .string("Team Codex"),
                    ])
                ]
            },
            addClaude: { _, _, _ in .object([:]) },
            addShared: { _, _ in .object([:]) },
            removeClaude: { _, _ in .object([:]) },
            removeShared: { _, _ in .object([:]) },
            updateClaude: { _, _, _ in .object([:]) },
            addNative: { _, _, _, _ in .object([:]) },
            removeNative: { _, _ in .object([:]) },
            loadUsage: { _ in TestState.emptyUsage }
        )
    }

    private actor TestState {
        var added = false

        func markAdded() {
            added = true
        }

        var isAdded: Bool { added }

        func claudePayload(teamID: String) -> JSONValue {
            let id = added ? "new-account" : "old-account"
            return .object([
                "accounts": .array([
                    .object([
                        "id": .string(id),
                        "kind": .string("anthropic_api_key"),
                        "label": .string(added ? "New" : "Old"),
                    ])
                ]),
                "teamId": .string(teamID),
            ])
        }

        static let emptyUsage = TeamMachineUsage(
            teamID: "team-a",
            periodDays: 30,
            kind: .ready,
            asOf: nil,
            machines: []
        )
    }

    private enum TestError: Error {
        case failed
    }
}
