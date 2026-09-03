import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The coordinator's state/link fan-out must not accumulate subscribers that
/// left between yields: `cmux vpn status` polls subscribe and go away without
/// the state ever changing. The owner learns of each departure through the
/// termination callback and removes the id under its own isolation.
@Suite
struct CloudTunnelBroadcastTests {
    @Test("terminated subscribers report their id so the owner can prune them")
    func reportsTerminationForPruning() async {
        var broadcast = CloudTunnelBroadcast<Int>()
        let (idStream, idContinuation) = AsyncStream<UUID>.makeStream()
        var live: [AsyncStream<Int>] = []
        for index in 0..<5 {
            let stream = broadcast.subscribe(current: index) { id in idContinuation.yield(id) }
            if index.isMultiple(of: 2) { live.append(stream) }
            // Odd streams are dropped right away; their continuation terminates.
        }
        var reported: [UUID] = []
        for await id in idStream {
            reported.append(id)
            if reported.count == 2 { break }
        }
        #expect(broadcast.subscriberCount == 5)
        for id in reported { broadcast.remove(id) }
        #expect(broadcast.subscriberCount == 3)
        withExtendedLifetime(live) {}
    }

    @Test("values reach every live subscriber, first the current one")
    func deliversCurrentThenUpdates() async {
        var broadcast = CloudTunnelBroadcast<Int>()
        let stream = broadcast.subscribe(current: 1) { _ in }
        broadcast.yield(2)
        broadcast.yield(3)
        var received: [Int] = []
        for await value in stream {
            received.append(value)
            if received.count == 3 { break }
        }
        #expect(received == [1, 2, 3])
    }
}
