import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud network policy")
struct CloudNetworkPolicyTests {
    @Test func decodesTheServerStatusShape() throws {
        let json = #"""
        {
          "policy": {"version": 1, "mode": "allowlist",
                     "ranges": [{"cidr": "10.0.0.0/8", "port": 5432, "protocol": "tcp", "note": "db"}],
                     "domains": ["api.example.com"], "presets": ["github"], "allowDns": false},
          "presets": [{"id": "github", "label": "GitHub", "domains": ["github.com"]}],
          "requiredDomains": ["files.cmux.com"],
          "defaultPolicy": {"version": 1, "mode": "full", "ranges": [], "domains": [], "presets": [], "allowDns": true},
          "applied": {"state": "pending"}
        }
        """#
        let status = try JSONDecoder().decode(CloudNetworkPolicyStatus.self, from: Data(json.utf8))
        #expect(status.policy.mode == .allowlist)
        #expect(status.policy.ranges == [CloudNetworkRange(cidr: "10.0.0.0/8", port: 5432, transport: .tcp, note: "db")])
        #expect(status.policy.domains == ["api.example.com"])
        #expect(status.policy.presets == ["github"])
        #expect(!status.policy.allowDns)
        #expect(status.presets.map(\.id) == ["github"])
        #expect(status.requiredDomains == ["files.cmux.com"])
        #expect(status.applied == CloudNetworkApplied(state: .pending))
    }

    @Test func omittedFieldsTakeTheServerDefaults() throws {
        let policy = try JSONDecoder().decode(CloudNetworkPolicy.self, from: Data(#"{"mode":"none"}"#.utf8))
        #expect(policy == CloudNetworkPolicy(mode: .none))
        #expect(policy.allowDns)
        #expect(policy.version == 1)
    }

    @Test func encodesTheWireShapeWithProtocolKey() throws {
        let policy = CloudNetworkPolicy(
            mode: .allowlist,
            ranges: [CloudNetworkRange(cidr: "10.0.0.0/8"), CloudNetworkRange(cidr: "1.2.3.4/32", port: 53, transport: .udp)],
            domains: ["api.example.com"]
        )
        let object = policy.foundationObject
        #expect(object["mode"] as? String == "allowlist")
        let ranges = try #require(object["ranges"] as? [[String: Any]])
        #expect(ranges[0].keys.sorted() == ["cidr"])
        #expect(ranges[1]["protocol"] as? String == "udp")
        #expect(ranges[1]["port"] as? Int == 53)
        #expect(try CloudNetworkPolicy(foundationObject: object) == policy)

        let encoded = try JSONSerialization.jsonObject(with: Data(policy.jsonString.utf8)) as? [String: Any]
        #expect(((encoded?["ranges"] as? [[String: Any]])?[1]["protocol"]) as? String == "udp")
    }

    @Test func nonObjectInputIsRejectedWithoutRaising() {
        #expect(throws: (any Error).self) { try CloudNetworkPolicy(foundationObject: "full") }
        #expect(throws: (any Error).self) { try CloudNetworkPolicy(foundationObject: ["mode": "open"]) }
    }

    @Test func switchingModeKeepsTheLists() throws {
        var policy = CloudNetworkPolicy(mode: .allowlist)
        try policy.apply(.addDomain("api.example.com"))
        try policy.apply(.addRange(CloudNetworkRange(cidr: "10.0.0.0/8")))
        try policy.apply(.setPreset("github", enabled: true))
        try policy.apply(.setMode(.full))
        try policy.apply(.setMode(.allowlist))
        #expect(policy.domains == ["api.example.com"])
        #expect(policy.ranges.map(\.cidr) == ["10.0.0.0/8"])
        #expect(policy.presets == ["github"])
    }

    @Test func domainsAreNormalizedAndDuplicatesRejected() throws {
        var policy = CloudNetworkPolicy(mode: .allowlist)
        try policy.apply(.addDomain(" https://API.Example.com/v1/path "))
        #expect(policy.domains == ["api.example.com"])
        #expect(throws: CloudNetworkPolicyEditError.duplicateDomain("api.example.com")) {
            try policy.apply(.addDomain("api.example.com."))
        }
        #expect(throws: CloudNetworkPolicyEditError.wildcardDomain("*.example.com")) {
            try policy.apply(.addDomain("*.example.com"))
        }
        #expect(throws: CloudNetworkPolicyEditError.invalidDomain("localhost")) {
            try policy.apply(.addDomain("localhost"))
        }
        #expect(throws: CloudNetworkPolicyEditError.invalidDomain("-bad.example.com")) {
            try policy.apply(.addDomain("-bad.example.com"))
        }
        try policy.apply(.removeDomain("API.example.com"))
        #expect(policy.domains.isEmpty)
        #expect(throws: CloudNetworkPolicyEditError.missingDomain("api.example.com")) {
            try policy.apply(.removeDomain("api.example.com"))
        }
    }

    @Test func rangesAreCanonicalizedLikeTheServer() throws {
        #expect(CloudNetworkPolicy.canonicalCIDR("10.1.2.3/8") == "10.0.0.0/8")
        #expect(CloudNetworkPolicy.canonicalCIDR("1.2.3.4") == "1.2.3.4/32")
        #expect(CloudNetworkPolicy.canonicalCIDR("2001:DB8::1/32") == "2001:db8::/32")
        #expect(CloudNetworkPolicy.canonicalCIDR("0.0.0.0/0") == "0.0.0.0/0")
        #expect(CloudNetworkPolicy.canonicalCIDR("10.0.0.0/33") == nil)
        #expect(CloudNetworkPolicy.canonicalCIDR("10.0.0.0/") == nil)
        #expect(CloudNetworkPolicy.canonicalCIDR("10.0.0.0/+8") == nil)
        #expect(CloudNetworkPolicy.canonicalCIDR("example.com") == nil)
    }

    @Test func rangeEditsDedupeAndDefaultToTCP() throws {
        var policy = CloudNetworkPolicy(mode: .allowlist)
        try policy.apply(.addRange(CloudNetworkRange(cidr: "10.9.9.9/8", port: 5432)))
        #expect(policy.ranges == [CloudNetworkRange(cidr: "10.0.0.0/8", port: 5432, transport: .tcp)])
        #expect(throws: CloudNetworkPolicyEditError.duplicateRange("10.0.0.0/8 tcp/5432")) {
            try policy.apply(.addRange(CloudNetworkRange(cidr: "10.0.0.0/8", port: 5432, transport: .tcp)))
        }
        try policy.apply(.addRange(CloudNetworkRange(cidr: "10.0.0.0/8", port: 53, transport: .udp)))
        #expect(throws: CloudNetworkPolicyEditError.invalidPort) {
            try policy.apply(.addRange(CloudNetworkRange(cidr: "10.0.0.0/8", port: 70_000)))
        }
        #expect(throws: CloudNetworkPolicyEditError.invalidRange("not-an-ip")) {
            try policy.apply(.addRange(CloudNetworkRange(cidr: "not-an-ip")))
        }
        // A bare range removes every rule on it; a port narrows the removal.
        try policy.apply(.removeRange(CloudNetworkRange(cidr: "10.0.0.0/8", port: 53, transport: .udp)))
        #expect(policy.ranges.count == 1)
        try policy.apply(.addRange(CloudNetworkRange(cidr: "10.0.0.0/8", port: 53, transport: .udp)))
        try policy.apply(.removeRange(CloudNetworkRange(cidr: "10.0.0.0/8")))
        #expect(policy.ranges.isEmpty)
    }

    @Test func presetsAreCheckedAgainstTheCatalog() throws {
        var policy = CloudNetworkPolicy(mode: .allowlist)
        #expect(throws: CloudNetworkPolicyEditError.unknownPreset("nope")) {
            try policy.apply(.setPreset("nope", enabled: true), knownPresetIDs: ["github"])
        }
        try policy.apply(.setPreset("github", enabled: true), knownPresetIDs: ["github"])
        try policy.apply(.setPreset("github", enabled: true), knownPresetIDs: ["github"])
        #expect(policy.presets == ["github"])
        try policy.apply(.setPreset("github", enabled: false))
        #expect(policy.presets.isEmpty)
    }

    @Test func serverRefusalsMapToTypedErrors() {
        let invalid = CloudNetworkPolicyRequestError.from(
            status: 400,
            body: #"{"error":"invalid_network_policy","path":"domains.0","message":"\"x\" is not a host name"}"#
        )
        #expect(invalid == .invalid(path: "domains.0", message: "\"x\" is not a host name"))
        #expect(invalid?.errorDescription == "domains.0: \"x\" is not a host name")
        #expect(CloudNetworkPolicyRequestError.from(status: 501, body: #"{"error":"vm_operation_unsupported"}"#) == .unsupported)
        #expect(CloudNetworkPolicyRequestError.from(status: 500, body: #"{"error":"boom"}"#) == nil)
    }

    @Test func socketEditsDecodeEveryOp() {
        func decode(_ object: [String: Any]) -> CloudNetworkPolicyEdit? {
            TerminalController.socketWorkerNetworkEdit(object)
        }
        #expect(decode(["op": "set_mode", "mode": "none"]) == .setMode(.none))
        #expect(decode(["op": "set_mode", "mode": "open"]) == nil)
        #expect(decode(["op": "add_domain", "domain": "a.example.com"]) == .addDomain("a.example.com"))
        #expect(decode(["op": "remove_domain", "domain": "a.example.com"]) == .removeDomain("a.example.com"))
        #expect(decode(["op": "add_range", "cidr": "10.0.0.0/8", "port": 22, "protocol": "TCP"])
            == .addRange(CloudNetworkRange(cidr: "10.0.0.0/8", port: 22, transport: .tcp)))
        #expect(decode(["op": "add_range", "cidr": "10.0.0.0/8", "protocol": "icmp"]) == nil)
        #expect(decode(["op": "remove_range", "cidr": "10.0.0.0/8"]) == .removeRange(CloudNetworkRange(cidr: "10.0.0.0/8")))
        #expect(decode(["op": "add_preset", "preset": "npm"]) == .setPreset("npm", enabled: true))
        #expect(decode(["op": "remove_preset", "preset": "npm"]) == .setPreset("npm", enabled: false))
        #expect(decode(["op": "set_dns", "allow_dns": false]) == .setAllowDns(false))
        #expect(decode(["op": "replace", "policy": ["mode": "none"] as [String: Any]]) == .replace(CloudNetworkPolicy(mode: .none)))
        #expect(decode(["op": "explode"]) == nil)
        #expect(TerminalController.socketWorkerNetworkEdit("add_domain") == nil)
    }
}

@Suite("Cloud network policy editor")
@MainActor
struct CloudNetworkPolicyEditorModelTests {
    private static let catalog = CloudNetworkPresetCatalog(
        presets: [CloudNetworkPreset(id: "github", label: "GitHub", domains: ["github.com"])],
        requiredDomains: ["files.cmux.com"]
    )

    @Test func addingADuplicateDomainKeepsTheDraftAndExplains() {
        let model = CloudNetworkPolicyEditorModel(policy: CloudNetworkPolicy(mode: .allowlist), catalog: Self.catalog)
        model.domainDraft = "api.example.com"
        model.addDomain()
        #expect(model.policy.domains == ["api.example.com"])
        #expect(model.domainDraft.isEmpty)
        #expect(model.inputError == nil)

        model.domainDraft = "API.example.com"
        model.addDomain()
        #expect(model.policy.domains == ["api.example.com"])
        #expect(model.domainDraft == "API.example.com")
        #expect(model.inputError == CloudNetworkPolicyEditError.duplicateDomain("api.example.com").errorDescription)
    }

    @Test func modeSwitchThroughTheEditorKeepsLists() {
        let model = CloudNetworkPolicyEditorModel(policy: CloudNetworkPolicy(mode: .allowlist), catalog: Self.catalog)
        model.rangeDraft = "192.168.1.7/24"
        model.portDraft = "443"
        model.addRange()
        model.setPreset("github", enabled: true)
        model.mode = .none
        #expect(!model.showsAllowlistDetails)
        model.mode = .allowlist
        #expect(model.policy.ranges == [CloudNetworkRange(cidr: "192.168.1.0/24", port: 443, transport: .tcp)])
        #expect(model.isPresetEnabled("github"))
        #expect(model.rangeDraft.isEmpty && model.portDraft.isEmpty)
    }

    @Test func badPortTextIsRefusedBeforeTheRangeIsAdded() {
        let model = CloudNetworkPolicyEditorModel(policy: CloudNetworkPolicy(mode: .allowlist))
        model.rangeDraft = "10.0.0.0/8"
        model.portDraft = "http"
        model.addRange()
        #expect(model.policy.ranges.isEmpty)
        #expect(model.inputError == CloudNetworkPolicyEditError.invalidPort.errorDescription)
    }

    @Test func unknownPresetIsRefusedOnceTheCatalogIsKnown() {
        let model = CloudNetworkPolicyEditorModel(policy: CloudNetworkPolicy(mode: .allowlist), catalog: Self.catalog)
        model.setPreset("nope", enabled: true)
        #expect(model.policy.presets.isEmpty)
        #expect(model.inputError != nil)
    }

    @Test func requiredDomainsAreNamedOnlyForRestrictiveModes() {
        let model = CloudNetworkPolicyEditorModel(policy: .default, catalog: Self.catalog)
        #expect(model.requiredDomainsNote == nil)
        model.mode = .none
        #expect(model.requiredDomainsNote?.contains("files.cmux.com") == true)
    }

    @Test func newMachineSendsAPolicyOnlyWhenTheServerKnowsPoliciesAndItChanged() throws {
        let model = NewMachineModel(mode: .newMachine, plan: nil, submit: { _ in true })
        #expect(!model.cliArguments.contains("--network-policy"))

        // Edited before the catalog loaded: an older server would ignore the
        // field and open the machine, so nothing is sent.
        model.network.mode = .none
        #expect(!model.cliArguments.contains("--network-policy"))

        model.applyNetworkCatalog(Self.catalog)
        let arguments = model.cliArguments
        let index = try #require(arguments.firstIndex(of: "--network-policy"))
        let sent = try JSONDecoder().decode(CloudNetworkPolicy.self, from: Data(arguments[index + 1].utf8))
        #expect(sent.mode == .none)

        model.network.mode = .full
        #expect(!model.cliArguments.contains("--network-policy"))
    }

    @Test func baseSetupHasNoNetworkChoice() {
        let model = NewMachineModel(mode: .base(workspaceID: UUID()), plan: nil, submit: { _ in true })
        model.applyNetworkCatalog(Self.catalog)
        model.network.mode = .none
        #expect(!model.supportsNetworkPolicy)
        #expect(!model.cliArguments.contains("--network-policy"))
    }
}

@Suite("Cloud network policy sheet")
@MainActor
struct CloudNetworkPolicySheetModelTests {
    private static func status(_ policy: CloudNetworkPolicy, _ state: CloudNetworkApplied.State, error: String? = nil) -> CloudNetworkPolicyStatus {
        CloudNetworkPolicyStatus(
            policy: policy,
            presets: [CloudNetworkPreset(id: "npm", label: "npm", domains: ["registry.npmjs.org"])],
            requiredDomains: ["files.cmux.com"],
            applied: CloudNetworkApplied(state: state, error: error)
        )
    }

    @Test func saveIsEnabledOnlyForAChangedDraftAndAnAppliedSaveCloses() async {
        var saved: [CloudNetworkPolicy] = []
        var outcomes: [CloudNetworkPolicySheetModel.Outcome] = []
        let model = CloudNetworkPolicySheetModel(
            machineID: "vm-1",
            load: { _ in Self.status(.default, .applied) },
            save: { _, policy in saved.append(policy); return Self.status(policy, .applied) }
        )
        model.onFinished = { outcomes.append($0) }
        await model.load()
        #expect(model.phase == .ready)
        #expect(!model.canSave)

        model.editor.mode = .allowlist
        model.editor.setPreset("npm", enabled: true)
        #expect(model.canSave)
        await model.save()
        #expect(saved.map(\.presets) == [["npm"]])
        #expect(outcomes == [.saved])
    }

    @Test func pendingApplyStaysOpenAndShowsTheState() async {
        var outcomes: [CloudNetworkPolicySheetModel.Outcome] = []
        let model = CloudNetworkPolicySheetModel(
            machineID: "vm-1",
            load: { _ in Self.status(.default, .applied) },
            save: { _, policy in Self.status(policy, .pending) }
        )
        model.onFinished = { outcomes.append($0) }
        await model.load()
        model.editor.mode = .none
        await model.save()
        #expect(outcomes.isEmpty)
        #expect(model.applied?.state == .pending)
        #expect(!model.hasChanges)
        model.done()
        #expect(outcomes == [.saved])
    }

    @Test func serverRefusalIsShownAndTheDraftKept() async {
        let model = CloudNetworkPolicySheetModel(
            machineID: "vm-1",
            load: { _ in Self.status(CloudNetworkPolicy(mode: .allowlist), .applied) },
            save: { _, _ in throw CloudNetworkPolicyRequestError.unsupported }
        )
        await model.load()
        model.editor.mode = .none
        await model.save()
        #expect(model.saveError == CloudNetworkPolicyRequestError.unsupported.errorDescription)
        #expect(model.editor.policy.mode == .none)
        #expect(model.canSave)
        #expect(model.outcome == nil)
    }

    @Test func loadFailureIsReported() async {
        let model = CloudNetworkPolicySheetModel(
            machineID: "vm-1",
            load: { _ in throw CloudNetworkPolicyRequestError.invalid(path: nil, message: "nope") },
            save: { _, policy in Self.status(policy, .applied) }
        )
        await model.load()
        #expect(model.phase == .loadFailed("nope"))
        #expect(!model.canSave)
    }
}
