import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Distinct identity objects used as observer tokens.
private final class FanOutToken {}

/// Unit tests for ``AgentSessionEventFanOut`` — the mechanism that lets one
/// agent process (one ``AgentSessionProcessStore``) feed both a visible surface
/// and a Kanban live backend at once, without ever spawning the agent twice.
@MainActor
@Suite(.serialized)
struct AgentSessionEventFanOutTests {
    private func event(_ type: String) -> [String: Any] { ["type": type] }

    @Test
    func dispatchDeliversToReservedSinkAndEveryObserver() {
        let fanOut = AgentSessionEventFanOut()
        var reserved: [String] = []
        var first: [String] = []
        var second: [String] = []
        let a = FanOutToken()
        let b = FanOutToken()
        fanOut.reservedSink = { reserved.append($0["type"] as? String ?? "") }
        fanOut.addObserver(ObjectIdentifier(a)) { first.append($0["type"] as? String ?? "") }
        fanOut.addObserver(ObjectIdentifier(b)) { second.append($0["type"] as? String ?? "") }

        fanOut.dispatch(event("provider.output"))

        #expect(reserved == ["provider.output"])
        #expect(first == ["provider.output"])
        #expect(second == ["provider.output"])
    }

    @Test
    func removingAnObserverStopsOnlyItsDelivery() {
        let fanOut = AgentSessionEventFanOut()
        var first = 0
        var second = 0
        let a = FanOutToken()
        let b = FanOutToken()
        fanOut.addObserver(ObjectIdentifier(a)) { _ in first += 1 }
        fanOut.addObserver(ObjectIdentifier(b)) { _ in second += 1 }

        fanOut.dispatch(event("provider.started"))
        fanOut.removeObserver(ObjectIdentifier(a))
        fanOut.dispatch(event("provider.output"))

        #expect(first == 1)
        #expect(second == 2)
    }

    @Test
    func dispatchSnapshotsObserversSoReentrantRemovalIsSafe() {
        let fanOut = AgentSessionEventFanOut()
        let a = FanOutToken()
        let b = FanOutToken()
        var bCount = 0
        // Observer A removes B mid-dispatch. Iterating a snapshot must not trap,
        // and B — already in this dispatch's snapshot — still sees THIS event.
        fanOut.addObserver(ObjectIdentifier(a)) { [weak fanOut] _ in
            fanOut?.removeObserver(ObjectIdentifier(b))
        }
        fanOut.addObserver(ObjectIdentifier(b)) { _ in bCount += 1 }

        fanOut.dispatch(event("provider.turnComplete"))
        fanOut.dispatch(event("provider.exit"))

        #expect(bCount == 1)
    }

    @Test
    func reservedSinkAloneStillReceivesEvents() {
        let fanOut = AgentSessionEventFanOut()
        var got: [String] = []
        fanOut.reservedSink = { got.append($0["type"] as? String ?? "") }

        fanOut.dispatch(event("provider.exit"))

        #expect(got == ["provider.exit"])
        #expect(fanOut.hasConsumers)
    }
}
