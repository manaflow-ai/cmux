public import CmuxiOSFeatureKit
import Foundation

/// Builds the list sections from the visible items (pure).
///
/// Inside a section open requests come first (higher priority, then newer),
/// then everything else newest first. Grouped sections are ordered by
/// whether they hold an open request, then by their newest item.
public struct FeedSectionBuilder: Sendable {
    public var filter: FeedFilter
    public var grouping: FeedGrouping
    /// Workspace display names from the workspace seam, when available.
    public var workspaceName: @Sendable (WorkspaceSummary.ID) -> String?

    public init(filter: FeedFilter, grouping: FeedGrouping,
                workspaceName: @escaping @Sendable (WorkspaceSummary.ID) -> String? = { _ in nil }) {
        self.filter = filter
        self.grouping = grouping
        self.workspaceName = workspaceName
    }

    public func sections(_ items: [FeedItem]) -> [FeedSection] {
        let shown = items.filter(filter.includes).sorted(by: Self.displayOrder)
        switch grouping {
        case .none:
            let open = shown.filter(\.isOpenRequest)
            let rest = shown.filter { !$0.isOpenRequest }
            return [FeedSection(kind: .needsInput, itemIDs: open.map(\.id)),
                    FeedSection(kind: .earlier, itemIDs: rest.map(\.id))].filter { !$0.itemIDs.isEmpty }
        case .workspace:
            return grouped(shown, key: { $0.workspaceID }) { id, members in
                .workspace(id: id, label: id.flatMap(workspaceName) ?? members.first.map(Self.workspaceLabel))
            }
        case .agent:
            return grouped(shown, key: { $0.agent }) { agent, _ in .agent(agent) }
        }
    }

    private func grouped(
        _ shown: [FeedItem], key: (FeedItem) -> String?, kind: (String?, [FeedItem]) -> FeedSectionKind
    ) -> [FeedSection] {
        var order: [String?] = []
        var members: [String?: [FeedItem]] = [:]
        for item in shown {
            let k = key(item)
            if members[k] == nil { order.append(k) }
            members[k, default: []].append(item)
        }
        let ranked = order.sorted { a, b in
            let lhs = members[a] ?? [], rhs = members[b] ?? []
            let lhsOpen = lhs.contains(where: \.isOpenRequest), rhsOpen = rhs.contains(where: \.isOpenRequest)
            if lhsOpen != rhsOpen { return lhsOpen }
            return (lhs.first?.createdAt ?? .distantPast) > (rhs.first?.createdAt ?? .distantPast)
        }
        return ranked.map { k in
            let group = members[k] ?? []
            return FeedSection(kind: kind(k, group), itemIDs: group.map(\.id))
        }
    }

    /// The workspace part of a poster label ("Agent · workspace"), else the label.
    static func workspaceLabel(_ item: FeedItem) -> String {
        guard let range = item.source.range(of: " · ", options: .backwards) else { return item.source }
        return String(item.source[range.upperBound...])
    }

    static func displayOrder(_ a: FeedItem, _ b: FeedItem) -> Bool {
        if a.isOpenRequest != b.isOpenRequest { return a.isOpenRequest }
        if a.isOpenRequest, a.priority != b.priority { return a.priority > b.priority }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id < b.id
    }
}
