import CnxTransport
import Foundation

/// Streamed browser tabs while the app is linked to a Mac: one model per tab
/// key, kept while the tab exists so the page and its history stay on the
/// Mac across tab switches and link drops. The live coordinator sets
/// ``opener`` (the current link) and calls ``linkChanged()``; with no opener
/// browser tabs stay local web views.
@MainActor
public final class StreamedBrowserDirectory {
    public static let shared = StreamedBrowserDirectory()

    /// The current link when it can stream browser tabs, else nil.
    public var opener: (@Sendable () async -> (any BrowserStreamOpening)?)? {
        didSet { if opener == nil { reset() } }
    }

    private var models: [String: StreamedBrowserModel] = [:]
    private var lastWarm: ContinuousClock.Instant?
    private var appActive = true

    public init() {}

    public var isLive: Bool { opener != nil }

    /// The streamed model of a tab (`tab`: its key on the Mac, `url`: its
    /// first page), or nil when not linked.
    public func model(tab: String, url: URL?) -> StreamedBrowserModel? {
        guard let opener else { return nil }
        if let model = models[tab] {
            warmMedia()
            return model
        }
        let model = StreamedBrowserModel(tab: tab, url: url) { sink in
            guard let link = await opener() else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            return try await link.openBrowser(tab: tab, url: url?.absoluteString, sink: sink)
        }
        models[tab] = model
        if !appActive { model.setAppActive(false) }
        warmMedia()
        return model
    }

    /// A workspace with browser tabs is shown: the WebRTC media session
    /// beside a WireGuard link opens before the first tab needs it.
    private func warmMedia() {
        // A warm-up lasts a minute on the link; at most one ask per 20 s.
        let now = ContinuousClock.now
        if let lastWarm, now - lastWarm < .seconds(20) { return }
        lastWarm = now
        guard let opener else { return }
        // task-owner: fire and forget; the link ignores it without a media session
        Task { await opener()?.warmMedia() }
    }

    /// The tab closed on the phone.
    public func drop(tab: String) {
        models.removeValue(forKey: tab)?.close()
    }

    /// A new link: dropped streams come back.
    public func linkChanged() {
        for model in models.values { model.reconnect() }
        lastWarm = nil
        if !models.isEmpty { warmMedia() }
    }

    /// The app went to the background (or came back): hidden pages let the
    /// WebRTC media session go.
    public func setAppActive(_ active: Bool) {
        appActive = active
        for model in models.values { model.setAppActive(active) }
    }

    public func reset() {
        for model in models.values { model.close() }
        models = [:]
    }
}
