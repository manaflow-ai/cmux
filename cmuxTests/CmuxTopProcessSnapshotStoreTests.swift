import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CmuxTopProcessSnapshotStoreTests {
    @Test
    func concurrentEquivalentRequestsShareOneCapture() async {
#if DEBUG
        let metricsStore = ProcessPerformanceMetrics()
#endif
        let capturer = ControlledProcessSnapshotCapturer()
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
#if DEBUG
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            },
            metrics: metricsStore
        )
#else
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )
#endif

        let first = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                consumer: .portScannerPanel
            )
        }
        await capturer.waitForCallCount(1)
        let second = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                consumer: .portScannerPanel
            )
        }
        await capturer.releaseNext()

        let firstSnapshot = await first.value
        let secondSnapshot = await second.value
        #expect(firstSnapshot === secondSnapshot)
        #expect(await capturer.callCount() == 1)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
#if DEBUG
        let metrics = metricsStore.snapshot()
        #expect(metrics.processSnapshots.captureStarted == 1)
        #expect(metrics.processSnapshots.captureCompleted == 1)
        #expect(metrics.processSnapshots.maximumInFlight == 1)
        #expect(metrics.processSnapshots.lastGeneration == 1)
        #expect(
            metrics.consumerGenerationReuse[ProcessSnapshotConsumer.portScannerPanel.rawValue]?[1]?.inFlight == 1
        )
#endif
    }

    @Test
    func strongerRequestWaitsForAndThenUpgradesWeakerCapture() async {
        let capturer = ControlledProcessSnapshotCapturer()
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )

        let basic = Task {
            await store.snapshot(requirements: .basic, maximumAge: 0)
        }
        await capturer.waitForCallCount(1)
        let detailed = Task {
            await store.snapshot(requirements: [.processDetails, .cmuxScope], maximumAge: 0)
        }

        await capturer.releaseNext()
        _ = await basic.value
        await capturer.waitForCallCount(2)
        await capturer.releaseNext()
        let detailedSnapshot = await detailed.value

        #expect(detailedSnapshot.hasCMUXScope)
        #expect(await capturer.capturedRequirements() == [
            .basic,
            [.processDetails, .cmuxScope]
        ])
        #expect(await capturer.maximumConcurrentCaptures() == 1)
    }

    @Test
    func cacheRespectsFreshnessAndCapabilityRequirements() async {
#if DEBUG
        let metricsStore = ProcessPerformanceMetrics()
#endif
        let capturer = ControlledProcessSnapshotCapturer(autoRelease: true)
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
#if DEBUG
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            },
            metrics: metricsStore
        )
#else
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )
#endif

        let first = await store.snapshot(
            requirements: .basic,
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        await clock.advance(by: 2)
        let cached = await store.snapshot(
            requirements: .basic,
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        let upgraded = await store.snapshot(
            requirements: .processDetails,
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        await clock.advance(by: 4)
        let refreshed = await store.snapshot(
            requirements: .basic,
            maximumAge: 3,
            consumer: .processDetectedResume
        )

        #expect(first === cached)
        #expect(upgraded !== cached)
        #expect(refreshed !== upgraded)
        #expect(await capturer.callCount() == 3)
#if DEBUG
        let metrics = metricsStore.snapshot()
        #expect(
            metrics.consumerGenerationReuse[ProcessSnapshotConsumer.processDetectedResume.rawValue]?[1]?.cache == 1
        )
#endif
    }
}

@Suite
struct PortScannerSharedSnapshotTests {
    @Test
    func staleRevisionIsRejectedAndCounted() {
#if DEBUG
        let metricsStore = ProcessPerformanceMetrics()
        #expect(!PortScanner.acceptsResult(
            currentRevision: 8,
            expectedRevision: 7,
            staleMetric: .portAgentRevision,
            metrics: metricsStore
        ))
        #expect(PortScanner.acceptsResult(
            currentRevision: 8,
            expectedRevision: 8,
            staleMetric: .portAgentRevision,
            metrics: metricsStore
        ))
        let metrics = metricsStore.snapshot()
        #expect(metrics.staleRejections[ProcessStaleRejection.portAgentRevision.rawValue] == 1)
