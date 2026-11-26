import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud agent updates")
struct CloudAgentUpdatesTests {
    @Test func wireValuesDecodeAndUnknownOnesAreNil() {
        #expect(CloudAgentUpdates(wireValue: "latest") == .latest)
        #expect(CloudAgentUpdates(wireValue: " Image ") == .image)
        #expect(CloudAgentUpdates(wireValue: "nightly") == nil)
        #expect(CloudAgentUpdates(wireValue: nil) == nil)
        #expect(CloudAgentUpdates(wireValue: NSNull()) == nil)
        #expect(CloudAgentUpdates(keepsAgentsUpdated: true) == .latest)
        #expect(!CloudAgentUpdates.image.keepsAgentsUpdated)
    }

    @Test func requestBodyAndResponseUseTheServerShape() throws {
        #expect(VMClient.agentUpdatesRequestBody(.latest) as? [String: String] == ["agentUpdates": "latest"])
        #expect(VMClient.agentUpdatesRequestBody(.image) as? [String: String] == ["agentUpdates": "image"])
        #expect(try VMClient.decodeAgentUpdatesResponse(["id": "vm-1", "agentUpdates": "latest"]) == .latest)
        #expect(throws: VMClientError.self) { try VMClient.decodeAgentUpdatesResponse(["id": "vm-1"]) }
    }

    @Test func machineRowsCarryTheSettingAndOlderServersLeaveItUnset() {
        var summary = VMSummary(id: "vm-1", provider: "freestyle", status: "running", image: "snapshot", createdAt: 1)
        #expect(MachineSnapshotBuilder.snapshot(from: summary).agentUpdates == nil)
        summary.agentUpdates = .latest
        #expect(MachineSnapshotBuilder.snapshot(from: summary).agentUpdates == .latest)
    }

    @Test func updateHostReachabilityFollowsTheNetworkPolicyAndCatalog() throws {
        let github = ["api.github.com", "github.com", "release-assets.githubusercontent.com"]
        let current = CloudNetworkPresetCatalog(
            presets: [CloudNetworkPreset(id: "npm", label: "npm", domains: ["registry.npmjs.org"])],
            requiredDomains: ["files.cmux.com"] + github,
            agentUpdateDomains: github
        )
        // Today's server: every update host is always allowed, so no policy blocks updates.
        for policy in [CloudNetworkPolicy(mode: .none), CloudNetworkPolicy(mode: .allowlist), CloudNetworkPolicy(mode: .full)] {
            #expect(CloudAgentUpdates.latest.networkNote(for: policy, catalog: current) == nil)
        }
        // A catalog whose update hosts are not always allowed: the note names exactly the blocked ones.
        let restricted = CloudNetworkPresetCatalog(
            presets: [CloudNetworkPreset(id: "github", label: "GitHub", domains: ["api.github.com"])],
            requiredDomains: ["github.com", "release-assets.githubusercontent.com"],
            agentUpdateDomains: github
        )
        #expect(CloudAgentUpdates.latest.networkNote(for: CloudNetworkPolicy(mode: .none), catalog: restricted)
            == CloudAgentUpdates.blockedNote(domains: ["api.github.com"]))
        #expect(CloudAgentUpdates.latest.networkNote(for: CloudNetworkPolicy(mode: .allowlist, presets: ["github"]), catalog: restricted) == nil)
        #expect(CloudAgentUpdates.latest.networkNote(for: CloudNetworkPolicy(mode: .allowlist, domains: ["api.github.com"]), catalog: restricted) == nil)
        #expect(CloudAgentUpdates.image.networkNote(for: CloudNetworkPolicy(mode: .none), catalog: restricted) == nil)
        // An older server sends no agentUpdateDomains: its updates went through npm.
        let legacy = try JSONDecoder().decode(
            CloudNetworkPresetCatalog.self,
            from: Data(#"{"presets":[{"id":"npm","label":"npm","domains":["registry.npmjs.org"]}],"requiredDomains":["files.cmux.com"]}"#.utf8)
        )
        #expect(legacy.agentUpdateDomains == ["registry.npmjs.org"])
        #expect(CloudAgentUpdates.latest.networkNote(for: CloudNetworkPolicy(mode: .none), catalog: legacy)
            == CloudAgentUpdates.blockedNote(domains: ["registry.npmjs.org"]))
        #expect(CloudAgentUpdates.latest.networkNote(for: CloudNetworkPolicy(mode: .allowlist, presets: ["npm"]), catalog: legacy) == nil)
    }

    @Test func operationKindNamesTheChange() {
        #expect(CloudOperationKind.resolve("vm.agent_updates_set") == .agentUpdates)
        #expect(CloudOperationKind.resolve("vm agent-updates") == .agentUpdates)
        #expect(CloudOperationKind.resolve("vm agent") == .agent)
    }

    @Test func socketPayloadNamesTheSettingAndTheNote() {
        let plain = TerminalController.socketWorkerAgentUpdatesPayload(id: "vm-1", setting: .image, note: nil)
        #expect(plain["agent_updates"] as? String == "image")
        #expect(plain["note"] == nil)
        let noted = TerminalController.socketWorkerAgentUpdatesPayload(id: "vm-1", setting: .latest, note: "blocked")
        #expect(noted["agent_updates"] as? String == "latest")
        #expect(noted["note"] as? String == "blocked")
    }
}

