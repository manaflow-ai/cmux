import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The coordinator's state/link fan-out must not accumulate subscribers that
/// left between yields: `cmux vpn status` polls subscribe and go away without
/// the state ever changing.
@Suite
struct CloudTunnelBroadcastTests {
    @Test("subscribers that stop listening are pruned without a yield")
    func prunesTerminatedSubscribersEagerly() async {
        let broadcast = CloudTunnelBroadcast<Int>()
        for _ in 0..<50 {
            // Drop the stream without ever iterating it: the continuation
            // terminates, the id lands in the inbox.
            _ = broadcast.subscribe(current: 0)
        }
        // A live subscriber stays counted.
        let live = broadcast.subscribe()
        #expect(broadcast.subscriberCount <= 51)
        // The next subscribe prunes everything that terminated so far.
        _ = broadcast.subscribe()
        #expect(broadcast.subscriberCount <= 3)
        withExtendedLifetime(live) {}
    }

    @Test("values reach every live subscriber, first the current one")
    func deliversCurrentThenUpdates() async {
        let broadcast = CloudTunnelBroadcast<Int>()
        let stream = broadcast.subscribe(current: 1)
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