#endif
    }

    @Test
    func processTreeExpansionIncludesForksAndDetachedAgentRoots() {
        let firstWorkspace = UUID()
        let detachedWorkspace = UUID()
        let snapshot = processSnapshot([
            process(pid: 10, parentPID: 1),
            process(pid: 20, parentPID: 10),
            process(pid: 30, parentPID: 20),
            process(pid: 90, parentPID: 1),
            process(pid: 91, parentPID: 90)
        ])

        let expanded = PortScanner.expandAgentProcessTree(
            agentPIDsByWorkspace: [
                firstWorkspace: [10],
                detachedWorkspace: [90]
            ],
            processSnapshot: snapshot
        )

        #expect(expanded[10] == [firstWorkspace])
        #expect(expanded[20] == [firstWorkspace])
        #expect(expanded[30] == [firstWorkspace])
        #expect(expanded[90] == [detachedWorkspace])
        #expect(expanded[91] == [detachedWorkspace])
    }

    @Test
    func socketInfoReportsIPv4AndIPv6ListenersButExcludesNonListeners() {
        var ipv4Listener = socket_fdinfo()
        ipv4Listener.psi.soi_kind = SOCKINFO_TCP
        ipv4Listener.psi.soi_protocol = IPPROTO_TCP
        ipv4Listener.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_LISTEN
        ipv4Listener.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4)
        ipv4Listener.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(3_000).bigEndian)

        var ipv6Listener = ipv4Listener
        ipv6Listener.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV6)
        ipv6Listener.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(9_229).bigEndian)

        var connected = ipv4Listener
        connected.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_ESTABLISHED
        var nonTCP = ipv4Listener
        nonTCP.psi.soi_kind = SOCKINFO_IN

        #expect(PortScanner.listeningTCPPort(from: ipv4Listener) == 3_000)
        #expect(PortScanner.listeningTCPPort(from: ipv6Listener) == 9_229)
        #expect(PortScanner.listeningTCPPort(from: connected) == nil)
        #expect(PortScanner.listeningTCPPort(from: nonTCP) == nil)
    }

    @Test
    func libprocScanDiscoversLiveIPv4AndIPv6ListenersOnly() throws {
        let ipv4 = try makeBoundTCPSocket(family: AF_INET, listening: true)
        defer { Darwin.close(ipv4.descriptor) }
        let ipv6 = try makeBoundTCPSocket(family: AF_INET6, listening: true)
        defer { Darwin.close(ipv6.descriptor) }
        let nonListener = try makeBoundTCPSocket(family: AF_INET, listening: false)
        defer { Darwin.close(nonListener.descriptor) }

        let pid = Int(Darwin.getpid())
        let ports = PortScanner.scanListeningPorts(pids: [pid])[pid] ?? []

        #expect(ports.contains(ipv4.port))
        #expect(ports.contains(ipv6.port))
        #expect(!ports.contains(nonListener.port))
    }

    private func processSnapshot(_ processes: [CmuxTopProcessInfo]) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(),
            includesProcessDetails: false,
            includesCMUXScope: false
        )
    }

    private func process(pid: Int, parentPID: Int) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: "process-\(pid)",
            path: nil,
            ttyDevice: nil,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: pid,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }

    private func makeBoundTCPSocket(
        family: Int32,
        listening: Bool
    ) throws -> (descriptor: Int32, port: Int) {
        let descriptor = Darwin.socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw currentPOSIXError() }

        do {
            let port: Int
            switch family {
            case AF_INET:
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
                try bindSocket(descriptor, address: &address)
                try startListeningIfNeeded(descriptor, listening: listening)
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                guard withUnsafeMutablePointer(to: &address, { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.getsockname(descriptor, $0, &length)
                    }
                }) == 0 else {
                    throw currentPOSIXError()
                }
                port = Int(UInt16(bigEndian: address.sin_port))
            case AF_INET6:
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_addr = in6addr_loopback
                try bindSocket(descriptor, address: &address)
                try startListeningIfNeeded(descriptor, listening: listening)
                var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                guard withUnsafeMutablePointer(to: &address, { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.getsockname(descriptor, $0, &length)
                    }
                }) == 0 else {
                    throw currentPOSIXError()
                }
                port = Int(UInt16(bigEndian: address.sin6_port))
            default:
                throw POSIXError(.EAFNOSUPPORT)
            }
            return (descriptor, port)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func bindSocket<Address>(
        _ descriptor: Int32,
        address: inout Address
    ) throws {
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<Address>.size))
            }
        }
        guard result == 0 else { throw currentPOSIXError() }
    }

    private func startListeningIfNeeded(
        _ descriptor: Int32,
        listening: Bool
    ) throws {
        guard listening else { return }
        guard Darwin.listen(descriptor, 1) == 0 else { throw currentPOSIXError() }
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

@Suite
struct PortScanSnapshotStoreTests {
    @Test
    func concurrentCoveredRequestsShareOneLibprocCapture() async {
#if DEBUG
        let metricsStore = ProcessPerformanceMetrics()
#endif
        let capturer = ControlledPortScanCapturer()
        let clock = PortScanTestClock(now: Date(timeIntervalSince1970: 100))
#if DEBUG
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) },
            metrics: metricsStore
        )
