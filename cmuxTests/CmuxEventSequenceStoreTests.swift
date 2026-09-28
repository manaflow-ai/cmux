import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxEventSequenceStoreTests: XCTestCase {
    func testDurablePublishDoesNotPersistSequenceForEveryEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-sequence-lease-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let bus = CmuxEventBus(retainedEventLimit: 4, eventLogURL: logURL)
        await bus.waitUntilRestored()

        bus.publish(name: "one", category: "test", source: "test")
        bus.flushEventLogForTesting()
        let sequenceURL = logURL.appendingPathExtension("seq")
        let firstHighWater = try Int64(String(contentsOf: sequenceURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertGreaterThan(firstHighWater, 1)

        bus.publish(name: "two", category: "test", source: "test")
        bus.flushEventLogForTesting()
        let secondHighWater = try Int64(String(contentsOf: sequenceURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(secondHighWater, firstHighWater)
    }

    func testSequenceStoresSharingFileLeaseUniqueRanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-sequence-shared-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = CmuxEventSequenceStore(eventLogURL: logURL, blockSize: 8)
        let secondStore = CmuxEventSequenceStore(eventLogURL: logURL, blockSize: 8)
        let valuesLock = NSLock()
        var values: [Int64] = []
        let group = DispatchGroup()
        let firstQueue = DispatchQueue(label: "cmux.event-sequence-test.first")
        let secondQueue = DispatchQueue(label: "cmux.event-sequence-test.second")

        for _ in 0..<64 {
            group.enter()
            firstQueue.async {
                if let sequence = firstStore.allocate() {
                    valuesLock.lock()
                    values.append(sequence)
                    valuesLock.unlock()
                }
                group.leave()
            }
            group.enter()
            secondQueue.async {
                if let sequence = secondStore.allocate() {
                    valuesLock.lock()
                    values.append(sequence)
                    valuesLock.unlock()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(values.count, 128)
        XCTAssertEqual(Set(values).count, values.count)
    }
}
