import CmuxiOSBrowserCore
import CmuxiOSFeatureKit

/// Lane C2 plug point (c2-browser-stream.md section 9): the real browser
/// seam needs the phone's `MobileLinkClient` per Mac (D1 with B2/B4/B6,
/// the same provider files use) and the host's browser tab records
/// (`WorkspaceBrowserTabDirectory` over C5's workspace source). Until a
/// client provider exists the slot stays nil and the seam serves its mock.
enum BrowserComposition {
    /// The first viewport `channel.open` carries; the screen sends its real
    /// size after layout.
    static let initialViewport = BrowserViewport(width: 393, height: 852, scale: 3, refreshHz: 120)

    static func realSource(clients: (any MobileLinkClientProvider)?,
                           directory: (any BrowserTabDirectory)?) -> (@Sendable () -> any BrowserStreamSource)? {
        guard let clients, let directory else { return nil }
        return { LinkBrowserStreamSource(clients: clients, directory: directory, viewport: { initialViewport }) }
    }
}
