import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Cloud Secrets sheet against a real in-memory vault: what each tab
/// lists, the import diff before commit, removal, and per-machine row state.
@MainActor
@Suite("Cloud Secrets sheet")
struct CloudSecretsSheetModelTests {
    @MainActor
    final class Harness {
        let vault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        var statusRows: [CloudSecretMachineStatusRow] = []
        var syncedMachines: [String] = []
        var syncError: String?
        var setCalls: [(names: [String], scope: CloudSecretScope)] = []

        var declaredReads: [URL] = []

        func model(
            machineID: String? = nil,
            label: String? = nil,
            withPreview: Bool = true,
            checkout: CloudSecretProjectCheckout? = nil,
            declared: [CloudSecretRequirement] = []
        ) -> CloudSecretsSheetModel {
            let vault = vault
            var preview: (@MainActor ([CloudSecretInput], CloudSecretScope) async throws -> [CloudSecretChange])?
            if withPreview {
                preview = { inputs, scope in try await vault.preview(inputs, scope: scope) }
            }
            return CloudSecretsSheetModel(
                machineID: machineID,
                machineLabel: label,
                contextCheckout: checkout,
                backend: CloudSecretsSheetBackend(
                    load: {
                        CloudSecretsSheetBackend.Snapshot(records: try await vault.records(), deliveries: try await vault.deliveries())
                    },
                    set: { inputs, scope, source in
                        self.setCalls.append((inputs.map(\.name), scope))
                        return try await vault.set(inputs, scope: scope, source: source)
                    },
                    remove: { names, scope in try await vault.remove(names: names, scope: scope) },
                    preview: preview,
                    status: { _ in self.statusRows },
                    sync: { id in
                        self.syncedMachines.append(id)
                        return self.syncError
                    },
                    declared: { root in
                        self.declaredReads.append(root)
                        return declared
                    }
                ),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            )
        }
    }

    @MainActor
    final class FinishCounter {
        var count = 0
    }

