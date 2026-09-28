import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Sendable safety: the lock guards the only mutable state shared by the two test queues.
private final class SequenceValuesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func append(_ value: Int64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

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
        let firstHighWater = try XCTUnwrap(Int64(String(contentsOf: sequenceURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertGreaterThan(firstHighWater, Int64(1))

        bus.publish(name: "two", category: "test", source: "test")
        bus.flushEventLogForTesting()
        let secondHighWater = try XCTUnwrap(Int64(String(contentsOf: sequenceURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(secondHighWater, firstHighWater)
    }

    func testSequenceStoresSharingFileLeaseUniqueRanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-sequence-shared-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = CmuxEventSequenceStore(eventLogURL: logURL, blockSize: 8)
        let secondStore = CmuxEventSequenceStore(eventLogURL: logURL, blockSize: 8)
        let values = SequenceValuesBox()
        let group = DispatchGroup()
        let firstQueue = DispatchQueue(label: "cmux.event-sequence-test.first")
        let secondQueue = DispatchQueue(label: "cmux.event-sequence-test.second")

        for _ in 0..<64 {
            group.enter()
            firstQueue.async {
                if let sequence = firstStore.allocate() {
                    values.append(sequence)
                }
                group.leave()
            }
            group.enter()
            secondQueue.async {
                if let sequence = secondStore.allocate() {
                    values.append(sequence)
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let allocated = values.snapshot
        XCTAssertEqual(allocated.count, 128)
        XCTAssertEqual(Set(allocated).count, allocated.count)
    }
}
