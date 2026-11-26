import Foundation
import Testing
@testable import CMUXMobileCore

/// A Mac with the real ledger and one text buffer per terminal, so each test
/// asserts exactly what reached which terminal.
@MainActor
private final class FakeMac {
    var ledger = MobileTerminalInputLedger()
    var screens: [UUID: String] = [:]
    var closedTerminals: Set<UUID> = []
    var busySequences: Set<UInt64> = []

    func deliver(_ text: String, _ delivery: MobileTerminalInputDelivery) -> MobileTerminalInputAcknowledgement {
        func ack(_ status: MobileTerminalInputAcknowledgement.Status, _ sequence: UInt64, expected: UInt64 = 0) -> MobileTerminalInputAcknowledgement {
            MobileTerminalInputAcknowledgement(status: status, streamID: delivery.streamID, sequence: sequence, expected: expected)
        }
        if closedTerminals.contains(delivery.surfaceID) { return ack(.terminalUnavailable, delivery.sequence) }
        switch ledger.admit(delivery, now: Date()) {
        case .apply:
            if busySequences.remove(delivery.sequence) != nil { return ack(.busy, delivery.sequence) }
            screens[delivery.surfaceID, default: ""] += text
            ledger.recordApplied(delivery, now: Date())
            return ack(.applied, delivery.sequence)
        case .duplicate(let appliedThrough):
            return ack(.duplicate, appliedThrough)
        case .gap(let expected):
            return ack(.gap, delivery.sequence, expected: expected)
        case .surfaceMismatch:
            return ack(.surfaceMismatch, delivery.sequence)
        }
    }

    func restart() { ledger = MobileTerminalInputLedger() }
}

@MainActor
private final class Harness {
    let mac = FakeMac()
    let sender: MobileTerminalInputSender<String>
    var laneUp = true
    var reachable = true
    /// Frames written to the lane and not yet read by the Mac.
    var laneInFlight: [(String, MobileTerminalInputDelivery)] = []
    /// The Mac applies the request but the response is lost.
    var rpcLosesResponses = 0
    var rpcRefusals = 0
    var rpcSends: [MobileTerminalInputDelivery] = []
    var pauses: [Int] = []
    var settlements: [String: [MobileTerminalInputSender<String>.Settlement]] = [:]

    init(merge: Bool = false) {
        sender = MobileTerminalInputSender<String>(
            merge: merge ? { $0 += $1; return true } : { _, _ in false }
        )
        sender.transport = .init(
            sendOnLane: { [unowned self] _, text, delivery in
                guard laneUp else { return .unavailable }
                laneInFlight.append((text, delivery))
                return .awaitingAcknowledgement
            },
            sendOverRPC: { [unowned self] _, text, delivery in
                rpcSends.append(delivery)
                if rpcRefusals > 0 { rpcRefusals -= 1; return .refused }
                let acknowledgement = mac.deliver(text, delivery)
                if rpcLosesResponses > 0 { rpcLosesResponses -= 1; return .failed }
                return .acknowledged(acknowledgement)
            },
            isReachable: { [unowned self] _, _ in reachable },
            pause: { [unowned self] attempt in pauses.append(attempt) }
        )
    }

    func submit(_ text: String, to key: MobileTerminalInputSender<String>.Key) {
        let accepted = sender.submit(text, byteCount: text.utf8.count, to: key) { [unowned self] settlement in
            settlements[text, default: []].append(settlement)
        }
        #expect(accepted)
    }

    /// The Mac reads every lane frame and its acknowledgements come back.
    func flushLane() {
        let frames = laneInFlight
        laneInFlight = []
        for (text, delivery) in frames {
            sender.receive(mac.deliver(text, delivery))
        }
    }

    /// Waits for `condition` with a real deadline, so a loaded runner cannot
    /// fail correct code, and a hung pump fails within the deadline.
    func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
    }

    /// A bounded window for negative assertions (nothing may happen).
    func settleBriefly() async {
        for _ in 0..<200 { await Task.yield() }
    }
}

@MainActor
@Suite("Mobile terminal input sender")
struct MobileTerminalInputSenderTests {
    private let a = MobileTerminalInputSender<String>.Key(hostID: "mac", surfaceID: UUID())
    private let b = MobileTerminalInputSender<String>.Key(hostID: "mac", surfaceID: UUID())

