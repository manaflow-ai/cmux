/// Why the proxy could not read a request head.
public enum ProxyHeadError: Error, Hashable, Sendable {
    case notHTTP
    case tooLarge
}
