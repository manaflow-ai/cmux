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
        private var eventsStorage: [String] = []
        var failDelivery: Error?
        var execStdout = ""
        /// Exit code for an exec; 0 unless a test says otherwise.
        var execExitCode: @Sendable (String) -> Int = { _ in 0 }
        /// What the routing guard prints: every provider routed unless a test says otherwise.
        var guardStdout = "CMUX-ROUTING-RESULT openai=ok anthropic=ok\n"

        /// Deliveries and execs in order: "deliver:<names>" or "exec:<command>".
        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return eventsStorage
        }

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
                    if failure == nil {
                        self.deliveriesStorage.append((machine, entries))
                        self.eventsStorage.append("deliver:" + entries.map(\.key).joined(separator: ","))
                    }
                    self.lock.unlock()
                    if let failure { throw failure }
                },
                exec: { machine, command in
                    self.lock.lock()
                    self.commandsStorage.append((machine, command))
                    self.eventsStorage.append("exec:" + command)
                    let stdout = command.contains("cmux-provider-routing") ? self.guardStdout : self.execStdout
                    let exitCode = self.execExitCode(command)
                    self.lock.unlock()
                    return VMExecResult(exitCode: exitCode, stdout: stdout, stderr: "")
                }
            )
        }
    }

    private func makeService(_ recorder: RecordingTransport, defaults: UserDefaults? = nil) -> CloudSecretsService {
        let suite = "cloud-secrets-tests-\(UUID().uuidString)"
        let defaults = defaults ?? UserDefaults(suiteName: suite) ?? .standard
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
        // Names only: the first sync's guards around its delivery, then the
        // removal, then the guard that releases the endpoint cmux added beside
        // the key.
        let unrouted = CloudSecretsProviderRouting.unrouted.command
        #expect(recorder.commands == [
            CloudSecretsProviderRouting(openAI: .direct, anthropic: .keep).command,
            CloudSecretsProviderRouting(openAI: .direct, anthropic: .plane).command,
            "cmux env rm OPENAI_API_KEY",
            unrouted,
        ])
        #expect(!recorder.commands.contains { $0.contains("sk-openai") })
    }

    @Test func anExplicitSyncRunsEvenWhenNothingChanged() async throws {
        let recorder = RecordingTransport()
        recorder.failDelivery = CloudEnvDelivery.DeliveryError.receiverFailed("offline")
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "XAI_API_KEY", value: "xai-value")], scope: .all, source: .manual, sync: false)
        _ = await service.sync(machineID: "m1")
        recorder.failDelivery = nil

        // The same value again, with `--sync`: the stale machine still gets it.
        let unchanged = try await service.set([CloudSecretInput(name: "XAI_API_KEY", value: "xai-value")], scope: .all, source: .manual, sync: true)
        #expect(unchanged.changes.map(\.kind) == [.unchanged])
        #expect(unchanged.synced.map(\.machineID) == ["m1"])
        #expect(recorder.deliveries.count == 1)

        // Removing a name the scope does not hold, with `--sync`, still syncs.
        try await service.set([CloudSecretInput(name: "XAI_API_KEY", value: "xai-next")], scope: .all, source: .manual, sync: false)
        let nothing = try await service.remove(names: ["NOT_STORED"], scope: .all, sync: true)
        #expect(nothing.changes.isEmpty)
        #expect(nothing.synced.map(\.machineID) == ["m1"])
        #expect(recorder.deliveries.count == 2)
    }

    @Test func aGitHubTokenConfiguresTheCredentialHelperWithoutTheValue() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "GH_TOKEN", value: "ghp_secretvalue")], scope: .all, source: .ghCLI, sync: false)

        let result = await service.sync(machineID: "m1")

        #expect(result.configuredGitCredentials)
        let helper = try #require(recorder.commands.first)
        #expect(helper.contains("git config --global --add credential.https://github.com.helper "))
        #expect(helper.contains("${GH_TOKEN:-$GITHUB_TOKEN}"))
        #expect(!helper.contains("ghp_secretvalue"))
    }

    @Test func removingTheLastGitHubTokenRemovesOnlyCmuxHelpers() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "GH_TOKEN", value: "ghp_secretvalue")], scope: .all, source: .ghCLI, sync: false)
        _ = await service.sync(machineID: "m1")

        _ = try await service.remove(names: ["GH_TOKEN"], scope: .all, sync: true)

        let cleanup = try #require(recorder.commands.last)
        #expect(cleanup.contains("git config --global --unset-all --fixed-value"))
        #expect(cleanup.contains("cmux_cloud_github_token_helper_v1"))
        #expect(cleanup.contains("!f()"))
        #expect(!cleanup.contains("ghp_secretvalue"))
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

    // MARK: - Provider routing

    @Test func providerRoutingFollowsTheUsersKeysAndEndpoints() {
        let none = CloudSecretsProviderRouting(effectiveNames: ["GH_TOKEN"])
        #expect(none == .unrouted)
        #expect(!none.hasUserProviderKey)
        #expect(none.companionEndpoints.isEmpty)

        let openAI = CloudSecretsProviderRouting(effectiveNames: ["OPENAI_API_KEY", "GH_TOKEN"])
        #expect(openAI.openAI == .direct)
        #expect(openAI.anthropic == .plane)
        #expect(openAI.companionEndpoints.map { $0.name } == ["OPENAI_BASE_URL"])
        #expect(openAI.companionEndpoints.map { $0.value } == ["https://api.openai.com/v1"])
        #expect(openAI.protectingOnly == CloudSecretsProviderRouting(openAI: .direct, anthropic: .keep))

        // A user's own endpoint in Cloud Secrets wins; cmux adds none.
        let ownEndpoint = CloudSecretsProviderRouting(effectiveNames: ["OPENAI_API_KEY", "OPENAI_BASE_URL"])
        #expect(ownEndpoint.openAI == .user)
        #expect(ownEndpoint.companionEndpoints.isEmpty)

        // Claude Code's bearer token counts as an Anthropic key too.
        let token = CloudSecretsProviderRouting(effectiveNames: ["ANTHROPIC_AUTH_TOKEN"])
        #expect(token.anthropic == .direct)
        #expect(token.companionEndpoints.map { $0.value } == ["https://api.anthropic.com"])
        #expect(token.marker == "v1;openai=plane;anthropic=direct")
    }

    @Test func theRoutingGuardCarriesNamesAndConstantsOnly() {
        let routing = CloudSecretsProviderRouting(openAI: .direct, anthropic: .user)
        #expect(routing.command.hasPrefix("sh -c '"))
        #expect(routing.command.hasSuffix(" cmux-provider-routing direct user"))
        let script = CloudSecretsProviderRouting.guardScript
        #expect(script.contains(CloudSecretsProviderRouting.openAIEndpoint))
        #expect(script.contains(CloudSecretsProviderRouting.anthropicEndpoint))
        // The model-plane copy is neutralized, never rewritten with a value.
        #expect(script.contains(#"ln -sfn /dev/null "$mp""#))
    }

    @Test func aProviderKeyIsRoutedBeforeItIsDeliveredAndNeverWithItsValue() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-proj-user")], scope: .all, source: .manual, sync: false)

        let result = await service.sync(machineID: "m1")

        #expect(result.error == nil)
        let guardCommand = CloudSecretsProviderRouting(openAI: .direct, anthropic: .keep).command
        // The guard runs first, then the key alone rides the link, then the
        // release for the provider the user gave no key (Anthropic).
        #expect(recorder.events == [
            "exec:" + guardCommand,
            "deliver:OPENAI_API_KEY",
            "exec:" + CloudSecretsProviderRouting(openAI: .direct, anthropic: .plane).command,
        ])
        #expect(!recorder.commands.contains { $0.contains("sk-proj-user") })
        #expect(recorder.deliveries.first?.entries == [CloudEnvDelivery.Entry(key: "OPENAI_API_KEY", value: "sk-proj-user")])

        // Current machine, current routing: nothing runs again.
        let again = await service.sync(machineID: "m1")
        #expect(again.noop)
        #expect(recorder.events.count == 3)
    }

    @Test func aUsersOwnEndpointIsRoutedAgainAfterItIsDelivered() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        try await service.set([
            CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-proj-user"),
            CloudSecretInput(name: "OPENAI_BASE_URL", value: "https://proxy.example.test/v1"),
            CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-ant-user"),
        ], scope: .all, source: .manual, sync: false)

        let result = await service.sync(machineID: "m1")

        // The guard reads the user's endpoint on the machine (by name) to point
        // codex at it, so it runs again once that endpoint has landed.
        #expect(result.error == nil)
        let routing = CloudSecretsProviderRouting(openAI: .user, anthropic: .direct)
        #expect(recorder.events == [
            "exec:" + routing.command,
            "deliver:ANTHROPIC_API_KEY,OPENAI_API_KEY,OPENAI_BASE_URL",
            "exec:" + routing.command,
        ])
    }

    @Test func directProviderKeysRunTheRoutingGuardAgainAfterDelivery() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        try await service.set([
            CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-openai-user"),
            CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-ant-user"),
        ], scope: .all, source: .manual, sync: false)

        _ = await service.sync(machineID: "m1")

        let routing = CloudSecretsProviderRouting(openAI: .direct, anthropic: .direct)
        #expect(recorder.events == [
            "exec:" + routing.command,
            "deliver:ANTHROPIC_API_KEY,OPENAI_API_KEY",
            "exec:" + routing.command,
        ])
    }

    @Test func aGuardThatFailsKeepsTheKeyOffTheMachine() async throws {
        let recorder = RecordingTransport()
        recorder.execExitCode = { command in command.contains("cmux-provider-routing") ? 1 : 0 }
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-ant-guarded")], scope: .all, source: .manual, sync: false)

        let result = await service.sync(machineID: "m1")

        #expect(result.error != nil)
        #expect(!(result.error ?? "").contains("sk-ant-guarded"))
        #expect(recorder.deliveries.isEmpty)
    }

    @Test func aMachineThatGotAKeyBeforeRoutingExistedIsRoutedWithoutRedelivery() async throws {
        let recorder = RecordingTransport()
        let defaults = try #require(UserDefaults(suiteName: "cloud-secrets-tests-\(UUID().uuidString)"))
        let service = makeService(recorder, defaults: defaults)
        try await service.set([CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-proj-old")], scope: .all, source: .manual, sync: false)
        _ = await service.sync(machineID: "m1")
        // As if delivered by a build without routing: the ledger is current, the
        // routing marker absent.
        service.forgetProviderRouting(machineID: "m1")
        let before = recorder.events.count

        let results = await service.syncAllStale()

        #expect(results.map(\.machineID) == ["m1"])
        #expect(results.first?.noop == true)
        #expect(Array(recorder.events.dropFirst(before)) == [
            "exec:" + CloudSecretsProviderRouting(openAI: .direct, anthropic: .plane).command,
        ])
        #expect(recorder.deliveries.count == 1)
        #expect(await service.syncAllStale().isEmpty)
    }

    @Test func aMachineWithoutProviderKeysNeverRunsTheGuard() async throws {
        let recorder = RecordingTransport()
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "NPM_TOKEN", value: "npm-value")], scope: .all, source: .manual, sync: false)

        _ = await service.sync(machineID: "m1")

        #expect(recorder.commands.isEmpty)
        #expect(recorder.events == ["deliver:NPM_TOKEN"])
    }

    /// Holds a delivery open until the test releases it, and says when one started.
    final class GatedTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var entered: CheckedContinuation<Void, Never>?
        private var didEnter = false
        private var release: CheckedContinuation<Void, Never>?

        var transport: CloudSecretsService.Transport {
            CloudSecretsService.Transport(
                deliver: { _, _ in
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        self.lock.lock()
                        self.release = continuation
                        self.didEnter = true
                        let waiter = self.entered
                        self.entered = nil
                        self.lock.unlock()
                        waiter?.resume()
                    }
                },
                exec: { _, command in
                    let stdout = command.contains("cmux-provider-routing")
                        ? "CMUX-ROUTING-RESULT openai=ok anthropic=ok\n"
                        : ""
                    return VMExecResult(exitCode: 0, stdout: stdout, stderr: "")
                }
            )
        }

        /// Returns once a delivery is waiting on ``releaseDelivery()``.
        func waitForDelivery() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if didEnter {
                    lock.unlock()
                    continuation.resume()
                } else {
                    entered = continuation
                    lock.unlock()
                }
            }
        }

        func releaseDelivery() {
            lock.lock()
            let continuation = release
            release = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    @Test func forgettingAMachineDuringASyncDoesNotResurrectItsLedgerOrRouting() async throws {
        let gate = GatedTransport()
        let defaults = try #require(UserDefaults(suiteName: "cloud-secrets-tests-\(UUID().uuidString)"))
        let service = CloudSecretsService(
            vault: CloudSecretVault(storage: InMemoryCloudSecretVaultStorage()),
            transport: gate.transport,
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            observesMachineCreation: false
        )
        try await service.set([CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-proj-race")], scope: .all, source: .manual, sync: false)
        let inFlight = Task { @MainActor in await service.sync(machineID: "m1") }
        await gate.waitForDelivery()

        // The machine is destroyed while its delivery is still on the link.
        service.forgetMachine("m1")
        try await service.vault.forgetMachine("m1")
        gate.releaseDelivery()
        _ = await inFlight.value
        await service.reload()

        #expect(try await service.vault.delivery(for: "m1") == nil)
        #expect(service.delivery(for: "m1") == nil)
        #expect(defaults.string(forKey: CloudSecretsService.providerRoutingDefaultsKey(machineID: "m1")) == nil)
    }

    @Test func aFailedSyncRecordsItsErrorBeforeReturning() async throws {
        let recorder = RecordingTransport()
        recorder.failDelivery = CloudEnvDelivery.DeliveryError.receiverFailed("closed")
        let service = makeService(recorder)
        try await service.set([CloudSecretInput(name: "XAI_API_KEY", value: "xai-value")], scope: .all, source: .manual, sync: false)

        let failed = await service.sync(machineID: "m1")

        // Recorded in the chain, not by a detached task that could land after a
        // later sync succeeded.
        #expect(failed.error != nil)
        #expect(service.delivery(for: "m1")?.lastError == failed.error)

        recorder.failDelivery = nil
        let succeeded = await service.sync(machineID: "m1")
        #expect(succeeded.error == nil)
        #expect(service.delivery(for: "m1")?.lastError == nil)
        #expect(try await service.vault.delivery(for: "m1")?.lastError == nil)
    }

    // MARK: - vm.env_set provider routing

    @Test func envSetRoutesAProviderKeyBeforeDeliveringIt() async throws {
        let recorder = RecordingTransport()
        let transport = recorder.transport
        let entries = [
            CloudEnvDelivery.Entry(key: "OPENAI_API_KEY", value: "sk-proj-env-set"),
            CloudEnvDelivery.Entry(key: "OTHER", value: "x"),
        ]

        try await CloudSecretsProviderRouting.deliverGuarded(
            machineID: "m1", entries: entries, exec: transport.exec,
            deliver: { try await transport.deliver("m1", $0) }
        )

        // Protecting only: OpenAI's endpoint is added, Anthropic's left as it is.
        #expect(recorder.events == [
            "exec:" + CloudSecretsProviderRouting(openAI: .direct, anthropic: .keep).command,
            "deliver:OPENAI_API_KEY,OTHER",
        ])
        #expect(!recorder.commands.contains { $0.contains("sk-proj-env-set") })
    }

    @Test func envSetWithTheUsersOwnEndpointAddsNone() async throws {
        let routing = try #require(CloudSecretsProviderRouting(protectingNames: ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"]))
        #expect(routing == CloudSecretsProviderRouting(openAI: .keep, anthropic: .user))
        #expect(routing.companionEndpoints.isEmpty)
        #expect(CloudSecretsProviderRouting(protectingNames: ["OPENAI_BASE_URL", "DATABASE_URL"]) == nil)
    }

    @Test func envSetWithoutAProviderKeyRunsNoGuard() async throws {
        let recorder = RecordingTransport()
        let transport = recorder.transport
        try await CloudSecretsProviderRouting.deliverGuarded(
            machineID: "m1", entries: [CloudEnvDelivery.Entry(key: "DATABASE_URL", value: "postgres://x")],
            exec: transport.exec, deliver: { try await transport.deliver("m1", $0) }
        )
        #expect(recorder.commands.isEmpty)
        #expect(recorder.events == ["deliver:DATABASE_URL"])
    }

    @Test func envSetKeepsAProviderKeyOffAMachineWhoseGuardFailed() async throws {
        let recorder = RecordingTransport()
        recorder.execExitCode = { _ in 1 }
        let transport = recorder.transport
        await #expect(throws: (any Error).self) {
            try await CloudSecretsProviderRouting.deliverGuarded(
                machineID: "m1", entries: [CloudEnvDelivery.Entry(key: "ANTHROPIC_API_KEY", value: "sk-ant-env-set")],
                exec: transport.exec, deliver: { try await transport.deliver("m1", $0) }
            )
        }
        #expect(recorder.deliveries.isEmpty)
    }

    // MARK: - Partial delivery

    @Test func aProviderTheGuardCouldNotRouteHoldsBackOnlyItsKey() async throws {
        let recorder = RecordingTransport()
        recorder.guardStdout = "CMUX-ROUTING-RESULT openai=codex anthropic=ok\n"
        let service = makeService(recorder)
        try await service.set([
            CloudSecretInput(name: "GH_TOKEN", value: "ghp_partial"),
            CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-proj-partial"),
            CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-ant-partial"),
        ], scope: .all, source: .manual, sync: false)

        let result = await service.sync(machineID: "m1")

        // Everything not at risk lands; only the OpenAI key waits.
        #expect(recorder.deliveries.first?.entries.map(\.key) == ["ANTHROPIC_API_KEY", "GH_TOKEN"])
        #expect(result.sent == ["ANTHROPIC_API_KEY", "GH_TOKEN"])
        let message = try #require(result.error)
        #expect(message.contains("OPENAI_API_KEY"))
        #expect(message.contains("Codex"))
        #expect(!message.contains("could not update its environment"))
        #expect(!message.contains("sk-proj-partial"))
        #expect(service.delivery(for: "m1")?.delivered["OPENAI_API_KEY"] == nil)
        #expect(service.delivery(for: "m1")?.lastError == message)

        // The next sync, once the machine can route OpenAI, delivers the key.
        recorder.guardStdout = "CMUX-ROUTING-RESULT openai=ok anthropic=ok\n"
        let retry = await service.sync(machineID: "m1")
        #expect(retry.error == nil)
        #expect(recorder.deliveries.last?.entries.map(\.key).contains("OPENAI_API_KEY") == true)
        #expect(service.delivery(for: "m1")?.delivered["OPENAI_API_KEY"] != nil)
        #expect(service.delivery(for: "m1")?.lastError == nil)
    }

    @Test func aGuardWithoutAResultStillDeliversEveryKeyThatIsNotAProviderKey() async throws {
        let recorder = RecordingTransport()
        recorder.guardStdout = ""
        recorder.execExitCode = { command in command.contains("cmux-provider-routing") ? 1 : 0 }
        let service = makeService(recorder)
        try await service.set([
            CloudSecretInput(name: "DATABASE_URL", value: "postgres://partial"),
            CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-proj-noresult"),
        ], scope: .all, source: .manual, sync: false)

        let result = await service.sync(machineID: "m1")

        #expect(recorder.deliveries.first?.entries.map(\.key) == ["DATABASE_URL"])
        let message = try #require(result.error)
        #expect(message.contains("OPENAI_API_KEY"))
        #expect(message.contains("exit 1"))
    }

    @Test func envSetDeliversWhatIsSafeAndNamesWhatItHeldBack() async throws {
        let recorder = RecordingTransport()
        recorder.guardStdout = "CMUX-ROUTING-RESULT openai=ok anthropic=env\n"
        let transport = recorder.transport
        do {
            try await CloudSecretsProviderRouting.deliverGuarded(
                machineID: "m1",
                entries: [
                    CloudEnvDelivery.Entry(key: "OPENAI_API_KEY", value: "sk-proj-env"),
                    CloudEnvDelivery.Entry(key: "ANTHROPIC_API_KEY", value: "sk-ant-env"),
                ],
                exec: transport.exec, deliver: { try await transport.deliver("m1", $0) }
            )
            Issue.record("expected the held-back Anthropic key to be reported")
        } catch {
            #expect(error.localizedDescription.contains("ANTHROPIC_API_KEY"))
            #expect(!error.localizedDescription.contains("sk-ant-env"))
        }
        #expect(recorder.deliveries.first?.entries.map(\.key) == ["OPENAI_API_KEY"])
    }

    // MARK: - Socket parameters

    @Test func scopeParsingAcceptsWireValuesAndResolvesProjects() throws {
        #expect(try CloudSecretsSocketParams.scope([:], method: "m") == .all)
        #expect(try CloudSecretsSocketParams.scope([:], method: "m", defaultScope: nil) == nil)
        #expect(try CloudSecretsSocketParams.scope(["scope": "machine:m1"], method: "m") == .machine("m1"))
        #expect(try CloudSecretsSocketParams.scope(["scope": "project:https://github.com/Owner/Repo.git"], method: "m") == .project("github.com/owner/repo"))
        #expect(try CloudSecretsSocketParams.scope(["scope": "project", "project_remote_url": "git@github.com:Owner/Repo.git"], method: "m") == .project("github.com/owner/repo"))
        #expect(try CloudSecretsSocketParams.scope(["scope": "project", "project_dir_name": "scratch"], method: "m") == .project("local/scratch"))
        // A bare key is normalized like a remote: case, slashes and `.git`.
        #expect(try CloudSecretsSocketParams.scope(["scope": "project:GitHub.com/Owner/Repo.git/"], method: "m") == .project("github.com/owner/repo"))
        #expect(try CloudSecretsSocketParams.scope(["scope": "project", "project": "/github.com/owner/repo/"], method: "m") == .project("github.com/owner/repo"))
        // A local key keeps its directory name as given.
        #expect(try CloudSecretsSocketParams.scope(["scope": "project:local/Scratch/"], method: "m") == .project("local/Scratch"))
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
            ["entries": [["key": "line-one-secret-pasted-as-a-name", "value": "x"]]],
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
