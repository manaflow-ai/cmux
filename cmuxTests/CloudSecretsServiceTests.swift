import CmuxCloud
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The app's Cloud Secrets service and its socket parsing, driven through an in-memory
/// vault and a recording transport: what reaches the machine link (values), what
/// reaches `vm.exec` (names only), and what the socket answers. These pin behavior,
/// not source shape.
@MainActor
@Suite(.serialized)
struct CloudSecretsServiceTests {
    /// Records every delivery and exec; `failDelivery` makes the link refuse.
    final class RecordingTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var deliveriesStorage: [(machine: String, entries: [CloudEnvDelivery.Entry])] = []
        private var commandsStorage: [(machine: String, command: String)] = []
        var failDelivery: Error?
        var execStdout = ""

        var deliveries: [(machine: String, entries: [CloudEnvDelivery.Entry])] {
            lock.lock()
            defer { lock.unlock() }
            return deliveriesStorage
        }

        var commands: [String] {
            lock.lock()
            defer { lock.unlock() }
            return commandsStorage.map(\.command)
        }

        var transport: CloudSecretsService.Transport {
            CloudSecretsService.Transport(
                deliver: { machine, entries in
                    self.lock.lock()
                    let failure = self.failDelivery
                    if failure == nil { self.deliveriesStorage.append((machine, entries)) }
                    self.lock.unlock()
                    if let failure { throw failure }
                },
                exec: { machine, command in
                    self.lock.lock()
                    self.commandsStorage.append((machine, command))
                    let stdout = self.execStdout
                    self.lock.unlock()
                    return VMExecResult(exitCode: 0, stdout: stdout, stderr: "")
                }
            )
        }
    }

    private func makeService(_ recorder: RecordingTransport) -> CloudSecretsService {
        let suite = "cloud-secrets-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return CloudSecretsService(
            vault: CloudSecretVault(storage: InMemoryCloudSecretVaultStorage()),
            transport: recorder.transport,
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            observesMachineCreation: false
        )
    }

    // MARK: - Sync

    @Test func syncDeliversTheEffectiveSetOverTheLinkThenIsANoop() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        try await service.set(
            [CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-ant-value")],
            scope: .all, source: .manual, sync: false
        )
        try await service.set(
            [CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-ant-machine")],
            scope: .machine("m1"), source: .manual, sync: false
        )

        let first = await service.sync(machineID: "m1")
        #expect(first.error == nil)
        #expect(first.sent == ["ANTHROPIC_API_KEY"])
        // The most specific scope wins and the value only rides the link.
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.entries == [CloudEnvDelivery.Entry(key: "ANTHROPIC_API_KEY", value: "sk-ant-machine")])
        #expect(!recorder.commands.contains { $0.contains("sk-ant") })

        let second = await service.sync(machineID: "m1")
        #expect(second.noop)
        #expect(recorder.deliveries.count == 1)
        #expect(service.delivery(for: "m1")?.delivered["ANTHROPIC_API_KEY"] != nil)
    }

    @Test func removingASecretRemovesItFromSyncedMachinesByNameOnly() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-openai")], scope: .all, source: .manual, sync: false)
        _ = await service.sync(machineID: "m1")

        let outcome = try await service.remove(names: ["OPENAI_API_KEY"], scope: .all, sync: true)

        #expect(outcome.changes.map(\.kind) == [.removed])
        #expect(outcome.synced.map(\.removed) == [["OPENAI_API_KEY"]])
        #expect(recorder.commands == ["cmux env rm OPENAI_API_KEY"])
    }

    @Test func aGitHubTokenConfiguresTheCredentialHelperWithoutTheValue() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "GH_TOKEN", value: "ghp_secretvalue")], scope: .all, source: .ghCLI, sync: false)

        let result = await service.sync(machineID: "m1")

        #expect(result.configuredGitCredentials)
        let helper = try #require(recorder.commands.first)
        #expect(helper.hasPrefix("git config --global credential.https://github.com.helper "))
        #expect(helper.contains("${GH_TOKEN:-$GITHUB_TOKEN}"))
        #expect(!helper.contains("ghp_secretvalue"))
    }

    @Test func aFailedDeliveryIsRedactedAndRecorded() async throws {
        let recorder = RecordingTransport()
        recorder.failDelivery = CloudEnvDelivery.DeliveryError.receiverFailed("echo sk-leaky-value")
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "XAI_API_KEY", value: "sk-leaky-value")], scope: .all, source: .manual, sync: false)

        let result = await service.sync(machineID: "m1")

        let message = try #require(result.error)
        #expect(!message.contains("sk-leaky-value"))
        #expect(result.sent.isEmpty)
    }

    @Test func maskReplacesEveryValueOccurrence() {
        let masked = CloudSecretsService.mask("token sk-abc123 then sk-abc123", values: ["sk-abc123", "ab"])
        #expect(masked == "token •••• then ••••")
    }

    @Test func verifiedStatusReadsNamesFromTheMachine() async throws {
        let recorder = RecordingTransport()
        recorder.execStdout = #"{"path":"/root/.config/cmux/env","keys":["OTHER"]}"#
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "GEMINI_API_KEY", value: "g-value")], scope: .all, source: .manual, sync: false)
        _ = await service.sync(machineID: "m1")

        let rows = try await service.status(machineID: "m1", verify: true)

        #expect(recorder.commands.last == CloudSecretsService.envListCommand)
        #expect(rows.map(\.name) == ["GEMINI_API_KEY"])
        #expect(rows.map(\.state) == [.missing])
    }

    @Test func previewReportsChangesWithoutStoring() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        let changes = try await service.preview([CloudSecretInput(name: "NPM_TOKEN", value: "npm-value")], scope: .all)
        #expect(changes.map(\.kind) == [.added])
        await service.reload()
        #expect(service.records.isEmpty)
    }

    // MARK: - Socket parameters

    @Test func scopeParsingAcceptsWireValuesAndResolvesProjects() throws {
        #expect(try CloudSecretsSocketParams.scope([:], method: "m") == .all)
        #expect(try CloudSecretsSocketParams.scope([:], method: "m", defaultScope: nil) == nil)
        #expect(try CloudSecretsSocketParams.scope(["scope": "machine:m1"], method: "m") == .machine("m1"))
        #expect(try CloudSecretsSocketParams.scope(["scope": "project:https://github.com/Owner/Repo.git"], method: "m") == .project("github.com/owner/repo"))
        #expect(try CloudSecretsSocketParams.scope(["scope": "project", "project_remote_url": "git@github.com:Owner/Repo.git"], method: "m") == .project("github.com/owner/repo"))
        #expect(try CloudSecretsSocketParams.scope(["scope": "project", "project_dir_name": "scratch"], method: "m") == .project("local/scratch"))
        #expect(throws: CloudSecretsSocketFailure.self) { try CloudSecretsSocketParams.scope(["scope": "project"], method: "m") }
        #expect(throws: CloudSecretsSocketFailure.self) { try CloudSecretsSocketParams.scope(["scope": "galaxy"], method: "m") }
    }

    @Test func entriesAreValidatedBeforeAnyWriteAndErrorsNameNoValue() throws {
        let inputs = try CloudSecretsSocketParams.entries(["entries": [["key": "A_KEY", "value": " padded "]]], method: "vm.secrets_set")
        #expect(inputs == [CloudSecretInput(name: "A_KEY", value: " padded ")])
        let cases: [[String: Any]] = [
            [:],
            ["entries": [["key": "A_KEY"]]],
            ["entries": [["key": "PATH", "value": "x"]]],
            ["entries": [["key": "CMUX_SOCKET", "value": "x"]]],
            ["entries": [["key": "MULTI", "value": "line-one-secret\nline-two"]]],
        ]
        for params in cases {
            do {
                _ = try CloudSecretsSocketParams.entries(params, method: "vm.secrets_set")
                Issue.record("expected a refusal for \(params.keys.sorted())")
            } catch let failure as CloudSecretsSocketFailure {
                #expect(failure.code == "invalid_params")
                #expect(!failure.message.contains("line-one-secret"))
            }
        }
    }

    @Test func socketRefusesMissingParamsWithInvalidParams() async throws {
        let cases: [(method: String, params: [String: Any])] = [
            ("vm.secrets_set", ["scope": "all"]),
            ("vm.secrets_set", ["scope": "galaxy", "entries": [["key": "A", "value": "v"]]]),
            ("vm.secrets_rm", ["names": [String]()]),
            ("vm.secrets_sync", [:]),
            ("vm.secrets_status", [:]),
            ("vm.secrets_link", ["id": "m1"]),
            ("vm.secrets_check", [:]),
        ]
        for testCase in cases {
            let response = await Task.detached {
                TerminalController.shared.socketWorkerVMSecretsResponse(method: testCase.method, id: "secrets", params: testCase.params)
            }.value
            let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            let error = try #require(object["error"] as? [String: Any], "\(testCase.method) should fail")
            #expect(error["code"] as? String == "invalid_params", "\(testCase.method)")
        }
    }
}