    @Test("Tabs list only their scope, and Add writes to the selected tab's scope")
    func tabsFilterByScope() async throws {
        let harness = Harness()
        try await harness.vault.set([CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-one")], scope: .all, source: .manual)
        try await harness.vault.set([CloudSecretInput(name: "DB_URL", value: "postgres://x")], scope: .project("github.com/acme/api"), source: .manual)
        try await harness.vault.set([CloudSecretInput(name: "ONLY_HERE", value: "1")], scope: .machine("vm-1"), source: .manual)
        let model = harness.model(machineID: "vm-1", label: "Big Machine")
        await model.load()

        #expect(model.visibleRecords.map(\.name) == ["OPENAI_API_KEY"])
        #expect(model.count(for: .project) == 1)
        model.tab = .machine
        #expect(model.visibleRecords.map(\.name) == ["ONLY_HERE"])
        #expect(model.scopeForNewSecret == .machine("vm-1"))

        model.tab = .all
        model.beginAdd(name: "ANTHROPIC_API_KEY")
        model.editor?.value = "  sk-ant-secret\n"
        await model.saveEditor()
        #expect(model.editor == nil)
        #expect(harness.setCalls.last?.scope == .all)
        #expect(model.visibleRecords.map(\.name) == ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"])
        // The trimmed value was stored: saving the same key with no whitespace is unchanged.
        let changes = try await harness.vault.preview([CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-ant-secret")], scope: .all)
        #expect(changes.map(\.kind) == [.unchanged])
    }

    @Test("Presets already stored in the tab's scope are not offered again")
    func presetsHideStoredNames() async throws {
        let harness = Harness()
        try await harness.vault.set([CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "a")], scope: .all, source: .manual)
        let model = harness.model()
        await model.load()
        let names = model.availablePresets.map(\.name)
        #expect(!names.contains("ANTHROPIC_API_KEY"))
        #expect(names.contains("OPENAI_API_KEY"))
        #expect(names.count == 4)
    }

    @Test("An invalid name is refused in the editor without reaching the vault")
    func editorRejectsReservedName() async {
        let harness = Harness()
        let model = harness.model()
        await model.load()
        model.beginAdd(name: "PATH")
        model.editor?.value = "/usr/bin"
        await model.saveEditor()
        #expect(model.editor?.error != nil)
        #expect(harness.setCalls.isEmpty)
    }

    @Test("Import previews new, replaced, unchanged and skipped names, then stores only changes")
    func importPreviewThenCommit() async throws {
        let harness = Harness()
        try await harness.vault.set([
            CloudSecretInput(name: "SAME", value: "1"),
            CloudSecretInput(name: "CHANGED", value: "old"),
        ], scope: .all, source: .manual)
        let model = harness.model()
        await model.load()

        let text = """
        # local keys
        export SAME=1
        CHANGED="new"
        FRESH=abc
        CMUX_TOKEN=nope
        """
        await model.beginImport(text: text, sourceName: ".env", source: .dotenv(".env"))
        let draft = try #require(model.importDraft)
        let kinds = Dictionary(uniqueKeysWithValues: draft.preview.rows.map { ($0.name, $0.problem == nil ? $0.kind.rawValue : "skipped") })
        #expect(kinds == ["SAME": "unchanged", "CHANGED": "updated", "FRESH": "added", "CMUX_TOKEN": "skipped"])
        #expect(draft.preview.inputsToCommit.map(\.name) == ["CHANGED", "FRESH"])
        // Nothing is stored before Import.
        #expect(harness.setCalls.isEmpty)

        await model.commitImport()
        #expect(model.importDraft == nil)
        #expect(harness.setCalls.map(\.names) == [["CHANGED", "FRESH"]])
        let record = try #require(model.records.first { $0.name == "FRESH" })
        #expect(record.source == .dotenv(".env"))
    }

    @Test("Without a dry run, a name already in the scope reads as replaced")
    func importPreviewFallback() async throws {
        let harness = Harness()
        try await harness.vault.set([CloudSecretInput(name: "KEEP", value: "1")], scope: .all, source: .manual)
        let model = harness.model(withPreview: false)
        await model.load()
        await model.beginImport(text: "KEEP=1\nNEW=2\n", sourceName: "x.env", source: .dotenv("x.env"))
        let rows = try #require(model.importDraft?.preview.rows)
        #expect(rows.map(\.kind) == [.updated, .added])
    }

    @Test("A bad line or an empty value is a skipped row; the rest still imports")
    func importSkipsBadLinesAndKeepsTheRest() async throws {
        let harness = Harness()
        let model = harness.model()
        await model.load()
        let text = "OK=1\nsk-bare-token-line\nEMPTY=\nALSO_OK=2\n"
        await model.beginImport(text: text, sourceName: ".env", source: .dotenv(".env"))
        #expect(model.actionError == nil)
        let draft = try #require(model.importDraft)
        #expect(draft.preview.inputsToCommit.map(\.name) == ["OK", "ALSO_OK"])
        let skipped = draft.preview.rows.filter { $0.problem != nil }
        #expect(skipped.map(\.line) == [2, 3])
        #expect(skipped.map(\.name) == ["Line 2", "EMPTY"])
        #expect(skipped.first?.problem == "Skipped (not NAME=value, line 2)")
        // The bare line may be a value: no row shows its text.
        #expect(!draft.preview.rows.contains { $0.name.contains("sk-") || ($0.problem ?? "").contains("sk-") })
        #expect(CloudSecretsSheetPresentation.importSummary(draft.preview) == "New: 2 \u{00B7} Skipped: 2")

        await model.commitImport()
        #expect(harness.setCalls.map(\.names) == [["OK", "ALSO_OK"]])
    }

    @Test("A file with only bad lines previews them and cannot be imported")
    func importOnlyBadLines() async throws {
        let harness = Harness()
        let model = harness.model()
        await model.load()
        await model.beginImport(text: "not a line\n", sourceName: ".env", source: .dotenv(".env"))
        let draft = try #require(model.importDraft)
        #expect(!draft.preview.canCommit)
        #expect(draft.preview.problemCount == 1)
        await model.beginImport(text: "# only comments\n", sourceName: ".env", source: .dotenv(".env"))
        #expect(model.actionError != nil)
    }

    @Test("Delete asks first, and only the confirmation removes")
    func removalNeedsConfirmation() async throws {
        let harness = Harness()
        try await harness.vault.set([CloudSecretInput(name: "GONE", value: "1")], scope: .all, source: .manual)
        let model = harness.model()
        await model.load()
        #expect(!model.requestRemovalOfSelection())
        model.selectionID = try #require(model.visibleRecords.first).sheetID
        #expect(model.requestRemovalOfSelection())
        #expect(model.pendingRemoval?.name == "GONE")
        let stored = try await harness.vault.records()
        #expect(stored.count == 1)
        await model.confirmRemoval()
        #expect(model.records.isEmpty)
        #expect(model.isEmptyVault)
    }

    @Test("Esc closes the open card before the sheet")
    func escapeClosesInnermostFirst() async {
        let harness = Harness()
        let model = harness.model()
        let finished = FinishCounter()
        model.onFinished = { finished.count += 1 }
        await model.load()
        model.beginAdd()
        model.cancel()
        #expect(model.editor == nil)
        #expect(finished.count == 0)
        model.cancel()
        #expect(finished.count == 1)
    }

    @Test("Machine rows show their own state, or that a more specific scope wins")
    func machineRowState() async throws {
        let harness = Harness()
        try await harness.vault.set([CloudSecretInput(name: "TOKEN", value: "all")], scope: .all, source: .manual)
        try await harness.vault.set([CloudSecretInput(name: "TOKEN", value: "mine")], scope: .machine("vm-1"), source: .manual)
        try await harness.vault.set([CloudSecretInput(name: "OTHER", value: "x")], scope: .all, source: .manual)
        harness.statusRows = [
            CloudSecretMachineStatusRow(name: "TOKEN", scope: .machine("vm-1"), state: .stale, fingerprint: nil),
            CloudSecretMachineStatusRow(name: "OTHER", scope: .all, state: .current, fingerprint: nil),
            CloudSecretMachineStatusRow(name: "OLD", scope: nil, state: .extra, fingerprint: nil),
        ]
        let model = harness.model(machineID: "vm-1", label: "Big Machine")
        await model.load()

        let allToken = try #require(model.visibleRecords.first { $0.name == "TOKEN" })
        #expect(model.rowState(for: allToken) == .overridden(by: .machine("vm-1")))
        let other = try #require(model.visibleRecords.first { $0.name == "OTHER" })
        #expect(model.rowState(for: other) == .machine(.current))
        model.tab = .machine
        let mine = try #require(model.visibleRecords.first)
        #expect(model.rowState(for: mine) == .machine(.stale))
        #expect(model.extraNames == ["OLD"])
        #expect(CloudSecretsSheetPresentation.needsSync(model.statusRows))

        await model.syncNow()
        #expect(harness.syncedMachines == ["vm-1"])
        #expect(model.didSync)
        harness.syncError = "Could not reach the machine."
        await model.syncNow()
        #expect(model.syncError == "Could not reach the machine.")
        #expect(!model.didSync)
    }

    @Test("A project secret shows Overridden only on a machine linked to that project")
    func projectOverrideNeedsLink() {
        let record = CloudSecretRecord(
            name: "DB_URL", scope: .project("github.com/acme/other"), fingerprint: "00000000",
            createdAt: .distantPast, updatedAt: .distantPast, source: .manual
        )
        let rows = [CloudSecretMachineStatusRow(name: "DB_URL", scope: .machine("vm-1"), state: .current, fingerprint: nil)]
        #expect(CloudSecretsSheetPresentation.rowState(for: record, statusRows: rows) == nil)
        #expect(CloudSecretsSheetPresentation.rowState(for: record, statusRows: rows, linkedProjects: ["github.com/acme/other"])
            == .overridden(by: .machine("vm-1")))
    }

    @Test("Relative labels round the first minute and future times to just now")
    func relativeLabels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        let justNow = CloudSecretsSheetPresentation.updatedLabel(now.addingTimeInterval(-30), now: now, locale: english)
        #expect(CloudSecretsSheetPresentation.updatedLabel(now.addingTimeInterval(120), now: now, locale: english) == justNow)
        let twoHours = CloudSecretsSheetPresentation.updatedLabel(now.addingTimeInterval(-7_200), now: now, locale: english)
        #expect(twoHours != justNow)
        #expect(twoHours.contains("2"))
        #expect(CloudSecretsSheetPresentation.deliveredLabel(nil, now: now, locale: english)
            != CloudSecretsSheetPresentation.deliveredLabel(now, now: now, locale: english))
    }

