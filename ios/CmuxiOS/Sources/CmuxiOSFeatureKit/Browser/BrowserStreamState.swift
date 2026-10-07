/// The attachment state of a browser stream.
public enum BrowserStreamState: Hashable, Sendable {
    case connecting
    /// Video arrives at `width` x `height` pixels.
    case streaming(width: Int, height: Int)
    case paused
    case ended(reason: String?)
}
