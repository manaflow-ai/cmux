/// Why a loopback proxy could not listen.
public enum LoopbackProxyError: Error, Hashable, Sendable {
    case cannotListen
    case stopped
}