@Suite("New Machine agent updates")
@MainActor
struct NewMachineAgentUpdatesTests {
    private static let catalog = CloudNetworkPresetCatalog(
        presets: [CloudNetworkPreset(id: "github", label: "GitHub", domains: ["api.github.com"])],
        requiredDomains: ["files.cmux.com", "github.com", "release-assets.githubusercontent.com"],
        defaultPolicy: .default,
        agentUpdateDomains: ["api.github.com", "github.com", "release-assets.githubusercontent.com"]
    )

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "new-machine-agent-updates-\(UUID().uuidString)")!
    }

    @Test func onByDefaultAndSendsLatest() throws {
        let model = NewMachineModel(mode: .newMachine, plan: nil, defaults: Self.defaults(), submit: { _ in true })
        #expect(model.keepsAgentsUpdated)
        let arguments = model.cliArguments
        let index = try #require(arguments.firstIndex(of: "--agent-updates"))
        #expect(arguments[index + 1] == "latest")
    }

    @Test func uncheckingSendsNothingAndIsRememberedForTheNextSheet() {
        let defaults = Self.defaults()
        let model = NewMachineModel(mode: .newMachine, plan: nil, defaults: defaults, submit: { _ in true })
        model.keepsAgentsUpdated = false
        #expect(!model.cliArguments.contains("--agent-updates"))

        // Only a submitted choice is remembered.
        #expect(NewMachineModel(mode: .newMachine, plan: nil, defaults: defaults, submit: { _ in true }).keepsAgentsUpdated)
        model.create()
        #expect(!NewMachineModel(mode: .newMachine, plan: nil, defaults: defaults, submit: { _ in true }).keepsAgentsUpdated)
    }

    @Test func networkNoteAppearsOnlyWhenThePolicyBlocksAnUpdateHost() {
        let model = NewMachineModel(mode: .newMachine, plan: nil, defaults: Self.defaults(), submit: { _ in true })
        model.keepsAgentsUpdated = true
        model.network.mode = .none
        // Until the catalog loads the machine gets full internet, so nothing to warn about.
        #expect(model.agentUpdatesNetworkNote == nil)
        model.applyNetworkCatalog(Self.catalog)
        let blocked = CloudAgentUpdates.blockedNote(domains: ["api.github.com"])
        #expect(model.agentUpdatesNetworkNote == blocked)
        model.network.mode = .allowlist
        #expect(model.agentUpdatesNetworkNote == blocked)
        model.network.setPreset("github", enabled: true)
        #expect(model.agentUpdatesNetworkNote == nil)
        model.keepsAgentsUpdated = false
        model.network.mode = .none
        #expect(model.agentUpdatesNetworkNote == nil)
    }

    @Test func baseSetupHasNoAgentUpdatesChoice() {
        let defaults = Self.defaults()
        defaults.set(true, forKey: NewMachineModel.keepsAgentsUpdatedDefaultsKey)
        let model = NewMachineModel(mode: .base(workspaceID: UUID()), plan: nil, defaults: defaults, submit: { _ in true })
        #expect(!model.supportsAgentUpdates)
        #expect(!model.cliArguments.contains("--agent-updates"))
    }
}
