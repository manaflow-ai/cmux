import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
/// The `debug.cloud_secrets.*` and `debug.cloud_getting_started.*` socket
/// verbs: param parsing, driving the real sheet model, and a state payload
/// that carries names and labels but never a secret value.
@MainActor
@Suite("Cloud debug socket probes")
struct CloudDebugProbeTests {
    private static let secretValue = "sk-live-debug-probe-4f7a9c"

    private func makeModel(vault: CloudSecretVault, machineID: String? = nil) -> CloudSecretsSheetModel {
        CloudSecretsSheetModel(
            machineID: machineID,
            backend: CloudSecretsSheetBackend(
                load: {
                    CloudSecretsSheetBackend.Snapshot(records: try await vault.records(), deliveries: try await vault.deliveries())
                },
                set: { inputs, scope, source in try await vault.set(inputs, scope: scope, source: source) },
                remove: { names, scope in try await vault.remove(names: names, scope: scope) },
                preview: { inputs, scope in try await vault.preview(inputs, scope: scope) },
                status: { _ in [] },
                sync: { _ in nil }
            ),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func action(_ params: [String: Any]) throws -> CloudDebugSecretsProbe.Action {
        try CloudDebugSecretsProbe.parseAction(params).get()
    }

    // MARK: Parsing

    @Test("Interact params parse into the model action they name")
    func parsesActions() throws {
        #expect(try action(["action": "select_tab", "tab": "project"]) == .selectTab(.project))
        #expect(try action(["action": "open_add", "preset_name": "OPENAI_API_KEY"]) == .openAdd(presetName: "OPENAI_API_KEY"))
        #expect(try action(["action": "open_add"]) == .openAdd(presetName: nil))
        #expect(try action(["action": "remove", "name": "DB_URL", "confirm": true]) == .remove(name: "DB_URL", scope: nil, confirm: true))
        #expect(try action(["action": "remove", "name": "DB_URL", "confirm": "false", "scope": "project:github.com/acme/api"])
            == .remove(name: "DB_URL", scope: .project("github.com/acme/api"), confirm: false))
        #expect(try action(["action": "remove", "name": "DB_URL"]) == .remove(name: "DB_URL", scope: nil, confirm: false))
        #expect(try action(["action": "import_text", "text": "A=1\n"]) == .importText(text: "A=1\n", sourceName: nil))
        #expect(try action(["action": "select_project"]) == .selectProject(nil))
        #expect(try action(["action": "sync_now"]).isAsync)
        #expect(try action(["action": "remove", "name": "X", "confirm": true]).isAsync)
        #expect(try !action(["action": "remove", "name": "X"]).isAsync)
        #expect(try !action(["action": "set_editor_value", "value": "v"]).isAsync)
    }

    @Test("Bad interact params fail without echoing a value")
    func rejectsBadParams() {
        let cases: [[String: Any]] = [
            [:],
            ["action": "launch"],
            ["action": "select_tab", "tab": "everything"],
            ["action": "set_editor_value"],
            ["action": "remove"],
            ["action": "select_row", "name": "A", "scope": "galaxy:far"],
        ]
        for params in cases {
            guard case .failure(let error) = CloudDebugSecretsProbe.parseAction(params) else {
                Issue.record("expected \(params.keys.sorted()) to fail")
                continue
            }
            #expect(!error.message.isEmpty)
        }
        let valueParams: [String: Any] = ["action": "nope", "value": Self.secretValue]
        if case .failure(let error) = CloudDebugSecretsProbe.parseAction(valueParams) {
            #expect(!error.message.contains(Self.secretValue))
        }
    }

    // MARK: Driving the model

    @Test("A value typed into the editor is saved but never appears in state")
    func editorValueNeverEchoes() async throws {
        let vault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        let model = makeModel(vault: vault)
        await model.load()

        var state = CloudDebugSecretsProbe.state(model, busy: false)
        #expect(state["body"] as? String == "empty_state")
        #expect(state["empty_state_visible"] as? Bool == true)

        #expect(CloudDebugSecretsProbe.performSync(.openAdd(presetName: "OPENAI_API_KEY"), on: model) == .applied)
        #expect(CloudDebugSecretsProbe.performSync(.setEditorValue(Self.secretValue), on: model) == .applied)
        state = CloudDebugSecretsProbe.state(model, busy: false)
        let editor = try #require(state["editor"] as? [String: Any])
        #expect(editor["name"] as? String == "OPENAI_API_KEY")
        #expect(editor["value_entered"] as? Bool == true)
        #expect(editor["can_save"] as? Bool == true)
        #expect(try !json(state).contains(Self.secretValue))

        #expect(await CloudDebugSecretsProbe.perform(.save, on: model) == .applied)
        state = CloudDebugSecretsProbe.state(model, busy: false)
        #expect(state["editor"] == nil)
        let rows = try #require(state["rows"] as? [[String: Any]])
        #expect(rows.map { $0["name"] as? String } == ["OPENAI_API_KEY"])
        let mask = try #require(rows.first?["fingerprint_mask"] as? String)
        #expect(mask.hasPrefix("\u{2022}\u{2022}\u{2022}\u{2022} "))
        #expect(rows.first?["selected"] as? Bool == true)
        #expect(try !json(state).contains(Self.secretValue))
        #expect(try await vault.records().map(\.name) == ["OPENAI_API_KEY"])
    }

    @Test("Import text previews names and kinds, then commits through the model")
    func importPreviewAndCommit() async throws {
        let vault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        let model = makeModel(vault: vault)
        await model.load()

        let text = "ANTHROPIC_API_KEY=\(Self.secretValue)\nOTHER_TOKEN=nope-value\n"
        #expect(await CloudDebugSecretsProbe.perform(.importText(text: text, sourceName: nil), on: model) == .applied)
        let state = CloudDebugSecretsProbe.state(model, busy: false)
        #expect(state["body"] as? String == "import_preview")
        let preview = try #require(state["import_preview"] as? [String: Any])
        let rows = try #require(preview["rows"] as? [[String: Any]])
        #expect(rows.compactMap { $0["name"] as? String } == ["ANTHROPIC_API_KEY", "OTHER_TOKEN"])
        #expect(rows.allSatisfy { $0["kind"] as? String == "added" })
        #expect(preview["can_commit"] as? Bool == true)
        let payload = try json(state)
        #expect(!payload.contains(Self.secretValue))
        #expect(!payload.contains("nope-value"))

        #expect(CloudDebugSecretsProbe.preflight(.importCommit, on: model) == nil)
        #expect(await CloudDebugSecretsProbe.perform(.importCommit, on: model) == .applied)
        #expect(model.importDraft == nil)
        #expect(try await Set(vault.records().map(\.name)) == ["ANTHROPIC_API_KEY", "OTHER_TOKEN"])
    }

    @Test("Skipped import lines report kind skipped, not unchanged")
    func importSkippedKind() async throws {
        let vault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        let model = makeModel(vault: vault)
        await model.load()

        let text = "GOOD_KEY=\(Self.secretValue)\nnot a line\nEMPTY_ONE=\n"
        #expect(await CloudDebugSecretsProbe.perform(.importText(text: text, sourceName: nil), on: model) == .applied)
        let state = CloudDebugSecretsProbe.state(model, busy: false)
        let preview = try #require(state["import_preview"] as? [String: Any])
        let rows = try #require(preview["rows"] as? [[String: Any]])
        let kinds = rows.compactMap { $0["kind"] as? String }
        #expect(kinds == ["added", "skipped", "skipped"])
        #expect(rows.dropFirst().allSatisfy { $0["kind_title"] as? String == "Skipped" })
        #expect(try !json(state).contains(Self.secretValue))
    }

    @Test("Remove without confirm leaves the dialog pending; with confirm deletes")
    func removeFlow() async throws {
        let vault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        try await vault.set([CloudSecretInput(name: "DB_URL", value: "postgres://x")], scope: .all, source: .manual)
        let model = makeModel(vault: vault)
        await model.load()

        #expect(CloudDebugSecretsProbe.performSync(.remove(name: "MISSING", scope: nil, confirm: false), on: model) == .notFound("no secret named MISSING"))
        #expect(CloudDebugSecretsProbe.performSync(.remove(name: "DB_URL", scope: nil, confirm: false), on: model) == .applied)
        let pending = try #require(CloudDebugSecretsProbe.state(model, busy: false)["pending_removal"] as? [String: String])
        #expect(pending["name"] == "DB_URL")
        #expect(CloudDebugSecretsProbe.performSync(.cancelRemove, on: model) == .applied)
        #expect(model.pendingRemoval == nil)

        #expect(CloudDebugSecretsProbe.performSync(.remove(name: "DB_URL", scope: nil, confirm: true), on: model) == nil)
        #expect(await CloudDebugSecretsProbe.perform(.remove(name: "DB_URL", scope: nil, confirm: true), on: model) == .applied)
        #expect(try await vault.records().isEmpty)
    }

    @Test("Model guards come back as ignored, not applied")
    func guardsReportIgnored() async {
        let vault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        let model = makeModel(vault: vault)
        await model.load()
        #expect(CloudDebugSecretsProbe.performSync(.setEditorName("A"), on: model) == .ignored("no editor is open"))
        #expect(CloudDebugSecretsProbe.preflight(.save, on: model) == .ignored("the editor cannot save yet"))
        #expect(CloudDebugSecretsProbe.preflight(.syncNow, on: model) == .ignored("Sync Now needs a sheet opened for a machine"))
        #expect(CloudDebugSecretsProbe.performSync(.selectTab(.machine), on: model) == .applied)
        #expect(CloudDebugSecretsProbe.performSync(.openAdd(presetName: nil), on: model) == .ignored("add is unavailable on this tab"))
    }

    @Test("Redaction scrubs held values from nested strings")
    func redactsNestedStrings() {
        let object: [String: Any] = [
            "error": "bad \(Self.secretValue) here",
            "rows": [["problem": Self.secretValue], ["name": "A"]],
            "count": 3,
        ]
        let scrubbed = CloudDebugSecretsProbe.redacting(object, values: [Self.secretValue, "x"]) as? [String: Any]
        #expect(scrubbed?["error"] as? String == "bad [redacted] here")
        let rows = scrubbed?["rows"] as? [[String: Any]]
        #expect(rows?.first?["problem"] as? String == "[redacted]")
        #expect(rows?.last?["name"] as? String == "A")
        #expect(scrubbed?["count"] as? Int == 3)
    }

    // MARK: Getting started

    @Test("Getting started press and copy follow the card's current step")
    func gettingStartedMapping() {
        let withSheet = CloudGettingStartedActions(openSecrets: {}, createMachine: {}, openLocalAgent: {}, dismiss: {})
        let bare = CloudGettingStartedActions(openSecrets: nil, createMachine: {}, openLocalAgent: nil, dismiss: {})
        typealias Probe = CloudDebugGettingStartedProbe
        #expect(Probe.press(for: .addKeys, actions: withSheet) == .openSecrets)
        #expect(Probe.press(for: .addKeys, actions: bare) == .noButton)
        #expect(Probe.press(for: .createMachine, actions: bare) == .createMachine)
        #expect(Probe.press(for: .startAgent, actions: withSheet) == .openLocalAgent)
        #expect(Probe.press(for: .startAgent, actions: bare) == .noButton)
        #expect(Probe.command(for: .addKeys, actions: bare) == CloudGettingStartedChecklist.importKeysCommand)
        #expect(Probe.command(for: .addKeys, actions: withSheet) == nil)
        #expect(Probe.command(for: .startAgent, actions: withSheet) == CloudGettingStartedChecklist.startAgentCommand())
        #expect(Probe.command(for: nil, actions: withSheet) == nil)
    }

    @Test("Getting started state reports steps, progress and the current step")
    func gettingStartedState() throws {
        let checklist = CloudGettingStartedChecklist(.init(
            secretCount: 2,
            machineCount: 0,
            hasCloudAgent: false,
            hasLoadedMachines: true,
            hasListProblem: false,
            isDismissed: false
        ))
        let entry = CloudDebugGettingStartedProbe.Entry(
            checklist: checklist,
            actions: { CloudGettingStartedActions(openSecrets: nil, createMachine: {}, openLocalAgent: nil, dismiss: {}) },
            window: nil
        )
        let state = CloudDebugGettingStartedProbe.state(entry, mountedCount: 1)
        #expect(state["visible"] as? Bool == true)
        #expect(state["completed_count"] as? Int == 1)
        #expect(state["total_count"] as? Int == 3)
        #expect(state["current_step"] as? String == "createMachine")
        #expect(state["current_press"] as? String == "createMachine")
        let steps = try #require(state["steps"] as? [[String: Any]])
        #expect(steps.compactMap { $0["id"] as? String } == ["addKeys", "createMachine", "startAgent"])
        #expect(steps.first?["done"] as? Bool == true)

        let unmounted = CloudDebugGettingStartedProbe.state(nil, mountedCount: 0)
        #expect(unmounted["mounted"] as? Bool == false)
    }
}
#endif
