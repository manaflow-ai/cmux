import Foundation

/// The attachment state of a browser stream.
public enum BrowserStreamState: Hashable, Sendable {
    case connecting
    /// `videoTrackID` names the `CmuxLink` media track to render.
    case streaming(videoTrackID: String, width: Int, height: Int)
    case paused
    case ended(reason: String?)
}
