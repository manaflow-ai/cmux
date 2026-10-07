import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation
import Testing

struct CloudWireDecoderTests {
    let decoder = CloudWireDecoder()

    @Test func decodesAMachineRecord() throws {
        let machine = try decoder.machine(CloudJSON.machine("vm_a", status: "paused", revision: 7, name: "box", host: "host_a"))
        #expect(machine.id == "vm_a")
        #expect(machine.name == "box")
        #expect(machine.status == .paused)
        #expect(machine.pauseReason == .idle)
        #expect(machine.host == HostID("host_a"))
        #expect(machine.size == CloudMachineSize(cpu: 2, memoryMB: 4096, diskMB: 16384))
        #expect(machine.revision == 7)
        #expect(machine.createdAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func refusesAnUnknownStatus() {
        #expect(throws: CloudWireDecodeError.self) { try decoder.machine(CloudJSON.machine("vm_a", status: "melting")) }
    }

    @Test func decodesPlanAndPage() throws {
        let plan = try decoder.plan(CloudJSON.plan(active: 1, maxActive: 3))
        #expect(plan.planID == "dev")
        #expect(plan.limits.maxActive == 3)
        #expect(plan.limits.lockedMemoryOptionsMB == [16384])
        #expect(plan.usage.vmHoursUsed == 3)
        let page = try decoder.page(.object(["machines": .array([CloudJSON.machine("vm_a")]), "next_cursor": .string("c4"),
                                             "revision": .string("12")]))
        #expect(page.machines.map(\.id) == ["vm_a"])
        #expect(page.nextCursor == "c4")
        #expect(page.revision == 12)
    }

    @Test func decodesWireFrames() {
        let upsert = CloudJSON.text(.object(["t": .string("event"), "seq": .int(5), "event": .string("cloud.machine.upsert"),
                                             "data": .object(["machine": CloudJSON.machine("vm_a", revision: 5)])]))
        guard case .event(5, .upsert(let machine)?) = CloudWireFrame.decode(Data(upsert.utf8)) else {
            Issue.record("not an upsert")
            return
        }
        #expect(machine.id == "vm_a")
        let removed = CloudJSON.text(.object(["t": .string("event"), "seq": .int(6), "event": .string("cloud.machine.removed"),
                                              "data": .object(["machine": .string("vm_a"), "revision": .string("6")])]))
        #expect(CloudWireFrame.decode(Data(removed.utf8)) == .event(seq: 6, change: .removed(machine: "vm_a", revision: 6)))
        let ledger = CloudJSON.text(.object(["t": .string("event"), "seq": .int(7), "op": .string("cloud.driver_result")]))
        #expect(CloudWireFrame.decode(Data(ledger.utf8)) == .event(seq: 7, change: nil))
        let snapshot = CloudJSON.text(.object(["t": .string("snapshot"), "seq": .int(9), "state": .object([:])]))
        #expect(CloudWireFrame.decode(Data(snapshot.utf8)) == .snapshot(seq: 9))
    }

    @Test func encodesIntentParams() {
        #expect(CloudIntent.create(name: " ", size: CloudMachineSize(memoryMB: 2048)).params
            == ["size": .object(["memory_mb": .int(2048)])])
        #expect(CloudIntent.create(name: "box", size: CloudMachineSize()).params["name"] == .string("box"))
        #expect(CloudIntent.pause(machine: "vm_a").params == ["machine": .string("vm_a")])
        #expect(CloudIntent.delete(machine: "vm_a").op == "cloud.machine.delete")
        #expect(CloudIntent.start(machine: "vm_a").op == "cloud.machine.start")
    }
}
