#if os(iOS)
import CNCore
import CNTransport
import CoreGraphics
import Foundation
import ImageIO
import Observation
import UIKit

/// The last decoded frame of a tab.
struct PageFrame {
    var image: CGImage
    /// CSS size the frame was rendered at.
    var cssSize: CGSize
    /// Average color of the top rows, used to fill the status-bar strip.
    var topColor: UIColor
    var seq: UInt32

    var uiImage: UIImage { UIImage(cgImage: image) }
}

// CGImage and UIColor are immutable; frames cross from the decoder task.
extension PageFrame: @unchecked Sendable {}

/// Viewport the phone asks the host to render.
struct BrowserViewport: Hashable, Sendable {
    var width: Int
    var height: Int
    var scale: Double
    var mobile: Bool
}

/// Browser state and transport for `BrowserRoot`: the tab list, the one
/// attached frame stream, per-tab last frames and thumbnails, viewport, and
/// ordered input.
@MainActor
@Observable
final class BrowserModel {
    @ObservationIgnored let connection: HostConnection

    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTabId: String?
    private(set) var frames: [String: PageFrame] = [:]
    private(set) var thumbnails: [String: UIImage] = [:]
    /// Tabs opened from the phone that show the local start page until the
    /// user navigates.
    private(set) var startPageTabs: Set<String> = []
    private(set) var desktopTabs: Set<String> = []
    private(set) var loaded = false
    private(set) var errorText: String?

    // Viewport inputs (points).
    @ObservationIgnored private var viewSize: CGSize = .zero
    @ObservationIgnored private var topInset: CGFloat = 0
    @ObservationIgnored private var bottomObscured: CGFloat = 0
    @ObservationIgnored private var screenScale: CGFloat = 3

    // Stream.
    @ObservationIgnored private var streamId: UInt32?
    @ObservationIgnored private var streamTabId: String?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamClient: HostClient?
    @ObservationIgnored private var attachToken = 0
    @ObservationIgnored private var sentViewport: BrowserViewport?
    @ObservationIgnored private var viewportInFlight = false
    @ObservationIgnored private var thumbnailRequests: Set<String> = []
    @ObservationIgnored private var pendingAttach: String?

    @ObservationIgnored lazy var input = BrowserInputPump { [weak self] in self?.connection.client }

    init(connection: HostConnection) {
        self.connection = connection
    }

    var activeTab: BrowserTab? { tabs.first { $0.id == activeTabId } }
    var activeFrame: PageFrame? { activeTabId.flatMap { frames[$0] } }
    var activeIndex: Int? { tabs.firstIndex { $0.id == activeTabId } }

    func showsStartPage(_ tabId: String?) -> Bool {
        guard let tabId else { return true }
        if startPageTabs.contains(tabId) { return true }
        guard let url = tabs.first(where: { $0.id == tabId })?.url else { return false }
        return url.isEmpty || url == "about:blank" || url.hasPrefix("chrome://newtab")
    }

    func isDesktop(_ tabId: String?) -> Bool { tabId.map { desktopTabs.contains($0) } ?? false }

    // MARK: Loading

