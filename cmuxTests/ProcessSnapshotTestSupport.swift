import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

actor ControlledProcessSnapshotCapturer {
    private let autoRelease: Bool
    private var requirements: [CmuxTopProcessSnapshotRequirements] = []
    private var activeCaptures = 0
    private var maximumActiveCaptures = 0
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(autoRelease: Bool = false) {
        self.autoRelease = autoRelease
    }

    func capture(requirements: CmuxTopProcessSnapshotRequirements) async -> CmuxTopProcessSnapshot {
        self.requirements.append(requirements)
        activeCaptures += 1
        maximumActiveCaptures = max(maximumActiveCaptures, activeCaptures)
        resumeSatisfiedCallCountWaiters()
        if !autoRelease {
            await withCheckedContinuation { continuation in
                releases.append(continuation)
            }
        }
        activeCaptures -= 1
        return CmuxTopProcessSnapshot(
            processes: [],
            sampledAt: Date(timeIntervalSince1970: TimeInterval(self.requirements.count)),
            includesProcessDetails: requirements.contains(.processDetails),
            includesCMUXScope: requirements.contains(.cmuxScope)
        )
    }

    func waitForCallCount(_ count: Int) async {
        guard requirements.count < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func releaseNext() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }

    func releaseAll() {
        let pending = releases
        releases.removeAll(keepingCapacity: true)
        for continuation in pending {
            continuation.resume()
        }
    }

    func callCount() -> Int {
        requirements.count
    }

    func capturedRequirements() -> [CmuxTopProcessSnapshotRequirements] {
        requirements
    }

    func maximumConcurrentCaptures() -> Int {
        maximumActiveCaptures
    }

    private func resumeSatisfiedCallCountWaiters() {
        let satisfied = callCountWaiters.filter { requirements.count >= $0.count }
        callCountWaiters.removeAll { requirements.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

actor ProcessSnapshotTestClock {
    private var now: Date

    init(now: Date) {
        self.now = now
    }

    func read() -> Date {
        now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

actor ControlledPortScanCapturer {
    private let autoRelease: Bool
    private let resultIncludesCaptureOrdinal: Bool
    private var requests: [Set<Int>] = []
    private var activeCaptures = 0
    private var maximumActiveCaptures = 0
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        autoRelease: Bool = false,
        resultIncludesCaptureOrdinal: Bool = false
    ) {
        self.autoRelease = autoRelease
        self.resultIncludesCaptureOrdinal = resultIncludesCaptureOrdinal
    }

    func capture(pids: Set<Int>) async -> [Int: Set<Int>] {
        requests.append(pids)
        let captureOrdinal = requests.count
        activeCaptures += 1
        maximumActiveCaptures = max(maximumActiveCaptures, activeCaptures)
        resumeSatisfiedCallCountWaiters()
        if !autoRelease {
            await withCheckedContinuation { continuation in
                releases.append(continuation)
            }
        }
        activeCaptures -= 1
        let portOffset = resultIncludesCaptureOrdinal ? captureOrdinal * 10_000 : 1_000
        return Dictionary(uniqueKeysWithValues: pids.map { ($0, [$0 + portOffset]) })
    }

    func waitForCallCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func releaseNext() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }

    func releaseAll() {
        let pending = releases
        releases.removeAll(keepingCapacity: true)
        for continuation in pending {
            continuation.resume()
        }
    }

    func callCount() -> Int {
        requests.count
    }

    func capturedPIDRequests() -> [Set<Int>] {
        requests
    }

    func maximumConcurrentCaptures() -> Int {
        maximumActiveCaptures
    }

    private func resumeSatisfiedCallCountWaiters() {
        let satisfied = callCountWaiters.filter { requests.count >= $0.count }
        callCountWaiters.removeAll { requests.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

actor PortScanTestClock {
    private var now: Date
    private var readCount = 0
    private var readCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(now: Date) {
        self.now = now
    }

    func read() -> Date {
        readCount += 1
        let satisfied = readCountWaiters.filter { readCount >= $0.count }
        readCountWaiters.removeAll { readCount >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
        return now
    }

    func waitForReadCount(_ count: Int) async {
        guard readCount < count else { return }
        await withCheckedContinuation { continuation in
            readCountWaiters.append((count, continuation))
        }
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

actor SnapshotCompletionBarrierClock {
    private let blockedReadNumbers: Set<Int>
    private var now: Date
    private var readCount = 0
    private var blockedReads: [Int: (Date, CheckedContinuation<Date, Never>)] = [:]
    private var readCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(now: Date, blockedReadNumbers: Set<Int>) {
        self.now = now
        self.blockedReadNumbers = blockedReadNumbers
    }

    func read() async -> Date {
        readCount += 1
        let readNumber = readCount
        let value = now
        if blockedReadNumbers.contains(readNumber) {
            return await withCheckedContinuation { continuation in
                blockedReads[readNumber] = (value, continuation)
                resumeSatisfiedReadCountWaiters()
            }
        }
        resumeSatisfiedReadCountWaiters()
        return value
    }

    func waitForReadCount(_ count: Int) async {
        guard readCount < count else { return }
        await withCheckedContinuation { continuation in
            readCountWaiters.append((count, continuation))
        }
    }

    func resumeRead(_ readNumber: Int) {
        guard let (value, continuation) = blockedReads.removeValue(forKey: readNumber) else {
            return
        }
        continuation.resume(returning: value)
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }

    private func resumeSatisfiedReadCountWaiters() {
        let satisfied = readCountWaiters.filter { readCount >= $0.count }
        readCountWaiters.removeAll { readCount >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

actor SnapshotTaskCompletionCounter {
    private var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let satisfied = waiters.filter { count >= $0.count }
        waiters.removeAll { count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    func waitForCount(_ count: Int) async {
        guard self.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}