#else
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) }
        )
#endif

        let first = Task {
            await store.snapshot(pids: [10, 20], maximumAge: 2)
        }
        await capturer.waitForCallCount(1)
        let covered = Task {
            await store.snapshot(pids: [20], maximumAge: 2)
        }
#if DEBUG
        #expect(await waitForMetrics {
            let reuse = metricsStore.snapshot().lsof.reuse
            return reuse.cache + reuse.inFlight == 1
        })
#else
        await clock.waitForReadCount(2)
#endif
        await capturer.releaseNext()

        let firstResult = await first.value
        let coveredResult = await covered.value
        #expect(firstResult == [10: [1_010], 20: [1_020]])
        #expect(coveredResult == firstResult)
        #expect(await capturer.callCount() == 1)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
#if DEBUG
        let metrics = metricsStore.snapshot()
        #expect(metrics.lsof.started == 1)
        #expect(metrics.lsof.completed == 1)
        #expect(metrics.lsof.maximumInFlight == 1)
        #expect(metrics.lsof.reuse.cache + metrics.lsof.reuse.inFlight == 1)
        let wireLsof = metrics.foundationObject["lsof"] as? [String: Any]
        #expect(wireLsof?["backend"] as? String == "libproc")
        #expect(wireLsof?["process_launches"] as? Int == 0)
#endif
    }

    @Test
    func uncoveredRequestsCoalesceIntoOneBoundedFollowup() async {
#if DEBUG
        let metricsStore = ProcessPerformanceMetrics()
#endif
        let capturer = ControlledPortScanCapturer()
        let clock = PortScanTestClock(now: Date(timeIntervalSince1970: 100))
#if DEBUG
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) },
            metrics: metricsStore
        )
#else
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) }
        )
#endif

        let first = Task {
            await store.snapshot(pids: [10], maximumAge: 2)
        }
        await capturer.waitForCallCount(1)
        let second = Task {
            await store.snapshot(pids: [20], maximumAge: 2)
        }
        let third = Task {
            await store.snapshot(pids: [30], maximumAge: 2)
        }
#if DEBUG
        #expect(await waitForMetrics {
            metricsStore.snapshot().lsof.coalescedRequests == 2
        })
#else
        await clock.waitForReadCount(3)
