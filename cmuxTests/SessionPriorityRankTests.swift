import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// The per-window session priority rank: it records the moves a user makes
/// and ignores the order cmux's automatic bumps leave behind.
struct SessionPriorityRankTests {
    private static func id(_ value: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }

    private let a = Self.id(1)
    private let b = Self.id(2)
    private let c = Self.id(3)
    private let d = Self.id(4)
    private let g1 = Self.id(5)
    private let g2 = Self.id(6)

    // MARK: - Membership

    @Test func effectiveOrderKeepsRecordedThenAppendsNew() {
        let rank = SessionPriorityRank(recordedOrder: [a, b, c])
        #expect(rank.effectiveOrder(visibleOrder: [c, d, a, b]) == [a, b, c, d])
    }

    @Test func closedWorkspacesDropOut() {
        let rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        #expect(rank.effectiveOrder(visibleOrder: [d, c, a]) == [a, c, d])
    }

    @Test func appendUnseenNeverDrops() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.appendUnseen(visibleOrder: [a, c, d])
        #expect(rank.recordedOrder == [a, b, c, d])
        rank.appendUnseen(visibleOrder: [b, a, c, d])
        #expect(rank.recordedOrder == [a, b, c, d])
        rank.appendUnseen(visibleOrder: [g1, a, b, c, d])
        #expect(rank.recordedOrder == [a, b, c, d, g1])
    }

    @Test func syncDropsMissingAndAppendsUnseen() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c])
        rank.sync(visibleOrder: [d, c, a])
        #expect(rank.recordedOrder == [a, c, d])
    }

    // MARK: - User moves

    @Test func userMoveIgnoresEarlierAutomaticBumps() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.recordUserMove(movedIds: [b], before: [d, a, b, c], after: [d, b, a, c])
        #expect(rank.recordedOrder == [b, a, c, d])
    }

    @Test func moveDownAnchorsBelowPredecessor() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.recordUserMove(movedIds: [a], before: [d, a, b, c], after: [d, b, a, c])
        #expect(rank.recordedOrder == [b, a, c, d])
    }

    @Test func moveToBottomGoesLast() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.recordUserMove(movedIds: [a], before: [d, a, b, c], after: [d, b, c, a])
        #expect(rank.recordedOrder == [b, c, d, a])
    }

    @Test func moveToTopGoesFirst() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.recordUserMove(movedIds: [c], before: [d, a, b, c], after: [c, d, a, b])
        #expect(rank.recordedOrder == [c, a, b, d])
    }

    @Test func blockMoveKeepsBlockOrder() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.recordUserMove(movedIds: [b, c], before: [a, b, c, d], after: [b, c, a, d])
        #expect(rank.recordedOrder == [b, c, a, d])
    }

    @Test func groupMembersMovedAlongAreDetected() {
        var rank = SessionPriorityRank(recordedOrder: [a, g1, g2, b])
        rank.recordUserMove(movedIds: [g1], before: [a, g1, g2, b], after: [g1, g2, a, b])
        #expect(rank.recordedOrder == [g1, g2, a, b])
    }

    // MARK: - Explicit order (batch reorder)

    @Test func recordUserOrderPermutesWithinHeldSlots() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.recordUserOrder([d, b], visibleOrder: [a, b, c, d])
        #expect(rank.recordedOrder == [a, d, c, b])
    }

    @Test func recordUserOrderFullListIsTheOrder() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.recordUserOrder([c, a, d, b], visibleOrder: [a, b, c, d])
        #expect(rank.recordedOrder == [c, a, d, b])
    }
}