    @Test func laneUnitsAreSettledWhenTheMacAcknowledgesThem() async {
        let harness = Harness()
        for text in ["l", "s", "\r"] { harness.submit(text, to: a) }
        await harness.settle(until: { harness.laneInFlight.count == 3 })
        #expect(harness.settlements.isEmpty)
        harness.flushLane()
        await harness.settle(until: { harness.settlements.count == 3 })
        #expect(harness.mac.screens[a.surfaceID] == "ls\r")
        #expect(harness.settlements == ["l": [.delivered], "s": [.delivered], "\r": [.delivered]])
        #expect(harness.sender.pendingUnitCount(for: a) == 0)
    }

    @Test func aLaneThatDropsAfterTheMacAppliedResendsWithoutDuplicating() async {
        let harness = Harness()
        for text in ["a", "b", "c"] { harness.submit(text, to: a) }
        await harness.settle(until: { harness.laneInFlight.count == 3 })
        // The Mac applies "a" and "b", then the lane dies before any ack.
        let frames = harness.laneInFlight
        harness.laneInFlight = []
        _ = harness.mac.deliver(frames[0].0, frames[0].1)
        _ = harness.mac.deliver(frames[1].0, frames[1].1)
        harness.laneUp = false
        harness.sender.resendUnacknowledged()
        await harness.settle(until: { harness.settlements.count == 3 })
        #expect(harness.mac.screens[a.surfaceID] == "abc")
        // Resending 1 is answered "applied through 2", so 2 is never resent.
        #expect(harness.rpcSends.map(\.sequence) == [1, 3])
        #expect(harness.settlements.values.allSatisfy { $0 == [.delivered] })
    }

    @Test func aLostResponseIsResentAndTheMacAppliesItOnce() async {
        let harness = Harness()
        harness.laneUp = false
        harness.rpcLosesResponses = 1
        harness.submit("rm -rf build\r", to: a)
        await harness.settle(until: { harness.settlements["rm -rf build\r"] != nil })
        #expect(harness.mac.screens[a.surfaceID] == "rm -rf build\r")
        #expect(harness.rpcSends.count == 2)
        #expect(harness.rpcSends[0] == harness.rpcSends[1])
        #expect(harness.pauses == [1])
        #expect(harness.settlements["rm -rf build\r"] == [.delivered])
    }

    @Test func repeatedAmbiguousResponsesAbandonTheStreamWithoutRepeatingTheWrite() async {
        let harness = Harness()
        harness.laneUp = false
        harness.rpcLosesResponses = MobileTerminalInputSender<String>.maximumRetryAttempts
        harness.submit("dangerous command\r", to: a)
        await harness.settle(until: { harness.settlements["dangerous command\r"] != nil })
        #expect(harness.settlements["dangerous command\r"] == [.abandoned])
        #expect(harness.mac.screens[a.surfaceID] == "dangerous command\r")
        #expect(harness.rpcSends.count == MobileTerminalInputSender<String>.maximumRetryAttempts)
        #expect(harness.sender.pendingKeys().isEmpty)
    }

    @Test func eachTerminalOnlyEverReceivesItsOwnInput() async {
        let harness = Harness()
        harness.submit("to-a ", to: a)
        harness.submit("to-b ", to: b)
        harness.submit("more-a", to: a)
        await harness.settle(until: { harness.laneInFlight.count == 3 })
        harness.laneUp = false
        harness.sender.resendUnacknowledged()
        await harness.settle(until: { harness.settlements.count == 3 })
        #expect(harness.mac.screens[a.surfaceID] == "to-a more-a")
        #expect(harness.mac.screens[b.surfaceID] == "to-b ")
        #expect(harness.rpcSends.allSatisfy { [a.surfaceID, b.surfaceID].contains($0.surfaceID) })
    }

    @Test func aRequestNeverOvertakesUnitsStillOnTheLane() async {
        let harness = Harness()
        harness.submit("first", to: a)
        await harness.settle(until: { harness.laneInFlight.count == 1 })
        // The lane cannot carry the next unit (a paste), so it waits for the
        // lane's acknowledgement instead of racing it over RPC.
        harness.laneUp = false
        harness.submit("paste", to: a)
        await harness.settleBriefly()
        #expect(harness.rpcSends.isEmpty)
        harness.flushLane()
        await harness.settle(until: { harness.settlements.count == 2 })
        #expect(harness.mac.screens[a.surfaceID] == "firstpaste")
    }

    @Test func aBusyTerminalGetsTheSameUnitAgainAfterAPause() async {
        let harness = Harness()
        harness.laneUp = false
        harness.mac.busySequences = [1]
        harness.submit("x", to: a)
        await harness.settle(until: { harness.settlements["x"] != nil })
        #expect(harness.mac.screens[a.surfaceID] == "x")
        #expect(harness.pauses == [1])
        #expect(harness.settlements["x"] == [.delivered])
    }

