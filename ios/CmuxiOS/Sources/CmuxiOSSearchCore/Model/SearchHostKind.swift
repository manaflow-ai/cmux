/// How an opened host result is shown.
public enum SearchHostKind: Hashable, Sendable {
    case pairedMac
    case ssh
    case direct
}
