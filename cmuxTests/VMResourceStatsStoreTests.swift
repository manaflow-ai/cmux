import CmuxCloud
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Resource readings across resize and poll races")
struct VMResourceStatsStoreTests {
    private let time = Date(timeIntervalSince1970: 1_780_000_000)

    private func stats(memory: Int, disk: Int, cpus: Int = 4) -> VMStats {
        VMStats(state: .awake, sampledAt: time, resourceSampledAt: time,
                cpus: cpus, cpuPercent: 25, loadAverage1m: nil,
                memoryTotalMb: memory, memoryUsedMb: 1024,
                diskTotalMb: disk, diskUsedMb: 2048)
    }

    @Test func latePollCannotReplaceTheSuccessfulResizeResponse() {
        let store = VMResourceStatsStore(now: { self.time })
        let before = stats(memory: 8192, disk: 32768)
        let after = stats(memory: 16384, disk: 65536, cpus: 8)
        store.finishRead(store.beginRead(machineID: "vm"), stats: before)
        let oldPoll = store.beginRead(machineID: "vm")
        let resize = store.beginResize(machineID: "vm")
        #expect(store.snapshot["vm"]?.memoryTotalMb == nil)
        let duringResize = store.beginRead(machineID: "vm")
        store.finishRead(duringResize, stats: before)
        #expect(store.snapshot["vm"]?.memoryTotalMb == nil)
        store.finishResize(resize, stats: after)
        #expect(store.finishRead(oldPoll, stats: before) == after)
        #expect(store.finishRead(duringResize, stats: before) == after)
        #expect(store.snapshot["vm"] == after)
    }

    @Test func cancelledOldPollCannotClearTheLatestSuccessfulRead() {
        let store = VMResourceStatsStore(now: { self.time })
        let old = store.beginRead(machineID: "vm")
        let newer = store.beginRead(machineID: "vm")
        let reading = stats(memory: 8192, disk: 32768)
        store.finishRead(newer, stats: reading)
        store.finishRead(old, stats: nil)
        #expect(store.snapshot["vm"] == reading)
    }

    @Test func newerFailedAttemptDoesNotSuppressAnOlderSuccessfulObservation() {
        let store = VMResourceStatsStore(now: { self.time })
        let old = store.beginRead(machineID: "vm")
        let newer = store.beginRead(machineID: "vm")
        store.finishRead(newer, stats: nil)
        let reading = stats(memory: 8192, disk: 32768)
        store.finishRead(old, stats: reading)
        #expect(store.snapshot["vm"] == reading)
    }

    @Test func newerSuccessfulObservationSupersedesOlderSuccess() {
        let store = VMResourceStatsStore(now: { self.time })
        let old = store.beginRead(machineID: "vm")
        let newer = store.beginRead(machineID: "vm")
        let reading = stats(memory: 16384, disk: 65536)
        store.finishRead(newer, stats: reading)
        store.finishRead(old, stats: stats(memory: 8192, disk: 32768))
        #expect(store.snapshot["vm"] == reading)
    }

    @Test func eventsCoalesceOnlyAffectedMachinesAndRetentionIsQuiet() {
        let store = VMResourceStatsStore(now: { self.time })
        for id in ["a", "b", "c"] {
            store.finishRead(store.beginRead(machineID: id), stats: stats(memory: 8192, disk: 32768))
        }
        let changes = store.changes()
        #expect(changes.takeMachineIDs() == nil)
        store.finishRead(store.beginRead(machineID: "a"), stats: stats(memory: 8192, disk: 32768))
        store.finishRead(store.beginRead(machineID: "b"), stats: stats(memory: 8192, disk: 32768))
        store.finishRead(store.beginRead(machineID: "a"), stats: stats(memory: 8192, disk: 32768))
        #expect(changes.takeMachineIDs() == Set(["a", "b"]))
        store.retain(machineIDs: ["a", "b", "c"], token: store.beginRetention())
        #expect(changes.takeMachineIDs() == Set<String>())
        store.retain(machineIDs: ["a", "c"], token: store.beginRetention())
        #expect(changes.takeMachineIDs() == Set(["b"]))
    }

    @Test func failedPostResizePollRetainsOnlyTheConfirmedNewShape() {
        let store = VMResourceStatsStore(now: { self.time })
        store.finishRead(store.beginRead(machineID: "vm"), stats: stats(memory: 8192, disk: 32768))
        let resize = store.beginResize(machineID: "vm")
        store.finishResize(resize, stats: stats(memory: 16384, disk: 65536, cpus: 8))
        let unavailable = store.finishRead(store.beginRead(machineID: "vm"), stats: nil)
        #expect(unavailable.cpus == 8)
        #expect(unavailable.memoryTotalMb == 16384)
        #expect(unavailable.diskTotalMb == 65536)
        #expect(unavailable.cpuPercent == nil)
        #expect(unavailable.resourceSampledAt == nil)
    }

    @Test func failedResizeDoesNotRestorePossiblySupersededCapacity() {
        let store = VMResourceStatsStore(now: { self.time })
        let before = stats(memory: 8192, disk: 32768)
        store.finishRead(store.beginRead(machineID: "vm"), stats: before)
        let latePoll = store.beginRead(machineID: "vm")
        let resize = store.beginResize(machineID: "vm")
        store.finishResize(resize, stats: nil)
        store.finishRead(latePoll, stats: before)
        let missing = store.finishRead(store.beginRead(machineID: "vm"), stats: nil)
        #expect(missing.memoryTotalMb == nil)
        #expect(missing.diskTotalMb == nil)
        let confirmed = stats(memory: 16384, disk: 65536)
        store.finishRead(store.beginRead(machineID: "vm"), stats: confirmed)
        #expect(store.snapshot["vm"] == confirmed)
    }