#endif

        await capturer.releaseNext()
        await capturer.waitForCallCount(2)
        #expect(await capturer.capturedPIDRequests() == [[10], [20, 30]])
        #expect(await capturer.maximumConcurrentCaptures() == 1)
        await capturer.releaseNext()

        #expect(await first.value == [10: [1_010]])
        #expect(await second.value == [20: [1_020], 30: [1_030]])
        #expect(await third.value == [20: [1_020], 30: [1_030]])
        #expect(await capturer.callCount() == 2)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
    }

    @Test
    func freshSupersetCacheServesSubsetsAndExpiryRefreshesListeners() async {
#if DEBUG
        let metricsStore = ProcessPerformanceMetrics()
#endif
        let capturer = ControlledPortScanCapturer(autoRelease: true)
        let clock = PortScanTestClock(now: Date(timeIntervalSince1970: 100))
#if DEBUG
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) },
            metrics: metricsStore
        )
#else
        let store = PortScanSnapshotStore(
            now: { await clock.read() },
            capture: { pids in await capturer.capture(pids: pids) }
        )
#endif

        let first = await store.snapshot(pids: [10, 20], maximumAge: 2)
        let cached = await store.snapshot(pids: [20], maximumAge: 2)
        await clock.advance(by: 3)
        let refreshed = await store.snapshot(pids: [20], maximumAge: 2)

        #expect(first == [10: [1_010], 20: [1_020]])
        #expect(cached == first)
        #expect(refreshed == [20: [1_020]])
        #expect(await capturer.callCount() == 2)
        #expect(await capturer.capturedPIDRequests() == [[10, 20], [20]])
#if DEBUG
        let metrics = metricsStore.snapshot()
        #expect(metrics.lsof.reuse.cache == 1)
#endif
    }

    private func waitForMetrics(
        _ predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<10_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

#if DEBUG
@Suite
struct ProcessPerformanceMetricsEpochTests {
    @Test
    func completionsFromBeforeResetDoNotEnterTheNewMeasurementEpoch() {
        let metricsStore = ProcessPerformanceMetrics()
        let processToken = metricsStore.processSnapshotCaptureStarted(
            generation: 1,
            requirementsRawValue: 0
        )
        let lsofToken = metricsStore.lsofStarted(pidCount: 3)
        let operationToken = metricsStore.operationStarted(.portFilter, inputCount: 3)

        metricsStore.reset()
        metricsStore.processSnapshotCaptureCompleted(
            processToken,
            generation: 1,
            processCount: 3
        )
        metricsStore.recordLsofReuse(.cache, token: lsofToken)
        metricsStore.recordLsofCoalescedRequest(token: lsofToken)
        metricsStore.lsofCompleted(lsofToken)
        metricsStore.operationCompleted(operationToken, outputCount: 2)

        let metrics = metricsStore.snapshot()
        #expect(metrics.processSnapshots.captureStarted == 0)
        #expect(metrics.processSnapshots.captureCompleted == 0)
        #expect(metrics.processSnapshots.inFlight == 0)
        #expect(metrics.generations.isEmpty)
        #expect(metrics.lsof.started == 0)
        #expect(metrics.lsof.completed == 0)
        #expect(metrics.lsof.inFlight == 0)
        #expect(metrics.lsof.coalescedRequests == 0)
        #expect(metrics.lsof.reuse == ProcessPerformanceReuseMetrics())
        #expect(metrics.operations.isEmpty)
    }
}
#endif

private actor ControlledProcessSnapshotCapturer {
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

private actor ProcessSnapshotTestClock {
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

private actor ControlledPortScanCapturer {
    private let autoRelease: Bool
    private var requests: [Set<Int>] = []
    private var activeCaptures = 0
    private var maximumActiveCaptures = 0
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(autoRelease: Bool = false) {
        self.autoRelease = autoRelease
    }

    func capture(pids: Set<Int>) async -> [Int: Set<Int>] {
        requests.append(pids)
        activeCaptures += 1
        maximumActiveCaptures = max(maximumActiveCaptures, activeCaptures)
        resumeSatisfiedCallCountWaiters()
        if !autoRelease {
            await withCheckedContinuation { continuation in
                releases.append(continuation)
            }
        }
        activeCaptures -= 1
        return Dictionary(uniqueKeysWithValues: pids.map { ($0, [$0 + 1_000]) })
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

private actor PortScanTestClock {
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
