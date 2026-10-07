import CmuxiOSFeatureKit
import CmuxiOSFeedModel
import Foundation
import Testing

@Suite struct FeedSectionBuilderTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func noGroupingPutsOpenRequestsFirstByPriorityThenNewest() {
        var items = MockFixtures.feedItems(now: now)
        items[2].priority = .urgent // feed3, the plan, is older than feed1 but urgent
        let sections = FeedSectionBuilder(filter: .all, grouping: .none).sections(items)
        #expect(sections.map(\.kind) == [.needsInput, .earlier])
        #expect(sections[0].itemIDs == ["feed3", "feed1", "feed2", "feed5"])
        #expect(sections[1].itemIDs == ["feed4"])
    }

    @Test func filtersHideArchivedAndClosedItemsAsDefined() {
        var items = MockFixtures.feedItems(now: now)
        items[4].archivedAt = now // feed4
        #expect(FeedSectionBuilder(filter: .all, grouping: .none).sections(items).flatMap(\.itemIDs).contains("feed4") == false)
        items[4].archivedAt = nil
        let needsInput = FeedSectionBuilder(filter: .needsInput, grouping: .none).sections(items).flatMap(\.itemIDs)
        #expect(!needsInput.contains("feed4"))
        let unread = FeedSectionBuilder(filter: .unread, grouping: .none).sections(items).flatMap(\.itemIDs)
        #expect(!unread.contains("feed4")) // read notice
        #expect(unread.contains("feed1"))
    }

    @Test func workspaceGroupingUsesResolverThenPosterLabel() {
        let items = MockFixtures.feedItems(now: now)
        let sections = FeedSectionBuilder(filter: .all, grouping: .workspace, workspaceName: { id in
            id == "ws_studio1" ? "cmux (resolved)" : nil
        }).sections(items)
        #expect(sections.map(\.id) == ["ws:ws_studio1", "ws:ws_studio2", "ws:ws_mini1"])
        #expect(sections[0].kind == .workspace(id: "ws_studio1", label: "cmux (resolved)"))
        #expect(sections[1].kind == .workspace(id: "ws_studio2", label: "backend"))
        #expect(sections[2].itemIDs == ["feed4"])
    }

    @Test func agentGroupingRanksGroupsWithOpenRequestsFirst() {
        var items = MockFixtures.feedItems(now: now)
        for index in items.indices where items[index].agent == "claude" && items[index].isRequest {
            items[index].state = .answered
        }
        let sections = FeedSectionBuilder(filter: .all, grouping: .agent).sections(items)
        #expect(sections.map(\.kind) == [.agent("codex"), .agent("claude")])
    }

    @Test func countsAreOpenRequestsPlusUnreadNotices() {
        var items = MockFixtures.feedItems(now: now)
        items[4].readAt = nil
        #expect(FeedCounts(items).openRequests == 4)
        #expect(FeedCounts(items).badge == 5)
    }

    @Test func choiceSelectionTogglesBySingleAndMulti() {
        let single = FeedChoiceSelection(selected: ["a"], other: "x").toggling("b", multi: false)
        #expect(single == FeedChoiceSelection(selected: ["b"], other: nil))
        #expect(single.toggling("b", multi: false).isEmpty)
        let multi = FeedChoiceSelection().toggling("a", multi: true).toggling("b", multi: true).toggling("a", multi: true)
        #expect(multi.selected == ["b"])
    }
}
