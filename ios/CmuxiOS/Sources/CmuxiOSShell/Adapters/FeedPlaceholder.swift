import CmuxiOSFeatureKit
import Foundation

/// Feed tab placeholder over `FeedSource`: open requests first.
enum FeedPlaceholder {
    static func stream(_ source: any FeedSource, isMock: Bool) -> PlaceholderSnapshot.Factory {
        PlaceholderSnapshot.stream(isMock: isMock, { await source.updates() }, sections: sections)
    }

    @Sendable static func sections(_ items: [FeedItem]) -> [PlaceholderSection] {
        let open = items.filter { $0.resolution == nil && $0.kind != .done }
        let rest = items.filter { $0.resolution != nil || $0.kind == .done }
        return [
            PlaceholderSection(id: "open", title: ShellText.needsInput, rows: open.map(row)),
            PlaceholderSection(id: "earlier", title: ShellText.earlier, rows: rest.map(row)),
        ].filter { !$0.rows.isEmpty }
    }

    private static func row(_ item: FeedItem) -> PlaceholderRow {
        let isOpen = item.resolution == nil && item.kind != .done
        return PlaceholderRow(id: item.id, title: item.title, subtitle: item.source + "\n" + item.body,
                              symbolName: symbol(item.kind), status: isOpen ? .waiting : .idle,
                              badge: item.isRead ? nil : 1)
    }

    private static func symbol(_ kind: FeedItemKind) -> String {
        switch kind {
        case .permission: "lock.shield"
        case .question: "questionmark.bubble"
        case .planApproval: "list.bullet.clipboard"
        case .done: "checkmark.circle"
        }
    }
}
