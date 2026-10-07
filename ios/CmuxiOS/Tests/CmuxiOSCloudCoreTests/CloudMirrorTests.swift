import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import Testing

struct CloudMirrorTests {
    func machine(_ id: String, _ status: CloudMachineStatus = .running, revision: UInt64) -> CloudMachine {
        CloudMachine(id: id, status: status, revision: revision)
    }

    @Test func anOlderRecordNeverReplacesANewerOne() {
        var mirror = CloudMachineMirror()
        mirror.replace(with: [machine("vm_a", revision: 5)], at: 5)
        let older = mirror.upsert(machine("vm_a", .paused, revision: 4))
        #expect(!older)
        #expect(mirror.machines["vm_a"]?.status == .running)
        let newer = mirror.upsert(machine("vm_a", .paused, revision: 6))
        #expect(newer)
        #expect(mirror.machines["vm_a"]?.status == .paused)
    }

    @Test func aStaleListKeepsNewerRecordsAndDoesNotResurrectRemovals() {
        var mirror = CloudMachineMirror()
        mirror.upsert(machine("vm_new", revision: 9))
        mirror.upsert(machine("vm_gone", revision: 3))
        mirror.remove("vm_gone", at: 8)
        mirror.upsert(machine("vm_b", .paused, revision: 7))
        // A list read at revision 6: before vm_new existed and before vm_gone was removed.
        mirror.replace(with: [machine("vm_gone", revision: 3), machine("vm_b", .running, revision: 2)], at: 6)
        #expect(mirror.machines["vm_new"] != nil)
        #expect(mirror.machines["vm_gone"] == nil)
        #expect(mirror.machines["vm_b"]?.status == .paused)
        #expect(mirror.isLoaded)
    }

    @Test func aCurrentListDropsMachinesItNoLongerHas() {
        var mirror = CloudMachineMirror()
        mirror.replace(with: [machine("vm_a", revision: 2), machine("vm_b", revision: 3)], at: 3)
        mirror.replace(with: [machine("vm_a", revision: 2)], at: 10)
        #expect(mirror.sorted.map(\.id) == ["vm_a"])
    }

    @Test func theIntentLogOverlaysTransitionsUntilSettled() {
        var log = CloudIntentLog()
        let machines = [machine("vm_a", revision: 1), machine("vm_b", .paused, revision: 1)]
        let pause = IntentKey(), start = IntentKey(), create = IntentKey()
        log.add(.pause(machine: "vm_a"), key: pause)
        log.add(.start(machine: "vm_b"), key: start)
        log.add(.create(name: "new", size: CloudMachineSize(memoryMB: 2048)), key: create)
        #expect(log.overlay(machines).map(\.status) == [.pausing, .starting])
        #expect(log.creating.map(\.id) == [create])
        log.settle(pause)
        log.settle(start)
        log.settle(create)
        #expect(log.overlay(machines).map(\.status) == [.running, .paused])
        #expect(log.creating.isEmpty)
    }
}