    /// Loads the tab list and attaches the active tab. Runs on every
    /// connection generation.
    func reload() async {
        guard let client = connection.client else { return }
        do {
            let list = try await client.listTabs()
            errorText = nil
            tabs = list
            loaded = true
            let keep = activeTabId.flatMap { id in list.contains { $0.id == id } ? id : nil }
            let next = keep ?? list.first(where: \.active)?.id ?? list.first?.id
            // A reconnect invalidates the old stream id; attach again.
            streamId = nil
            streamTabId = nil
            sentViewport = nil
            input.reset()
            if let next {
                activeTabId = next
                await attach(next)
            } else {
                activeTabId = nil
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func handle(_ push: HostPush) {
        switch push {
        case .browserTab(let tab):
            if let i = tabs.firstIndex(where: { $0.id == tab.id }) {
                if tabs[i].url != tab.url, !tab.url.isEmpty, tab.url != "about:blank" { startPageTabs.remove(tab.id) }
                tabs[i] = tab
            } else {
                tabs.append(tab)
            }
        case .browserClosed(let tabId):
            removeLocally(tabId)
        default:
            break
        }
    }

    // MARK: Viewport

    /// Called by the page surface whenever its size, safe area or the
    /// software keyboard over it changes.
    func setGeometry(size: CGSize, topInset: CGFloat, bottomObscured: CGFloat, scale: CGFloat) {
        viewSize = size
        self.topInset = topInset
        self.bottomObscured = bottomObscured
        screenScale = scale
        if let tabId = pendingAttach, viewport(for: tabId) != nil {
            pendingAttach = nil
            Task { await attach(tabId) }
            return
        }
        pushViewport()
    }

    func viewport(for tabId: String?) -> BrowserViewport? {
        guard viewSize.width > 0 else { return nil }
        let w = viewSize.width
        let h = max(100, viewSize.height - topInset - bottomObscured)
        if isDesktop(tabId) {
            let cssW = 980.0
            let ratio = cssW / Double(w)
            return BrowserViewport(width: Int(cssW), height: Int((Double(h) * ratio).rounded()),
                                   scale: max(1, Double(screenScale) / ratio), mobile: false)
        }
        return BrowserViewport(width: Int(w.rounded()), height: Int(h.rounded()), scale: Double(screenScale), mobile: true)
    }

    private func pushViewport() {
        guard let tabId = streamTabId, streamId != nil, let vp = viewport(for: tabId), vp != sentViewport else { return }
        guard !viewportInFlight else { return }
        viewportInFlight = true
        sentViewport = vp
        Task {
            if let client = connection.client {
                try? await client.setViewport(BrowserViewportParams(tabId: tabId, width: vp.width, height: vp.height, scale: vp.scale))
            }
            viewportInFlight = false
            // A newer size arrived while this one was in flight.
            if let latest = viewport(for: streamTabId), latest != sentViewport { pushViewport() }
        }
    }

    // MARK: Stream

    func attach(_ tabId: String) async {
        attachToken += 1
        let token = attachToken
        await detachStream()
        guard let client = connection.client, let vp = viewport(for: tabId) else {
            // No size yet: attach once the surface reports its geometry.
            pendingAttach = tabId
            return
        }
        pendingAttach = nil
        input.reset()
        do {
            let result = try await client.attachTab(BrowserAttachParams(tabId: tabId, width: vp.width, height: vp.height,
                                                                        scale: vp.scale, mobile: vp.mobile))
            guard token == attachToken else {
                try? await client.detachTab(streamId: result.streamId)
                client.closeStream(id: result.streamId)
                return
            }
            merge(result.tab)
            streamId = result.streamId
            streamTabId = tabId
            streamClient = client
            sentViewport = vp
            let sid = result.streamId
            let frames = client.openBrowserStream(id: sid)
            streamTask = Task { [weak self] in
                for await frame in frames {
                    let decoded = await Self.decode(frame)
                    guard let self, self.streamId == sid else { return }
                    if let decoded { self.frames[tabId] = decoded }
                    // Ack even an undecodable frame: the host stops sending
                    // after two unacked frames.
                    try? await client.ackFrame(streamId: sid, seq: frame.seq)
                }
            }
            // The size may have changed while attaching.
            pushViewport()
        } catch {
            if token == attachToken { errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    private func detachStream() async {
        streamTask?.cancel()
        streamTask = nil
        if let sid = streamId, let client = streamClient {
            try? await client.detachTab(streamId: sid)
            client.closeStream(id: sid)
        }
        streamId = nil
        streamTabId = nil
        streamClient = nil
        sentViewport = nil
    }

    func detachAll() {
        attachToken += 1
        Task { await detachStream() }
    }

    nonisolated static func decode(_ frame: BrowserFrame) async -> PageFrame? {
        let data = frame.image
        return await Task.detached(priority: .userInitiated) { () -> PageFrame? in
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, options) else { return nil }
            return PageFrame(image: image, cssSize: CGSize(width: Double(frame.cssWidth), height: Double(frame.cssHeight)),
                             topColor: topColor(of: image), seq: frame.seq)
        }.value
    }

    /// Average color of the first few pixel rows.
    nonisolated static func topColor(of image: CGImage) -> UIColor {
        let rows = max(1, image.height / 300)
        guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: rows)) else { return .white }
        var px = [UInt8](repeating: 0, count: 16 * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 16, height: 1, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(strip, in: CGRect(x: 0, y: 0, width: 16, height: 1))
            return true
        }
        guard ok else { return .white }
        var r = 0, g = 0, b = 0
        for i in 0..<16 { r += Int(px[i * 4]); g += Int(px[i * 4 + 1]); b += Int(px[i * 4 + 2]) }
        return UIColor(red: CGFloat(r) / 16 / 255, green: CGFloat(g) / 16 / 255, blue: CGFloat(b) / 16 / 255, alpha: 1)
    }

    // MARK: Tabs

    func select(_ tabId: String) {
        guard tabId != activeTabId || streamTabId != tabId else { return }
        activeTabId = tabId
        // Show the overview thumbnail until the first live frame arrives.
        if frames[tabId] == nil, let cg = thumbnails[tabId]?.cgImage, let vp = viewport(for: tabId), cg.width > 0 {
            frames[tabId] = PageFrame(image: cg, cssSize: CGSize(width: Double(vp.width), height: Double(vp.width) * Double(cg.height) / Double(cg.width)),
                                      topColor: Self.topColor(of: cg), seq: 0)
        }
        Task { await attach(tabId) }
    }

    /// Opens a new tab showing the start page; returns its id.
    @discardableResult
    func newTab(url: String? = nil) async -> String? {
        guard let client = connection.client else { return nil }
        do {
            let tab = try await client.createTab(url: url ?? "about:blank")
            merge(tab)
            if url == nil { startPageTabs.insert(tab.id) }
            activeTabId = tab.id
            await attach(tab.id)
            return tab.id
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }

    func close(_ tabId: String) {
        removeLocally(tabId)
        Task { try? await connection.client?.closeTab(tabId) }
    }

    private func removeLocally(_ tabId: String) {
        guard let i = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs.remove(at: i)
        frames[tabId] = nil
        thumbnails[tabId] = nil
        startPageTabs.remove(tabId)
        desktopTabs.remove(tabId)
        if activeTabId == tabId {
            activeTabId = nil
            if !tabs.isEmpty {
                select(tabs[min(i, tabs.count - 1)].id)
            } else {
                detachAll()
            }
        }
    }

    private func merge(_ tab: BrowserTab) {
        if let i = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[i] = tab } else { tabs.append(tab) }
    }

    /// Thumbnail image for a card: the live frame for the active tab, else a
    /// `browser.screenshot` (fetched once per overview).
    func cardImage(_ tabId: String) -> UIImage? {
        if let f = frames[tabId], tabId == activeTabId { return f.uiImage }
        return thumbnails[tabId] ?? frames[tabId]?.uiImage
    }

    func refreshThumbnails() {
        thumbnailRequests.removeAll()
        for tab in tabs where tab.id != activeTabId { requestThumbnail(tab.id) }
    }

    func requestThumbnail(_ tabId: String) {
        guard !thumbnailRequests.contains(tabId), !showsStartPage(tabId), let client = connection.client else { return }
        thumbnailRequests.insert(tabId)
        Task {
            guard let shot = try? await client.screenshot(tabId), let data = shot.data else { return }
            let image = await Task.detached { UIImage(data: data)?.preparingForDisplay() }.value
            if let image { thumbnails[tabId] = image }
        }
    }

    // MARK: Navigation

    func navigate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tabId = activeTabId else { return }
        startPageTabs.remove(tabId)
        Task { try? await connection.client?.navigate(tabId, to: Self.normalize(trimmed)) }
    }

    static func normalize(_ text: String) -> String {
        if text.contains("://") { return text }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost { return "https://" + text }
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return "https://www.google.com/search?q=" + q
    }

    func goBack() { if let id = activeTabId { Task { try? await connection.client?.goBack(id) } } }
    func goForward() { if let id = activeTabId { Task { try? await connection.client?.goForward(id) } } }

    func reloadOrStop() {
        guard let tab = activeTab else { return }
        Task {
            if tab.loading { try? await connection.client?.stopLoading(tab.id) } else { try? await connection.client?.reload(tab.id) }
        }
    }

    func openOnMac() { if let id = activeTabId { Task { try? await connection.client?.activateTab(id) } } }

    func toggleDesktop() {
        guard let id = activeTabId else { return }
        if desktopTabs.contains(id) { desktopTabs.remove(id) } else { desktopTabs.insert(id) }
        // The host applies `mobile` at attach time; attach again.
        Task { await attach(id) }
    }

    // MARK: Input (CSS px)

    func sendTouch(_ type: TouchEventType, points: [TouchPoint]) {
        guard let id = streamTabId else { return }
        input.send(.touch(BrowserTouchParams(tabId: id, type: type, points: points)))
    }

    func sendKey(_ key: DOMKey) {
        guard let id = streamTabId else { return }
        input.send(.key(BrowserKeyParams(tabId: id, type: .down, key: key.key, code: key.code, text: key.text, modifiers: key.modifiers)))
        input.send(.key(BrowserKeyParams(tabId: id, type: .up, key: key.key, code: key.code, modifiers: key.modifiers)))
    }

    func sendText(_ text: String) {
        guard let id = streamTabId, !text.isEmpty else { return }
        input.send(.text(BrowserTextParams(tabId: id, text: text)))
    }
}

extension BrowserTab {
    /// Registrable host shown in the address capsule: no scheme, path or `www.`.
    var displayHost: String {
        guard let host = URL(string: url)?.host(percentEncoded: false), !host.isEmpty else {
            return url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Search query when the tab shows a search results page.
    var searchQuery: String? {
        guard let comps = URLComponents(string: url), let host = comps.host,
              host.contains("google.") || host.contains("duckduckgo.") || host.contains("bing.") else { return nil }
        return comps.queryItems?.first { $0.name == "q" }?.value
    }
}
#endif
