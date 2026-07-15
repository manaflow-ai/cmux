import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
    func panelMutationRejectsGenerationAdvancedWhileMainActorIsBusy() async {
        let gate = PortScanner.ResultGenerationGate()
        gate.advancePanel(to: 1)
        let barrier = MainActorQueueBarrier()
        barrier.blockMainActor()
        await barrier.waitUntilBlocked()

        let mutation = Task { @MainActor in
            gate.applyPanel(ifCurrent: 1) { true }
        }
        gate.advancePanel(to: 2)
        barrier.releaseMainActor()

        #expect(await mutation.value == nil)
    }

    @Test
    func agentMutationRejectsGenerationAdvancedWhileMainActorIsBusy() async {
        let workspaceId = UUID()
        let gate = PortScanner.ResultGenerationGate()
        gate.advanceAgent(workspaceId: workspaceId, to: 1)
        let barrier = MainActorQueueBarrier()
        barrier.blockMainActor()
        await barrier.waitUntilBlocked()

        let mutation = Task { @MainActor in
            gate.applyAgent(workspaceId: workspaceId, ifCurrent: 1) { true }
        }
        gate.advanceAgent(workspaceId: workspaceId, to: 2)
        barrier.releaseMainActor()

        #expect(await mutation.value == nil)
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
    func descendantLookupDoesNotMixLiveChildrenIntoCapturedGeneration() throws {
        let childInput = Pipe()
        let liveChild = Process()
        liveChild.executableURL = URL(fileURLWithPath: "/bin/cat")
        liveChild.standardInput = childInput
        liveChild.standardOutput = FileHandle.nullDevice
        liveChild.standardError = FileHandle.nullDevice
        try liveChild.run()
        defer {
            if liveChild.isRunning {
                liveChild.terminate()
            }
            liveChild.waitUntilExit()
        }

        let rootPID = Int(Darwin.getpid())
        let capturedChildPID = 999_999
        let snapshot = processSnapshot([
            process(pid: rootPID, parentPID: 1),
            process(pid: capturedChildPID, parentPID: rootPID)
        ])

        #expect(liveChild.isRunning)
        #expect(snapshot.descendantPIDs(rootPID: rootPID) == [capturedChildPID])
    }

    @Test
    func socketInfoReportsIPv4AndIPv6ListenersButExcludesNonListeners() {
        var ipv4Listener = socket_fdinfo()
        ipv4Listener.psi.soi_kind = Int32(SOCKINFO_TCP)
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
        nonTCP.psi.soi_kind = Int32(SOCKINFO_IN)

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
private final class MainActorQueueBarrier: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func blockMainActor() {
        DispatchQueue.main.async { [self] in
            entered.signal()
            release.wait()
        }
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                entered.wait()
                continuation.resume()
            }
        }
    }

    func releaseMainActor() {
        release.signal()
    }
}
