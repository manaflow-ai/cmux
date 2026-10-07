import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import Testing

@Suite struct PickerTests {
    let hosts = MockFixtures.hostWorkspaces()

    @Test func choicesPerHostWithNewFirst() throws {
        let sections = WorkspacePickerModel().sections(from: hosts, request: WorkspacePickerRequest())
        #expect(sections.map(\.host.hostID) == [MockFixtures.studio, MockFixtures.mini])
        let studio = sections[0].choices
        #expect(studio.first?.selection == WorkspaceSelection(hostID: MockFixtures.studio, workspaceID: nil))
        #expect(studio.dropFirst().map(\.selection.workspaceID) == ["ws_studio1", "ws_studio2", "ws_studio3"])
        #expect(studio.allSatisfy { $0.isEnabled })
        // The asleep Mac's rows are shown but disabled (nothing queues).
        #expect(sections[1].choices.allSatisfy { !$0.isEnabled })
    }

    @Test func restrictToOneHostWithoutNew() {
        let request = WorkspacePickerRequest(hostID: MockFixtures.mini, allowsNewWorkspace: false)
        let choices = WorkspacePickerModel().choices(from: hosts, request: request)
        #expect(choices.keys.sorted { $0.rawValue < $1.rawValue } == [MockFixtures.mini])
        #expect(choices[MockFixtures.mini]?.map(\.title) == ["release"])
    }

    @Test func hiddenMachinesAreLeftOut() {
        let model = WorkspacePickerModel(preferences: WorkspaceViewPreferences(hiddenHosts: [MockFixtures.mini]))
        #expect(model.sections(from: hosts, request: WorkspacePickerRequest()).map(\.host.hostID) == [MockFixtures.studio])
    }

    @Test func directoryFromRegistryKeepsTrustedMacs() {
        let hosts = DeviceRegistryHostDirectory.hosts(in: MockFixtures.devices())
        #expect(hosts.map(\.id) == [MockFixtures.studio, MockFixtures.mini])
        #expect(hosts.allSatisfy { $0.kind == .mac })
    }

    @Test func registryRecordsAreAddressedByHostID() {
        let mac = DeviceRecord(id: "install:inst_m1", name: "Studio", platform: .mac, trust: .trusted, hostID: "host_a1")
        #expect(DeviceRegistryHostDirectory.hosts(in: [mac]).map(\.id) == [HostID("host_a1")])
    }
}