    @Test("Scope labels and fingerprints never need the value")
    func labels() {
        #expect(CloudSecretsSheetPresentation.shortProjectLabel("github.com/acme/api") == "acme/api")
        #expect(CloudSecretsSheetPresentation.shortProjectLabel("local/scratch") == "scratch")
        #expect(CloudSecretsSheetPresentation.scopePill(.all, machineLabels: [:]) == nil)
        #expect(CloudSecretsSheetPresentation.scopePill(.machine("vm-1"), machineLabels: ["vm-1": "Big"]) == "Big")
        #expect(CloudSecretsSheetPresentation.maskedFingerprint("3f9a1c2e") == "\u{2022}\u{2022}\u{2022}\u{2022} 3f9a1c2e")
        #expect(CloudSecretsSheetPresentation.normalizedProjectKey("git@github.com:Acme/API.git") == "github.com/acme/api")
        #expect(CloudSecretsSheetPresentation.normalizedProjectKey("  ") == nil)
    }

    // MARK: Repository-declared names

    @Test("The Project tab lists the checkout's unset names as ghost rows, and Set… opens a prefilled editor")
    func declaredNamesShowAsGhostRows() async throws {
        let harness = Harness()
        let project = "github.com/acme/api"
        try await harness.vault.set([CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-all")], scope: .all, source: .manual)
        try await harness.vault.set([CloudSecretInput(name: "STRIPE_KEY", value: "sk-other")], scope: .project("github.com/acme/web"), source: .manual)
        let checkout = CloudSecretProjectCheckout(root: URL(fileURLWithPath: "/tmp/acme-api"), projectKey: project)
        let declared = [
            CloudSecretRequirement(name: "ANTHROPIC_API_KEY", description: nil, source: ".cmux/cloud.json"),
            CloudSecretRequirement(name: "DATABASE_URL", description: "Postgres for tests", source: ".cmux/cloud.json"),
            CloudSecretRequirement(name: "STRIPE_KEY", description: nil, source: ".devcontainer/devcontainer.json"),
        ]
        let model = harness.model(checkout: checkout, declared: declared)
        await model.load()

        #expect(harness.declaredReads == [checkout.root])
        #expect(model.projectKey == project, "opened from a checkout, the Project tab starts on its project")
        #expect(model.unsetRequirements.isEmpty, "ghost rows belong to the Project tab only")
        model.tab = .project
        // An all-machines secret covers the name; another project's does not.
        #expect(model.unsetRequirements.map(\.name) == ["DATABASE_URL", "STRIPE_KEY"])
        #expect(model.unsetRequirementsProjectLabel == "acme/api")
        #expect(CloudSecretsSheetPresentation.requirementDetail(projectLabel: "acme/api").contains("acme/api"))

        model.projectKey = "github.com/acme/web"
        #expect(model.unsetRequirements.isEmpty, "another project's view does not show this checkout's needs")
        model.projectKey = nil
        #expect(model.unsetRequirements.count == 2)

        let databaseURL = try #require(model.unsetRequirements.first)
        model.beginSetRequirement(databaseURL)
        #expect(model.editor?.name == "DATABASE_URL")
        #expect(model.editor?.projectText == project)
        #expect(model.editor?.hint?.contains("Postgres for tests") == true)
        #expect(model.editorScope == .project(project))
        model.editor?.value = "postgres://localhost/test"
        await model.saveEditor()
        #expect(harness.setCalls.last?.names == ["DATABASE_URL"])
        #expect(harness.setCalls.last?.scope == .project(project))
        #expect(model.unsetRequirements.map(\.name) == ["STRIPE_KEY"], "a saved name leaves the ghost rows")
    }

    @Test("Without a checkout, or from a machine, no declared names are read")
    func noCheckoutNoGhostRows() async {
        let harness = Harness()
        let model = harness.model(declared: [CloudSecretRequirement(name: "DATABASE_URL", description: nil, source: ".cmux/cloud.json")])
        await model.load()
        model.tab = .project
        #expect(model.unsetRequirements.isEmpty)
        #expect(harness.declaredReads.isEmpty)
        #expect(model.projectKey == nil)

        let checkout = CloudSecretProjectCheckout(root: URL(fileURLWithPath: "/tmp/x"), projectKey: "local/x")
        let machineModel = harness.model(machineID: "vm-1", checkout: checkout)
        await machineModel.load()
        #expect(machineModel.projectKey != "local/x", "a machine's sheet keeps its linked project")
    }
}