    @Test func otherMachinesAndEverySubscriberShareTheAcceptedState() async {
        let store = VMResourceStatsStore(now: { self.time })
        let firstSubscription = store.changes()
        let secondSubscription = store.changes()
        var first = firstSubscription.events.makeAsyncIterator()
        var second = secondSubscription.events.makeAsyncIterator()
        _ = await first.next()
        _ = await second.next()
        let other = stats(memory: 4096, disk: 16384)
        store.finishRead(store.beginRead(machineID: "other"), stats: other)
        let after = stats(memory: 16384, disk: 65536)
        store.finishResize(store.beginResize(machineID: "vm"), stats: after)
        _ = await first.next()
        #expect(store.snapshot["vm"] == after)
        _ = await second.next()
        #expect(store.snapshot["vm"] == after)
        #expect(store.snapshot["other"] == other)
    }

    @Test func resetAndRemovalFenceOutstandingRequests() {
        let store = VMResourceStatsStore(now: { self.time })
        let read = store.beginRead(machineID: "vm")
        let resize = store.beginResize(machineID: "other")
        store.reset()
        store.finishRead(read, stats: stats(memory: 8192, disk: 32768))
        store.finishResize(resize, stats: stats(memory: 8192, disk: 32768))
        #expect(store.snapshot.isEmpty)
        let removed = store.beginRead(machineID: "removed")
        store.retain(machineIDs: [], token: store.beginRetention())
        store.finishRead(removed, stats: stats(memory: 8192, disk: 32768))
        #expect(store.snapshot.isEmpty)
    }

    @Test func cliOnlyReadsHaveABoundedRetentionLimit() {
        let store = VMResourceStatsStore(now: { self.time })
        for index in 0..<300 {
            store.finishRead(store.beginRead(machineID: "vm-\(index)"), stats: stats(memory: 8192, disk: 32768))
        }
        #expect(store.snapshot.count == 256)
        #expect(store.snapshot["vm-0"] == nil)
        #expect(store.snapshot["vm-299"] != nil)
    }

    @Test func listedFleetSurvivesConcurrentReadsAndCLIOnlyCacheEviction() {
        let store = VMResourceStatsStore(now: { self.time })
        let fleet = Set((0..<300).map { "vm-\($0)" })
        let reading = stats(memory: 8192, disk: 32768)
        store.retain(machineIDs: fleet, token: store.beginRetention())
        // The panel starts a read for every machine before the network replies.
        let reads = fleet.map { store.beginRead(machineID: $0) }
        for read in reads { store.finishRead(read, stats: reading) }
        #expect(store.snapshot.count == fleet.count)
        #expect(fleet.allSatisfy { store.stats(for: $0) == reading })

        for index in 0..<300 {
            store.finishRead(store.beginRead(machineID: "cli-\(index)"), stats: reading)
        }
        #expect(store.snapshot.count == fleet.count + 256)
        #expect(fleet.allSatisfy { store.stats(for: $0) == reading })
        #expect(store.stats(for: "cli-0") == nil)
        #expect(store.stats(for: "cli-299") == reading)

        let removedRead = store.beginRead(machineID: "vm-0")
        store.retain(machineIDs: fleet.subtracting(["vm-0"]), token: store.beginRetention())
        store.finishRead(removedRead, stats: reading)
        #expect(store.snapshot.count == fleet.count - 1)
        #expect(store.stats(for: "vm-0") == nil)
    }

    @Test func authResetClearsAuthoritativeFleetRetention() {
        let store = VMResourceStatsStore(now: { self.time })
        let fleet = Set((0..<300).map { "vm-\($0)" })
        store.retain(machineIDs: fleet, token: store.beginRetention())
        store.reset()
        for id in fleet {
            store.finishRead(store.beginRead(machineID: id), stats: stats(memory: 8192, disk: 32768))
        }
        #expect(store.snapshot.count == 256)
    }

    @Test func aValidatedFleetReplacesThePreviousScopeAfterReset() {
        let store = VMResourceStatsStore(now: { self.time })
        let oldFleet = Set(["old-a", "old-b"])
        let newFleet = Set(["new-a", "new-b"])
        let reading = stats(memory: 8192, disk: 32768)
        store.retain(machineIDs: oldFleet, token: store.beginRetention())
        store.finishRead(store.beginRead(machineID: "old-a"), stats: reading)
        store.reset()

        // The shared client accepts the list only in its current auth scope.
        store.retain(machineIDs: newFleet, token: store.beginRetention())
        store.finishRead(store.beginRead(machineID: "new-a"), stats: reading)
        for id in oldFleet { #expect(store.stats(for: id) == nil) }
        #expect(store.stats(for: "new-a") == reading)
        #expect(store.stats(for: "new-b") == nil)
    }

    @Test(arguments: [false, true])
    func olderListResponseCannotReplaceNewerFleetRetention(resetDuringRequest: Bool) {
        let store = VMResourceStatsStore(now: { self.time })
        let oldToken = store.beginRetention()
        if resetDuringRequest { store.reset() }
        let newToken = store.beginRetention()
        store.retain(machineIDs: ["new"], token: newToken)
        store.retain(machineIDs: ["old"], token: oldToken)
        store.finishRead(store.beginRead(machineID: "new"), stats: stats(memory: 8192, disk: 32768))
        for index in 0..<256 {
            store.finishRead(store.beginRead(machineID: "cli-\(index)"), stats: stats(memory: 8192, disk: 32768))
        }
        #expect(store.stats(for: "new") != nil)
    }
}