    @Test func aClosedTerminalReportsInputUndeliveredAndNeverRedirectsIt() async {
        let harness = Harness()
        harness.laneUp = false
        harness.mac.closedTerminals = [a.surfaceID]
        harness.submit("typed into a", to: a)
        await harness.settle(until: { harness.settlements["typed into a"] != nil })
        #expect(harness.settlements["typed into a"] == [.undeliverable])
        #expect(harness.mac.screens.isEmpty)
        #expect(harness.sender.pendingUnitCount(for: a) == 0)
    }

    @Test func aMacRestartMovesPendingInputToANewStream() async {
        let harness = Harness()
        harness.laneUp = false
        harness.submit("one", to: a)
        await harness.settle(until: { harness.settlements["one"] != nil })
        let firstStream = harness.sender.streamID(for: a)
        harness.mac.restart()
        harness.mac.screens = [:]
        harness.reachable = false
        harness.submit("two", to: a)
        harness.submit("three", to: a)
        // The restarted Mac forgot the stream: "two" (sequence 2) is a gap
        // below this outbox's view, so pending units move to a new stream.
        harness.reachable = true
        harness.sender.resume()
        await harness.settle(until: { harness.settlements["three"] != nil })
        #expect(harness.mac.screens[a.surfaceID] == "twothree")
        #expect(harness.sender.streamID(for: a) != firstStream)
        #expect(harness.settlements["two"] == [.delivered])
        #expect(harness.settlements["three"] == [.delivered])
    }

    @Test func repeatedRefusalsReportTheStreamUndeliveredAndStartFresh() async {
        let harness = Harness()
        harness.laneUp = false
        harness.rpcRefusals = MobileTerminalInputSender<String>.maximumRefusals
        harness.reachable = false
        harness.submit("bad", to: a)
        harness.submit("after", to: a)
        harness.reachable = true
        harness.sender.resume()
        await harness.settle(until: { harness.settlements["after"] != nil })
        #expect(harness.settlements["bad"] == [.undeliverable])
        #expect(harness.settlements["after"] == [.undeliverable])
        #expect(harness.mac.screens.isEmpty)
        harness.submit("next", to: a)
        await harness.settle(until: { harness.settlements["next"] != nil })
        #expect(harness.mac.screens[a.surfaceID] == "next")
        #expect(harness.rpcSends.last?.sequence == 1)
    }

    @Test func keysTypedWhileARequestIsInFlightMergeIntoOneUnit() async {
        let harness = Harness(merge: true)
        harness.laneUp = false
        harness.reachable = false
        for text in ["e", "c", "h", "o"] { harness.submit(text, to: a) }
        #expect(harness.sender.pendingUnitCount(for: a) == 1)
        harness.reachable = true
        harness.sender.resume()
        await harness.settle(until: { harness.settlements["o"] != nil })
        #expect(harness.mac.screens[a.surfaceID] == "echo")
        #expect(harness.rpcSends.count == 1)
        #expect(["e", "c", "h", "o"].allSatisfy { harness.settlements[$0] == [.delivered] })
    }

    @Test func abandoningAMacSettlesItsUnitsAndSendsNothingElse() async {
        let harness = Harness()
        harness.reachable = false
        harness.submit("pending", to: a)
        harness.sender.abandon { $0.hostID == "mac" }
        harness.reachable = true
        harness.sender.resume()
        await harness.settleBriefly()
        #expect(harness.settlements["pending"] == [.abandoned])
        #expect(harness.rpcSends.isEmpty)
        #expect(harness.sender.pendingKeys().isEmpty)
    }

    @Test func outOfOrderArrivalIsRepairedWithoutLosingOrDuplicatingUnits() async {
        let harness = Harness()
        for text in ["1", "2", "3"] { harness.submit(text, to: a) }
        await harness.settle(until: { harness.laneInFlight.count == 3 })
        // The Mac reads "3" first (another path overtook), then the rest.
        let frames = harness.laneInFlight
        harness.laneInFlight = []
        harness.sender.receive(harness.mac.deliver(frames[2].0, frames[2].1))
        await harness.settle(until: { harness.laneInFlight.count == 3 })
        harness.sender.receive(harness.mac.deliver(frames[0].0, frames[0].1))
        harness.sender.receive(harness.mac.deliver(frames[1].0, frames[1].1))
        harness.flushLane()
        await harness.settle(until: { harness.sender.pendingUnitCount(for: a) == 0 })
        #expect(harness.mac.screens[a.surfaceID] == "123")
    }
}
