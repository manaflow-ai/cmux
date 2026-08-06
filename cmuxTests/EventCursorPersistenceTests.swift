import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

struct EventCursorPersistenceTests {
    @Test func burstWritesAreBatchedAndFinalSequenceFlushes() throws {
        var persistedSequences: [Int64] = []
        let start = ContinuousClock().now
        var persistence = EventCursorPersistenceBatch(
            maximumPendingEvents: 128,
            maximumDelay: .seconds(1),
            write: { persistedSequences.append($0) }
        )

        for sequence in 1 ..< 128 {
            try persistence.record(Int64(sequence), now: start)
        }
        #expect(persistedSequences.isEmpty)

        try persistence.record(128, now: start)
        #expect(persistedSequences == [128])

        for sequence in 129 ... 140 {
            try persistence.record(Int64(sequence), now: start)
        }
        try persistence.flush(now: start)
        #expect(persistedSequences == [128, 140])
    }

    @Test func elapsedDelayFlushesPendingSequenceDuringHeartbeat() throws {
        var persistedSequences: [Int64] = []
        let start = ContinuousClock().now
        var persistence = EventCursorPersistenceBatch(
            maximumPendingEvents: 128,
            maximumDelay: .seconds(1),
            write: { persistedSequences.append($0) }
        )

        try persistence.record(41, now: start)
        try persistence.flushIfDue(now: start.advanced(by: .milliseconds(999)))
        #expect(persistedSequences.isEmpty)

        try persistence.flushIfDue(now: start.advanced(by: .seconds(1)))
        #expect(persistedSequences == [41])
    }

    @Test func failedWriteRemainsPendingForRetry() throws {
        struct ExpectedFailure: Error {}

        var shouldFail = true
        var persistedSequences: [Int64] = []
        let start = ContinuousClock().now
        var persistence = EventCursorPersistenceBatch(
            maximumPendingEvents: 1,
            maximumDelay: .seconds(1),
            write: { sequence in
                if shouldFail {
                    throw ExpectedFailure()
                }
                persistedSequences.append(sequence)
            }
        )

        #expect(throws: ExpectedFailure.self) {
            try persistence.record(9, now: start)
        }

        shouldFail = false
        try persistence.flush(now: start)
        #expect(persistedSequences == [9])
    }
}
