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
        /// What the host remembers each project declaring (a `vm clone` check).
        var declaredByProject: [String: [CloudSecretRequirement]] = [:]
        var declaredProjectReads: [String] = []
        /// When set, writes from the sheet run a background delivery; each run
        /// records what the sheet showed while it was in flight.
        var autoSyncEnabled = false
        weak var observed: CloudSecretsSheetModel?
        var deliveringDuringAutoSync: [Bool] = []

        func model(
            machineID: String? = nil,
            label: String? = nil,
            withPreview: Bool = true,
            checkout: CloudSecretProjectCheckout? = nil,
            declared: [CloudSecretRequirement] = [],
            cloudMachineID: String? = nil,
            directoryName: String? = nil
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
                contextMachineID: cloudMachineID,
                contextDirectoryName: directoryName,
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
                    },
                    declaredForProject: { key in
                        self.declaredProjectReads.append(key)
                        return self.declaredByProject[key] ?? []
                    },
                    autoSync: {
                        guard self.autoSyncEnabled else { return nil }
                        return { self.deliveringDuringAutoSync.append(self.observed?.isDelivering ?? false) }
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

        #expect(model.tab == .machine, "a machine's sheet opens on that machine")
        #expect(model.scopeForNewSecret == .machine("vm-1"), "so Add writes to that machine")
        model.tab = .all
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
        // What Import does with each row; a skipped row is never "unchanged".
        let dispositions = Dictionary(uniqueKeysWithValues: draft.preview.rows.map { ($0.name, $0.disposition) })
        #expect(dispositions == kinds)
        // A reserved name needs renaming; it is the only row that asks for attention.
        #expect(draft.preview.rows.filter(\.needsAttention).map(\.name) == ["CMUX_TOKEN"])
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
        // Skipping a bad line is expected: quiet, and reported as skipped.
        #expect(skipped.allSatisfy { !$0.needsAttention && $0.disposition == "skipped" })
        #expect(skipped.map { CloudSecretsSheetPresentation.importRowTitle($0) } == ["Skipped", "Skipped"])
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
        model.tab = .all

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

    @Test("A delivery after a save reads as Syncing, not as missing, until it finishes")
    func autoSyncAfterSaveShowsSyncing() async throws {
        let harness = Harness()
        harness.autoSyncEnabled = true
        harness.statusRows = [
            CloudSecretMachineStatusRow(name: "OPENAI_API_KEY", scope: .all, state: .missing, fingerprint: nil),
        ]
        let model = harness.model(machineID: "vm-1", label: "Big Machine")
        harness.observed = model
        await model.load()
        model.tab = .all
        #expect(!model.isDelivering)

        model.beginAdd(name: "OPENAI_API_KEY")
        model.editor?.value = "sk-one"
        await model.saveEditor()
        let task = try #require(model.autoSyncTask)
        await task.value
        #expect(harness.deliveringDuringAutoSync == [true], "the sheet knew a delivery was in flight while it ran")
        #expect(model.pendingAutoSyncs == 0)
        #expect(!model.isDelivering)
        let record = try #require(model.visibleRecords.first)
        #expect(model.rowState(for: record) == .machine(.missing), "after the delivery the real state shows again")
    }

    @Test("A sync someone else started shows the machine as Syncing, never as missing")
    func externalSyncShowsSyncing() async throws {
        let harness = Harness()
        try await harness.vault.set([CloudSecretInput(name: "OPENAI_API_KEY", value: "sk")], scope: .all, source: .manual)
        try await harness.vault.set([CloudSecretInput(name: "GH_TOKEN", value: "gh")], scope: .all, source: .manual)
        harness.statusRows = [
            CloudSecretMachineStatusRow(name: "OPENAI_API_KEY", scope: .all, state: .missing, fingerprint: nil),
            CloudSecretMachineStatusRow(name: "GH_TOKEN", scope: .all, state: .current, fingerprint: nil),
        ]
        let model = harness.model(machineID: "vm-1", label: "Big Machine")
        await model.load()
        model.tab = .all
        let missing = try #require(model.visibleRecords.first { $0.name == "OPENAI_API_KEY" })
        let current = try #require(model.visibleRecords.first { $0.name == "GH_TOKEN" })
        #expect(model.rowState(for: missing) == .machine(.missing))
        #expect(CloudSecretsSheetPresentation.machineSummary(model.statusRows, isDelivering: model.isDelivering) == "Up to date: 1 of 2")

        model.setExternalSyncInFlight(true)
        #expect(model.isDelivering)
        #expect(model.rowState(for: missing) == .syncing)
        #expect(model.rowState(for: current) == .machine(.current), "a current value stays current")
        #expect(CloudSecretsSheetPresentation.machineSummary(model.statusRows, isDelivering: model.isDelivering) == "Syncing\u{2026}")

        model.setExternalSyncInFlight(false)
        #expect(!model.isDelivering)
        #expect(model.rowState(for: missing) == .machine(.missing))

        // The sheet not about a machine never claims a delivery.
        let plain = harness.model()
        plain.setExternalSyncInFlight(true)
        #expect(!plain.isDelivering)
    }

    @Test("Rows show a chip only when the machine differs from the vault")
    func chipsOnlyForNonCurrent() {
        #expect(CloudSecretsSheetPresentation.visibleChip(.machine(.current)) == nil)
        #expect(CloudSecretsSheetPresentation.visibleChip(nil) == nil)
        #expect(CloudSecretsSheetPresentation.visibleChip(.machine(.stale)) == .machine(.stale))
        #expect(CloudSecretsSheetPresentation.visibleChip(.syncing) == .syncing)
        #expect(CloudSecretsSheetPresentation.visibleChip(.overridden(by: .all)) == .overridden(by: .all))
    }

    @Test("Credential copy uses the provider's word and a correct article")
    func credentialCopy() throws {
        let anthropic = try #require(CloudSecretCatalog.presets.first { $0.name == "ANTHROPIC_API_KEY" })
        let github = try #require(CloudSecretCatalog.presets.first { $0.name == "GH_TOKEN" })
        let openAI = try #require(CloudSecretCatalog.presets.first { $0.name == "OPENAI_API_KEY" })
        #expect(CloudSecretsSheetPresentation.credentialLink(anthropic) == "Get an API key from Anthropic")
        #expect(CloudSecretsSheetPresentation.credentialLink(openAI) == "Get an API key from OpenAI")
        #expect(CloudSecretsSheetPresentation.credentialLink(github) == "Get a token from GitHub")
        #expect(CloudSecretsSheetPresentation.valuePlaceholder(github) == "Paste the token")
        #expect(CloudSecretsSheetPresentation.valuePlaceholder(anthropic) == "Paste the API key")
        #expect(CloudSecretsSheetPresentation.valuePlaceholder(nil) == "Paste the value")
        #expect(CloudSecretsSheetPresentation.presetAccessibility(github) == "Add GitHub token")
    }

    @Test("The editor's preset follows the typed name, so GH_TOKEN asks for a token")
    func editorPresetFollowsName() async {
        let harness = Harness()
        let model = harness.model()
        await model.load()
        model.beginAdd(name: "GH_TOKEN")
        #expect(model.editorPreset?.credential == .token)
        model.editor?.name = "MY_OWN_THING"
        #expect(model.editorPreset == nil)
    }

    @Test("Removing asks in one sentence who loses the secret")
    func removalSentence() {
        #expect(CloudSecretsSheetPresentation.removalMessage(.all, machineLabels: [:]) == "Machines lose it on their next sync.")
        #expect(CloudSecretsSheetPresentation.removalMessage(.project("github.com/acme/api"), machineLabels: [:])
            == "Machines linked to acme/api lose it on their next sync.")
        #expect(CloudSecretsSheetPresentation.removalMessage(.machine("vm-1"), machineLabels: ["vm-1": "Big"]) == "Big loses it on its next sync.")
    }

    @Test("A project shows as typed, while its key stays normalized")
    func projectShowsAsTyped() async throws {
        let harness = Harness()
        let model = harness.model()
        await model.load()
        model.tab = .project
        model.beginAdd(name: "GH_TOKEN")
        model.editor?.projectText = "https://github.com/Octocat/Hello-World.git"
        model.editor?.value = "ghp_x"
        #expect(model.editorScope == .project("github.com/octocat/hello-world"))
        await model.saveEditor()
        #expect(harness.setCalls.last?.scope == .project("github.com/octocat/hello-world"))
        #expect(model.projectLabel("github.com/octocat/hello-world") == "Octocat/Hello-World")
        #expect(CloudSecretsSheetPresentation.scopePill(
            .project("github.com/octocat/hello-world"), machineLabels: [:], projectLabels: model.projectDisplayNames
        ) == "Octocat/Hello-World")

        #expect(CloudSecretsSheetPresentation.typedProjectLabel("github.com/octocat/hello-world", key: "github.com/octocat/hello-world") == nil,
                "lowercase text adds nothing over the key")
        #expect(CloudSecretsSheetPresentation.typedProjectLabel("Something/Else", key: "github.com/octocat/hello-world") == nil)
        // Another host keeps its host; GitHub's owner/repo is the usual short form.
        #expect(CloudSecretsSheetPresentation.shortProjectLabel("gitlab.com/acme/api") == "gitlab.com/acme/api")
    }

    @Test("Row ages drop the repeated Updated and keep it for help text")
    func ageLabels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        #expect(CloudSecretsSheetPresentation.ageLabel(now.addingTimeInterval(-10), now: now, locale: english) == "just now")
        let twoHours = CloudSecretsSheetPresentation.ageLabel(now.addingTimeInterval(-7_200), now: now, locale: english)
        #expect(twoHours.contains("2"))
        #expect(!twoHours.contains("Updated"))
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
    // MARK: Ghost rows away from a local checkout

    @Test("A machine's sheet lists what its linked project declares, on its own tab, from the remembered check")
    func machineSheetShowsLinkedProjectNeeds() async throws {
        let harness = Harness()
        let project = "github.com/acme/cgc-fixture"
        try await harness.vault.linkMachine("vm-1", projectKey: project)
        try await harness.vault.set([CloudSecretInput(name: "GH_TOKEN", value: "gh")], scope: .all, source: .manual)
        try await harness.vault.set([CloudSecretInput(name: "REDIS_URL", value: "redis://x")], scope: .machine("vm-1"), source: .manual)
        harness.declaredByProject[project] = [
            CloudSecretRequirement(name: "DATABASE_URL", description: nil, source: ".cmux/cloud.json"),
            CloudSecretRequirement(name: "GH_TOKEN", description: nil, source: ".cmux/cloud.json"),
            CloudSecretRequirement(name: "REDIS_URL", description: nil, source: ".cmux/cloud.json"),
        ]
        let model = harness.model(machineID: "vm-1", label: "cgc-eval-r4")
        await model.load()

        #expect(harness.declaredProjectReads == [project])
        #expect(harness.declaredReads.isEmpty, "a machine's sheet never reads a local folder")
        #expect(model.tab == .machine)
        #expect(model.projectKey == project)
        // All-machines and machine secrets both reach the machine.
        #expect(model.unsetRequirements.map(\.name) == ["DATABASE_URL"])
        #expect(model.unsetRequirementsProjectLabel == "acme/cgc-fixture")
        model.tab = .project
        #expect(model.unsetRequirements.map(\.name) == ["DATABASE_URL"])
        model.tab = .all
        #expect(model.unsetRequirements.isEmpty, "ghost rows stay off the all-machines tab")

        let databaseURL = try #require(harness.declaredByProject[project]?.first)
        model.beginSetRequirement(databaseURL)
        #expect(model.tab == .project)
        #expect(model.editorScope == .project(project), "Set\u{2026} writes to the project that declares the name")
    }

    @Test("A Cloud workspace's sheet starts on the project its folder is checked out from")
    func cloudWorkspaceSheetUsesFolderProject() async throws {
        let harness = Harness()
        try await harness.vault.linkMachine("vm-1", projectKey: "github.com/acme/web")
        try await harness.vault.linkMachine("vm-1", projectKey: "github.com/acme/api")
        harness.declaredByProject["github.com/acme/api"] = [
            CloudSecretRequirement(name: "DATABASE_URL", description: "Postgres", source: ".cmux/cloud.json"),
        ]
        let model = harness.model(cloudMachineID: "vm-1", directoryName: "api")
        await model.load()

        #expect(!model.isMachineMode, "a workspace's sheet is still the all-machines sheet")
        #expect(model.tab == .all)
        #expect(model.projectKey == "github.com/acme/api")
        #expect(model.unsetRequirements.isEmpty)
        model.tab = .project
        #expect(model.unsetRequirements.map(\.name) == ["DATABASE_URL"])
        #expect(model.unsetRequirementsProjectLabel == "acme/api")
    }

    @Test("Opened from the Cloud panel, a chosen project shows the names its last check declared")
    func chosenProjectShowsRememberedNeeds() async throws {
        let harness = Harness()
        try await harness.vault.set([CloudSecretInput(name: "A", value: "1")], scope: .project("github.com/acme/api"), source: .manual)
        harness.declaredByProject["github.com/acme/api"] = [
            CloudSecretRequirement(name: "A", description: nil, source: ".cmux/cloud.json"),
            CloudSecretRequirement(name: "DATABASE_URL", description: nil, source: ".cmux/cloud.json"),
        ]
        let model = harness.model()
        await model.load()
        model.tab = .project
        #expect(model.unsetRequirements.isEmpty, "All Projects with no project of its own lists none")
        model.projectKey = "github.com/acme/api"
        #expect(model.unsetRequirements.map(\.name) == ["DATABASE_URL"])
    }

    @Test("The Project segment counts what the tab lists for the chosen project")
    func projectCountFollowsFilter() async throws {
        let harness = Harness()
        try await harness.vault.set([CloudSecretInput(name: "A", value: "1")], scope: .project("github.com/acme/api"), source: .manual)
        try await harness.vault.set([CloudSecretInput(name: "B", value: "2")], scope: .project("github.com/acme/web"), source: .manual)
        try await harness.vault.set([CloudSecretInput(name: "C", value: "3")], scope: .project("github.com/acme/web"), source: .manual)
        let model = harness.model()
        await model.load()
        #expect(model.count(for: .project) == 3, "every project's secrets while none is chosen")
        model.projectKey = "github.com/acme/web"
        model.tab = .project
        #expect(model.count(for: .project) == model.visibleRecords.count)
        #expect(model.count(for: .project) == 2)
    }

    @Test("A machine's linked project is the one its workspace folder names, else the first")
    func linkedProjectChoice() {
        let keys = ["github.com/acme/web", "github.com/acme/api"]
        #expect(CloudSecretsSheetPresentation.linkedProject(keys, directoryName: "API") == "github.com/acme/api")
        #expect(CloudSecretsSheetPresentation.linkedProject(keys, directoryName: "elsewhere") == "github.com/acme/web")
        #expect(CloudSecretsSheetPresentation.linkedProject(keys, directoryName: nil) == "github.com/acme/web")
        #expect(CloudSecretsSheetPresentation.linkedProject([], directoryName: "api") == nil)
    }

    // MARK: Ages in other languages

    @Test("Ages read as words in every language, never CLDR's narrow symbols")
    func agesInOtherLocales() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveMinutes = now.addingTimeInterval(-300)
        func age(_ identifier: String) -> String {
            CloudSecretsSheetPresentation.ageLabel(fiveMinutes, now: now, locale: Locale(identifier: identifier))
        }
        #expect(age("en_US") == "5m ago")
        let french = age("fr_FR")
        #expect(french.hasPrefix("il y a 5"), "not \"-5 min\": \(french)")
        #expect(!french.contains("-"))
        let german = age("de_DE")
        #expect(german.hasPrefix("vor 5 Min"), "not \"vor 5 m\": \(german)")
        #expect(age("ja_JP").contains("5") && age("ja_JP").contains("\u{524D}"))
        let russian = age("ru_RU")
        #expect(!russian.hasPrefix("-"), "\(russian)")
        // The full phrases use the same form.
        let delivered = CloudSecretsSheetPresentation.relativePhrase(fiveMinutes, now: now, locale: Locale(identifier: "fr_FR"))
        #expect(delivered == french)
        #expect(CloudSecretsSheetPresentation.relativeUnitsStyle(for: Locale(identifier: "en_GB")) == .abbreviated)
        #expect(CloudSecretsSheetPresentation.relativeUnitsStyle(for: Locale(identifier: "es_ES")) == .short)
    }

    @Test("Ages follow the app's language, with the person's region")
    func interfaceLocaleFollowsAppLanguage() {
        let english = Locale(identifier: "en_US")
        let french = CloudSecretsSheetPresentation.interfaceLocale(preferredLocalizations: ["fr"], current: english)
        #expect(french.language.languageCode == .french)
        #expect(french.region == .unitedStates)
        let same = CloudSecretsSheetPresentation.interfaceLocale(preferredLocalizations: ["en"], current: Locale(identifier: "en_GB"))
        #expect(same.identifier == "en_GB")
        let fallback = CloudSecretsSheetPresentation.interfaceLocale(preferredLocalizations: [], current: Locale(identifier: "de_DE"))
        #expect(fallback.identifier == "de_DE")
    }
}
