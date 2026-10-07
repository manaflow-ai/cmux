import CmuxiOSSearchCore

/// One section of the search list.
enum SearchSectionID: Hashable, Sendable {
    case recents
    case category(SearchCategory)
}
