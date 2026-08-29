import Foundation
import os
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct MobileHostPOSIXListenerTests {
    /// One-shot bridge from the listener's queue callbacks to async test code.
    /// The watchdog resumes the waiter instead of leaving a cancelled task
    /// suspended in a continuation, so a broken listener fails the test rather
    /// than hanging it.
    private final class AcceptAwaiter: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.cmux.mobile.test.accept-awaiter")
        private var continuation: CheckedContinuation<MobileHostPOSIXAcceptedConnection?, Never>?
        private var delivered = false

        func arm(_ listener: MobileHostPOSIXListener) {
            listener.start(
                onAccepted: { [weak self] accepted in
                    self?.deliver(accepted)
                },
                onCancelled: { [weak self] in
                    self?.deliver(nil)
                }
            )
        }

        func awaitConnection(timeout: TimeInterval = 5) async throws -> MobileHostPOSIXAcceptedConnection {
            let watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.deliver(nil)
            }
            let result: MobileHostPOSIXAcceptedConnection? = await withCheckedContinuation { continuation in
                queue.async {
                    guard !self.delivered else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.continuation = continuation
                }
            }
            watchdog.cancel()
            guard let result else {
                throw NSError(
                    domain: "dev.cmux.mobile.test.accept-awaiter",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "listener did not accept within \(timeout)s"
                    ]
                )
            }
            return result
        }

        private func deliver(_ accepted: MobileHostPOSIXAcceptedConnection?) {
            queue.async {
                guard !self.delivered else { return }
                self.delivered = true
                self.continuation?.resume(returning: accepted)
                self.continuation = nil
            }
        }
    }

    /// Dials `port` on loopback with a blocking client socket and returns the
    /// connected descriptor.
    private func dialLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #require(fd >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw NSError(
                domain: "dev.cmux.mobile.test.dial",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "connect to 127.0.0.1:\(port) failed"]
            )
        }
        return fd
    }

    @Test func listenerAcceptsLoopbackConnectionWithLiveDescriptor() async throws {
        let listener = try MobileHostPOSIXListener(
            preferredPort: nil,
            queue: DispatchQueue(label: "dev.cmux.mobile.test-listener-accept")
        )
        defer { listener.cancel() }
        let awaiter = AcceptAwaiter()
        awaiter.arm(listener)

        let client = try dialLoopback(port: listener.boundPort)
        defer { close(client) }

        let accepted = try await awaiter.awaitConnection()
        #expect(accepted.fileDescriptor >= 0)
        #expect(accepted.peerIsLoopback)

        // The accepted descriptor is a live, connected socket: a round-trip
        // through the client proves the kernel wired both halves.
        let message = Data("ping".utf8)
        try message.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < message.count {
                let written = write(client, base + offset, message.count - offset)
                if written <= 0 { throw NSError(domain: "write", code: Int(errno)) }
                offset += written
            }
        }
        var buffer = [UInt8](repeating: 0, count: message.count)
        var filled = 0
        while filled < message.count {
            let n = read(accepted.fileDescriptor, &buffer, message.count - filled)
            if n <= 0 { throw NSError(domain: "read", code: Int(errno)) }
            filled += n
        }
        #expect(Data(buffer) == message)
        close(accepted.fileDescriptor)
    }

    @Test func listenerBindFailsWhenPreferredPortIsOccupied() throws {
        let blocker = try MobileHostPOSIXListener(
            preferredPort: nil,
            queue: DispatchQueue(label: "dev.cmux.mobile.test-listener-blocker")
        )
        defer { blocker.cancel() }

        #expect(throws: MobileHostPOSIXListener.ListenerError.bindFailed(Int32(EADDRINUSE))) {
            _ = try MobileHostPOSIXListener(
                preferredPort: blocker.boundPort,
                queue: DispatchQueue(label: "dev.cmux.mobile.test-listener-conflict")
            )
        }
    }

    @Test func listenerCancelStopsAcceptingAndFiresCancelledOnce() async throws {
        let listener = try MobileHostPOSIXListener(
            preferredPort: nil,
            queue: DispatchQueue(label: "dev.cmux.mobile.test-listener-cancel")
        )
        let cancelledCount = OSAllocatedUnfairLock(initialState: 0)
        listener.start(
            onAccepted: { accepted in close(accepted.fileDescriptor) },
            onCancelled: {
                _ = cancelledCount.withLock { $0 += 1 }
            }
        )
        listener.cancel()
        listener.cancel()

        // The cancel handler runs on the listener queue; poll for it with a
        // bounded deadline instead of a fixed sleep.
        for _ in 0..<300 {
            if cancelledCount.withLock({ $0 }) == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cancelledCount.withLock { $0 } == 1)

        // The port is released: a fresh listener can bind it.
        let replacement = try MobileHostPOSIXListener(
            preferredPort: listener.boundPort,
            queue: DispatchQueue(label: "dev.cmux.mobile.test-listener-replacement")
        )
        replacement.cancel()
    }

    @Test func listenerDisarmKeepsIntentionalTeardownSilent() async throws {
        let listener = try MobileHostPOSIXListener(
            preferredPort: nil,
            queue: DispatchQueue(label: "dev.cmux.mobile.test-listener-disarm")
        )
        let cancelledCount = OSAllocatedUnfairLock(initialState: 0)
        listener.start(
            onAccepted: { accepted in close(accepted.fileDescriptor) },
            onCancelled: {
                _ = cancelledCount.withLock { $0 += 1 }
            }
        )
        listener.disarm()
        listener.cancel()
        for _ in 0..<50 {
            if cancelledCount.withLock({ $0 }) > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cancelledCount.withLock { $0 } == 0)
    }

    @Test func loopbackPeerClassificationMatchesOldEndpointSemantics() {
        func ipv4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> sockaddr_storage {
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { raw in
                let sin = raw.bindMemory(to: sockaddr_in.self).baseAddress!
                sin.pointee.sin_family = sa_family_t(AF_INET)
                sin.pointee.sin_addr = in_addr(
                    s_addr: UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
                )
            }
            return storage
        }

        func ipv6(_ bytes: [UInt8]) -> sockaddr_storage {
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { raw in
                let sin6 = raw.bindMemory(to: sockaddr_in6.self).baseAddress!
                sin6.pointee.sin6_family = sa_family_t(AF_INET6)
                _ = withUnsafeMutableBytes(of: &sin6.pointee.sin6_addr) { addr in
                    for (index, byte) in bytes.enumerated() {
                        addr[index] = byte
                    }
                }
            }
            return storage
        }

        let mappedLoopback: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 0, 0, 1]
        var v6Loopback: [UInt8] = Array(repeating: 0, count: 16)
        v6Loopback[15] = 1

        #expect(MobileHostPOSIXListener.isLoopbackPeer(ipv4(127, 0, 0, 1)))
        #expect(MobileHostPOSIXListener.isLoopbackPeer(ipv4(127, 255, 255, 254)))
        #expect(MobileHostPOSIXListener.isLoopbackPeer(ipv6(v6Loopback)))
        #expect(MobileHostPOSIXListener.isLoopbackPeer(ipv6(mappedLoopback)))
        #expect(!MobileHostPOSIXListener.isLoopbackPeer(ipv4(100, 88, 118, 71)))
        #expect(!MobileHostPOSIXListener.isLoopbackPeer(ipv4(192, 168, 0, 3)))
        #expect(!MobileHostPOSIXListener.isLoopbackPeer(ipv4(8, 8, 8, 8)))
    }
}
