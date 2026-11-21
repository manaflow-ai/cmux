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

    // MARK: - Order-preserving user moves (ruling R24)

    /// A new workspace shows above an older one but ranks below it. Moving it to the top, where
    /// it already is, affirms its visible place instead of recording nothing.
    @Test func orderPreservingMoveAffirmsThePosition() {
        var rank = SessionPriorityRank(recordedOrder: [a, b])
        rank.recordUserMove(movedIds: [b], before: [b, a], after: [b, a])
        #expect(rank.recordedOrder == [b, a])
    }

    /// The pinned workspace holds index 0, so `--index 0` leaves the order as it was.
    @Test func orderPreservingMoveBelowAPinnedWorkspaceAffirmsThePosition() {
        var rank = SessionPriorityRank(recordedOrder: [d, a, b])
        rank.recordUserMove(movedIds: [b], before: [d, b, a], after: [d, b, a])
        #expect(rank.recordedOrder == [d, b, a])
    }

    @Test func orderPreservingMoveOfACorrectlyRankedIdChangesNothing() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c])
        rank.recordUserMove(movedIds: [a], before: [a, b, c], after: [a, b, c])
        #expect(rank.recordedOrder == [a, b, c])
        rank.recordUserMove(movedIds: [b], before: [a, b, c], after: [a, b, c])
        #expect(rank.recordedOrder == [a, b, c])
        rank.recordUserMove(movedIds: [c], before: [a, b, c], after: [a, b, c])
        #expect(rank.recordedOrder == [a, b, c])
    }

    /// Several affirmed ids keep their visible order, each run placed with the moving-up rule.
    @Test func orderPreservingBlockMoveAffirmsTheBlock() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.recordUserMove(movedIds: [c, d], before: [c, d, a, b], after: [c, d, a, b])
        #expect(rank.recordedOrder == [c, d, a, b])
    }

    /// Move Down on the last workspace is clamped and leaves the order. The user asked to go
    /// down, so the moving-down rule places it and it is not promoted: rank `a b c` shown as
    /// `b a c`, Move Down on c, keeps `a b c`.
    @Test func orderPreservingMoveDownKeepsTheWorkspaceWhereItRanks() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c])
        rank.recordUserMove(movedIds: [c], before: [b, a, c], after: [b, a, c], movingUp: false)
        #expect(rank.recordedOrder == [a, b, c])
    }

    /// The direction matters only when the order did not change: a real move keeps its own.
    @Test func directionIsIgnoredForAMoveThatChangedTheOrder() {
        var rank = SessionPriorityRank(recordedOrder: [a, b, c, d])
        rank.recordUserMove(movedIds: [c], before: [d, a, b, c], after: [c, d, a, b], movingUp: false)
        #expect(rank.recordedOrder == [c, a, b, d])
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
