/// One row of the search list.
enum SearchRowID: Hashable, Sendable {
    case recent(String)
    case clearRecents
    case result(String)
}
