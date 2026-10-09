import CNCore
import CNTransport
import Foundation

struct MockTab {
    var tab: BrowserTab
    var page: MockPage
    var scrollY = 0.0
    var back: [String] = []
    var forward: [String] = []
    var typed = ""
    var highlightedSection: Int?
    var loadTask: Task<Void, Never>?
    var gestureStart: (x: Double, y: Double)?
    var gestureLastY = 0.0
    var gestureMoved = false
    var viewportHeight = 760.0
}

struct MockBrowserStream {
    var tabId: String
    var width: Int
    var height: Int
    var scale: Double
    var sentSeq: UInt32 = 0
    var ackedSeq: UInt32 = 0
    var dirty = true
    var task: Task<Void, Never>?
}

extension MockEngine {
    static let maxUnackedFrames: UInt32 = 2

    func tabOrThrow(_ id: String) throws -> MockTab {
        guard let t = tabs[id] else { throw notFound("tab", id) }
        return t
    }

    func updateTab(_ id: String, broadcastTab: Bool = true, _ change: (inout MockTab) -> Void) {
        guard var t = tabs[id] else { return }
        change(&t)
        t.tab.canGoBack = !t.back.isEmpty
        t.tab.canGoForward = !t.forward.isEmpty
        tabs[id] = t
        if broadcastTab { broadcast(.browserTab, BrowserTabResult(tab: t.tab)) }
        markDirty(id)
    }

    func markDirty(_ tabId: String) {
        for (id, s) in browserStreams where s.tabId == tabId { browserStreams[id]?.dirty = true }
    }

    func createTab(url: String?) -> BrowserTab {
        let page = fixtures.page(for: url ?? "https://cmux.dev")
        let tab = BrowserTab(id: makeId("tab"), url: page.url, title: page.title)
        tabs[tab.id] = MockTab(tab: tab, page: page)
        tabOrder.append(tab.id)
        broadcast(.browserTab, BrowserTabResult(tab: tab))
        return tab
    }

    func closeTab(_ id: String) throws {
        guard let t = tabs.removeValue(forKey: id) else { throw notFound("tab", id) }
        t.loadTask?.cancel()
        tabOrder.removeAll { $0 == id }
        for (streamId, s) in browserStreams where s.tabId == id { releaseStream(streamId) }
        broadcast(.browserClosed, BrowserClosedEvent(tabId: id))
    }

    func activateTab(_ id: String) throws {
        _ = try tabOrThrow(id)
        for other in tabOrder where other != id && tabs[other]?.tab.active == true {
            updateTab(other) { $0.tab.active = false }
        }
        updateTab(id) { $0.tab.active = true }
    }

    func attachTab(_ p: BrowserAttachParams, session: MockServerSession) throws -> BrowserAttachResult {
        let tab = try tabOrThrow(p.tabId)
        // One screencast per tab, as on the real host: a new attachment takes
        // over and the displaced phone hears `browser.detached`.
        for (oldId, old) in browserStreams where old.tabId == p.tabId {
            let owner = streamOwners[oldId]
            releaseStream(oldId)
            if let owner, owner != session.id {
                send(.browserDetached, BrowserDetachedEvent(streamId: oldId, tabId: p.tabId, reason: .displaced), to: owner)
            }
        }
        let streamId = allocateStream(for: session)
        var stream = MockBrowserStream(tabId: p.tabId, width: p.width, height: p.height, scale: p.scale)
        stream.task = Task { await self.browserLoop(streamId) }
        browserStreams[streamId] = stream
        updateTab(p.tabId, broadcastTab: false) { $0.viewportHeight = Double(p.height) }
        return BrowserAttachResult(streamId: streamId, tab: tab.tab)
    }

    func setViewport(_ p: BrowserViewportParams) throws {
        _ = try tabOrThrow(p.tabId)
        for (id, s) in browserStreams where s.tabId == p.tabId {
            browserStreams[id]?.width = p.width
            browserStreams[id]?.height = p.height
            browserStreams[id]?.scale = p.scale
        }
        updateTab(p.tabId, broadcastTab: false) { $0.viewportHeight = Double(p.height) }
    }

