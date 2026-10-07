import CmuxiOSSearchCore
import Foundation

/// The search screen's localized strings.
struct SearchScreenText {
    static var title: String {
        String(localized: "search.title", defaultValue: "Search", bundle: .module)
    }
    static var placeholder: String {
        String(localized: "search.placeholder", defaultValue: "Workspaces, feed, hosts, actions", bundle: .module)
    }
    static var recents: String {
        String(localized: "search.section.recents", defaultValue: "Recent Searches", bundle: .module)
    }
    static var clearRecents: String {
        String(localized: "search.recents.clear", defaultValue: "Clear Recent Searches", bundle: .module)
    }
    static var delete: String {
        String(localized: "search.recents.delete", defaultValue: "Delete", bundle: .module)
    }
    static var done: String {
        String(localized: "search.done", defaultValue: "Done", bundle: .module)
    }
    static var oneResult: String {
        String(localized: "search.results.one", defaultValue: "1 result", bundle: .module)
    }
    static func results(_ count: Int) -> String {
        String(localized: "search.results.count", defaultValue: "\(count) results", bundle: .module)
    }
    static func more(_ count: Int) -> String {
        String(localized: "search.section.more", defaultValue: "\(count) more", bundle: .module)
    }
    static var previous: String {
        String(localized: "search.key.previous", defaultValue: "Previous Result", bundle: .module)
    }
    static var next: String {
        String(localized: "search.key.next", defaultValue: "Next Result", bundle: .module)
    }
    static var close: String {
        String(localized: "search.key.close", defaultValue: "Close Search", bundle: .module)
    }

    static func title(_ category: SearchCategory) -> String {
        switch category {
        case .actions: String(localized: "search.section.actions", defaultValue: "Actions", bundle: .module)
        case .workspaces: String(localized: "search.section.workspaces", defaultValue: "Workspaces", bundle: .module)
        case .tabs: String(localized: "search.section.tabs", defaultValue: "Tabs", bundle: .module)
        case .feed: String(localized: "search.section.feed", defaultValue: "Feed", bundle: .module)
        case .hosts: String(localized: "search.section.hosts", defaultValue: "Hosts", bundle: .module)
        case .settings: String(localized: "search.section.settings", defaultValue: "Settings", bundle: .module)
        }
    }
}
