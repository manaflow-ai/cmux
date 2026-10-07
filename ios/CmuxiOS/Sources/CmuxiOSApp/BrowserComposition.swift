import CmuxBrowserStream
import CmuxiOSBrowserCore
import CmuxiOSFeatureKit

/// Lane C2 plug point (c2-browser-stream.md section 9): the real browser
/// seam needs the admitted `cmux.mobile/1` session per host (D1/B6 own
/// dialing and the device proof) and the host's browser tab records (C5's
/// workspace mirror). Until both exist the slot stays nil and the seam
/// serves its mock.
enum BrowserComposition {
    /// The first viewport `channel.open` carries; the screen sends its real
    /// size after layout.
    static let initialViewport = BrowserViewport(width: 393, height: 852, scale: 3, refreshHz: 120)

    static func realSource(links: (any MobileSessionLinkProvider)?,
                           directory: (any BrowserTabDirectory)?) -> (@Sendable () -> any BrowserStreamSource)? {
        guard let links, let directory else { return nil }
        return { LinkBrowserStreamSource(links: links, directory: directory, viewport: { initialViewport }) }
    }
}