    func ack(streamId: UInt32, seq: UInt32) {
        guard var s = browserStreams[streamId] else { return }
        s.ackedSeq = max(s.ackedSeq, min(seq, s.sentSeq))
        browserStreams[streamId] = s
    }

    /// Sends a frame when the tab changed and at most two frames are unacked.
    func browserLoop(_ streamId: UInt32) async {
        var ticks = 0
        let interval = 1000 / max(1, options.browserFPS)
        let ticksPerSecond = max(1, Int(options.browserFPS.rounded()))
        while !Task.isCancelled {
            guard var s = browserStreams[streamId], let tab = tabs[s.tabId] else { return }
            ticks += 1
            if ticks % ticksPerSecond == 0 { s.dirty = true }  // caret blink and footer clock
            if s.dirty, s.sentSeq &- s.ackedSeq < Self.maxUnackedFrames {
                let renderer = MockPageRenderer(page: tab.page, scrollY: tab.scrollY, typed: tab.typed,
                                                loadingProgress: tab.tab.loading ? tab.tab.progress : nil,
                                                highlightedSection: tab.highlightedSection, tick: ticks / ticksPerSecond)
                if let (jpeg, pxW, pxH) = renderer.renderJPEG(cssWidth: Double(s.width), cssHeight: Double(s.height), scale: s.scale) {
                    s.sentSeq &+= 1
                    let frame = BrowserFrame(seq: s.sentSeq, cssWidth: UInt16(clamping: s.width), cssHeight: UInt16(clamping: s.height),
                                             pixelWidth: UInt16(clamping: pxW), pixelHeight: UInt16(clamping: pxH), format: .jpeg, image: jpeg)
                    sendFrame(StreamFrame(kind: .browserFrame, streamId: streamId, payload: frame.encodedPayload()))
                }
                s.dirty = false
            }
            browserStreams[streamId] = s
            do { try await pause(interval) } catch { return }
        }
    }

    // MARK: Navigation

    func navigate(_ id: String, to raw: String) throws {
        _ = try tabOrThrow(id)
        var url = raw.trimmingCharacters(in: .whitespaces)
        if !url.contains("://") {
            url = url.contains(".") && !url.contains(" ")
                ? "https://" + url
                : "https://duckduckgo.com/?q=" + (url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)
        }
        startLoading(id, url: url, pushHistory: true)
    }

    func startLoading(_ id: String, url: String, pushHistory: Bool) {
        guard let current = tabs[id] else { return }
        current.loadTask?.cancel()
        updateTab(id) { t in
            if pushHistory, t.tab.url != url { t.back.append(t.tab.url); t.forward.removeAll() }
            t.tab.loading = true
            t.tab.progress = 0.1
            t.tab.url = url
            t.typed = ""
        }
        let task = Task { await self.loadProgress(id, url: url) }
        tabs[id]?.loadTask = task
    }

    func loadProgress(_ id: String, url: String) async {
        do {
            for p in [0.3, 0.55, 0.8] {
                try await pause(180)
                updateTab(id) { $0.tab.progress = p }
            }
            try await pause(200)
            let page = fixtures.page(for: url)
            updateTab(id) { t in
                t.page = page
                t.tab.title = page.title
                t.tab.progress = 1
                t.tab.loading = false
                t.scrollY = 0
                t.highlightedSection = nil
                t.loadTask = nil
            }
        } catch {}
    }

    func stopLoading(_ id: String) throws {
        _ = try tabOrThrow(id)
        tabs[id]?.loadTask?.cancel()
        updateTab(id) { $0.tab.loading = false; $0.tab.progress = 1; $0.loadTask = nil }
    }

    func goBack(_ id: String) throws {
        var t = try tabOrThrow(id)
        guard let previous = t.back.popLast() else { return }
        t.forward.append(t.tab.url)
        tabs[id] = t
        startLoading(id, url: previous, pushHistory: false)
    }

    func goForward(_ id: String) throws {
        var t = try tabOrThrow(id)
        guard let next = t.forward.popLast() else { return }
        t.back.append(t.tab.url)
        tabs[id] = t
        startLoading(id, url: next, pushHistory: false)
    }

    // MARK: Input

