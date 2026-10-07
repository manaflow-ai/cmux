import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import Testing

struct CloudHostDirectoryTests {
    @Test func boundModernMachinesBecomeCloudHosts() {
        let machines = [
            CloudMachine(id: "vm_a", name: "devbox", status: .running, host: HostID("host_a")),
            CloudMachine(id: "vm_b", status: .paused, host: HostID("host_b")),
            CloudMachine(id: "vm_c", status: .provisioning),
            CloudMachine(id: "vm_d", status: .running, host: HostID("host_d"), isClassic: true),
            CloudMachine(id: "vm_e", status: .deleting, host: HostID("host_e")),
        ]
        #expect(CloudMachineHostDirectory.hosts(in: machines) == [
            WorkspaceHostDescriptor(id: HostID("host_a"), name: "devbox", kind: .cloud),
            WorkspaceHostDescriptor(id: HostID("host_b"), name: "vm_b", kind: .cloud),
        ])
    }

    @Test func compositeMergesMacsAndMachinesAndFollowsChanges() async {
        let macs = StaticHostDirectory([WorkspaceHostDescriptor(id: HostID("mac_1"), name: "MacBook")])
        let source = MockCloudMachineSource()
        var updates = await CompositeHostDirectory([macs, CloudMachineHostDirectory(source: source)]).hosts().makeAsyncIterator()
        let first = await updates.next()
        #expect(first?.map(\.id.rawValue) == ["mac_1", "host_mockdevbox000000001", "host_mockscratch00000002"])
        #expect(first?.last?.kind == .cloud)
        _ = try? await source.perform(.delete(machine: "vm_mockscratch00000002"), key: IntentKey())
        let second = await updates.next()
        #expect(second?.map(\.id.rawValue) == ["mac_1", "host_mockdevbox000000001"])
        await macs.update([])
        let third = await updates.next()
        #expect(third?.map(\.id.rawValue) == ["host_mockdevbox000000001"])
    }
}
