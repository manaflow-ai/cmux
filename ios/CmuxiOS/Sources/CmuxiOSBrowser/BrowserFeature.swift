public import CmuxiOSFeatureKit
public import UIKit

/// Lane C2's entry: builds browser screens over the account's
/// `BrowserStreamSource`. The composition root puts `makeScreen` into
/// `SurfaceScreenFactories.browser`.
@MainActor
public struct BrowserFeature {
    public let source: any BrowserStreamSource
    public let isMock: Bool

    public init(source: any BrowserStreamSource, isMock: Bool) {
        self.source = source
        self.isMock = isMock
    }

    public func makeScreen(tab: BrowserTabInfo, host: HostID) -> UIViewController {
        BrowserStreamViewController(source: source, tab: tab, host: host, isMock: isMock)
    }

    public var surfaceFactories: SurfaceScreenFactories {
        let feature = self
        return SurfaceScreenFactories(browser: { tab, host in feature.makeScreen(tab: tab, host: host) })
    }
}
