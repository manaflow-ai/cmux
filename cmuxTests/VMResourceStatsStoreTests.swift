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
        var first = store.changes().makeAsyncIterator()
        var second = store.changes().makeAsyncIterator()
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
        store.retain(machineIDs: [])
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
}
