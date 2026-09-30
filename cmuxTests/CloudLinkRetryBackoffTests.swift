import CmuxCloud
import Foundation
import Testing

@Suite("Cloud link retry backoff")
struct CloudLinkRetryBackoffTests {
    private let failedAt = Date(timeIntervalSince1970: 1_000)

    @Test("background upkeep waits out the backoff after a failure")
    func upkeepWaits() async {
        await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
            #expect(CloudMachineLinkManager.backoffRejects(failedAt: failedAt, now: failedAt.addingTimeInterval(5), backoff: 15))
            #expect(!CloudMachineLinkManager.backoffRejects(failedAt: failedAt, now: failedAt.addingTimeInterval(16), backoff: 15))
        }
    }

    @Test("anything a person or an agent asked for dials inside the backoff")
    func requestsDial() {
        #expect(!CloudMachineLinkManager.isBackgroundUpkeep)
        #expect(!CloudMachineLinkManager.backoffRejects(failedAt: failedAt, now: failedAt.addingTimeInterval(1), backoff: 15))
    }

    @Test("work started by upkeep inherits the mark")
    func childTasksInherit() async {
        let inherited = await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
            await Task { CloudMachineLinkManager.isBackgroundUpkeep }.value
        }
        #expect(inherited)
    }

    @Test("background upkeep never connects a non-running machine")
    func pausedMachineStaysDisconnectedDuringUpkeep() {
        #expect(CloudMachineLinkManager.backgroundUpkeepShouldConnect(status: "running"))
        #expect(!CloudMachineLinkManager.backgroundUpkeepShouldConnect(status: "paused"))
        #expect(!CloudMachineLinkManager.backgroundUpkeepShouldConnect(status: "stopped"))
        #expect(!CloudMachineLinkManager.backgroundUpkeepShouldConnect(status: "suspended"))
    }

    @Test("a paused machine's upkeep request does not wake or dial")
    func pausedUpkeepDoesNotConnect() async {
        let probe = ResumeProbe()
        let links = CloudMachineLinkManager(clientURL: nil, resumeMachine: { id in
            await probe.record(id)
            return "running"
        }, hostThemeColors: { nil })
        await links.setMachineStatus("paused", for: "vm-paused")
        await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
            do {
                _ = try await links.connected(machineID: "vm-paused")
                Issue.record("Paused upkeep unexpectedly connected")
            } catch CloudMachineLinkManager.ManagerError.retryLater {
                // The status check ran before any client or private route lookup.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(await probe.ids.isEmpty)
    }

    @Test("a direct open resumes before its carrier dial")
    func directOpenResumes() async {
        let probe = ResumeProbe()
        let links = CloudMachineLinkManager(clientURL: nil, resumeMachine: { id in
            await probe.record(id)
            return "running"
        }, hostThemeColors: { nil })
        await links.setMachineStatus("paused", for: "vm-paused")
        do {
            _ = try await links.connected(machineID: "vm-paused")
            Issue.record("The nil test client unexpectedly connected")
        } catch CloudMachineLinkManager.ManagerError.clientMissing {
            // The test client stops the dial after the resume.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await probe.ids == ["vm-paused"])
    }
}

private actor ResumeProbe {
    private(set) var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}