    func scroll(_ id: String, dy: Double) throws {
        _ = try tabOrThrow(id)
        updateTab(id, broadcastTab: false) { t in
            let maxY = max(0, t.page.contentHeight - t.viewportHeight)
            t.scrollY = min(maxY, max(0, t.scrollY + dy))
        }
    }

    func beginGesture(_ id: String, x: Double, y: Double) {
        updateTab(id, broadcastTab: false) { t in
            t.gestureStart = (x, y)
            t.gestureLastY = y
            t.gestureMoved = false
            t.highlightedSection = t.page.section(atPageY: y + t.scrollY)
        }
    }

    func moveGesture(_ id: String, y: Double) {
        guard let t = tabs[id], t.gestureStart != nil else { return }
        let dy = t.gestureLastY - y
        updateTab(id, broadcastTab: false) { t in
            t.gestureLastY = y
            if let start = t.gestureStart, abs(start.y - y) > 8 { t.gestureMoved = true; t.highlightedSection = nil }
            let maxY = max(0, t.page.contentHeight - t.viewportHeight)
            t.scrollY = min(maxY, max(0, t.scrollY + dy))
        }
    }

    func endGesture(_ id: String, x: Double, y: Double, cancelled: Bool) {
        guard let t = tabs[id], t.gestureStart != nil else { return }
        let tapped = !cancelled && !t.gestureMoved ? t.page.section(atPageY: y + t.scrollY) : nil
        updateTab(id, broadcastTab: false) { t in
            t.gestureStart = nil
            t.highlightedSection = nil
        }
        if let tapped {
            let slug = t.page.sections[tapped].title.lowercased()
                .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            startLoading(id, url: t.page.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + slug, pushHistory: true)
        }
    }

    func pointer(_ p: BrowserPointerParams) throws {
        _ = try tabOrThrow(p.tabId)
        switch p.type {
        case .down: beginGesture(p.tabId, x: p.x, y: p.y)
        case .move: if p.button == .left { moveGesture(p.tabId, y: p.y) }
        case .up: endGesture(p.tabId, x: p.x, y: p.y, cancelled: false)
        }
    }

    func touch(_ p: BrowserTouchParams) throws {
        _ = try tabOrThrow(p.tabId)
        guard let point = p.points.first else {
            if p.type == .end || p.type == .cancel { endGesture(p.tabId, x: 0, y: tabs[p.tabId]?.gestureLastY ?? 0, cancelled: p.type == .cancel) }
            return
        }
        switch p.type {
        case .start: beginGesture(p.tabId, x: point.x, y: point.y)
        case .move: moveGesture(p.tabId, y: point.y)
        case .end: endGesture(p.tabId, x: point.x, y: point.y, cancelled: false)
        case .cancel: endGesture(p.tabId, x: point.x, y: point.y, cancelled: true)
        }
    }

    func key(_ p: BrowserKeyParams) throws {
        _ = try tabOrThrow(p.tabId)
        guard p.type == .down else { return }
        switch p.key {
        case "Backspace":
            updateTab(p.tabId, broadcastTab: false) { t in if !t.typed.isEmpty { t.typed.removeLast() } }
        case "Enter":
            if let typed = tabs[p.tabId]?.typed, !typed.isEmpty { try navigate(p.tabId, to: typed) }
        case "ArrowDown", "PageDown":
            try scroll(p.tabId, dy: p.key == "PageDown" ? 600 : 60)
        case "ArrowUp", "PageUp":
            try scroll(p.tabId, dy: p.key == "PageUp" ? -600 : -60)
        default:
            if let text = p.text, !text.isEmpty { try typeText(p.tabId, text) }
        }
    }

    func typeText(_ id: String, _ text: String) throws {
        _ = try tabOrThrow(id)
        updateTab(id, broadcastTab: false) { $0.typed += text }
    }

    func screenshot(_ id: String) throws -> Data {
        let t = try tabOrThrow(id)
        let renderer = MockPageRenderer(page: t.page, scrollY: t.scrollY, typed: t.typed, loadingProgress: nil,
                                        highlightedSection: nil, tick: 0)
        guard let (jpeg, _, _) = renderer.renderJPEG(cssWidth: 390, cssHeight: 760, scale: 1, quality: 0.6) else {
            throw RPCError(code: .internal, message: "Render failed")
        }
        return jpeg
    }
}
