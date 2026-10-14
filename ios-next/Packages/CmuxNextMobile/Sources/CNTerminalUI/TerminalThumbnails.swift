#if os(iOS)
public import CNCore
public import CNTransport
import CNDesign
import Foundation
import GhosttyNextKit
public import SwiftUI
public import UIKit

/// Live snapshot images of terminals for a tab grid (cards), including
/// terminals that are not on screen.
///
/// Each shown terminal gets a headless Ghostty surface (never drawn, small
/// scrollback) attached to the host's stream: it parses the output exactly
/// like the full terminal, and the card image is the visible grid's text
/// drawn in the theme's colors, refreshed on output at most every
/// `refreshInterval` (2 Hz by default). At most `maxLive` terminals stay
/// attached (least recently shown are dropped), so memory is bounded.
/// Mirrored (`term.mirror.v1`) terminals render at the Mac's grid; phone
/// owned ones attach at their current grid, so nothing is resized.
///
/// Usage: call `show(_:cardSize:)` with the ids visible in the grid (again
/// when that set or the card size changes), read `images[id]` (observable),
/// and call `stopAll()` when the grid goes away.
@MainActor
@Observable
public final class TerminalThumbnails {
    public let connection: HostConnection
    public let maxLive: Int
    public let refreshInterval: Duration
    /// Latest card image per terminal id.
    public private(set) var images: [String: UIImage] = [:]

    @ObservationIgnored private var live: [String: HeadlessTerminal] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var cardSize = CGSize(width: 180, height: 300)
    @ObservationIgnored private var generation = -1
    @ObservationIgnored private var style: UIUserInterfaceStyle = .light
    /// `show` was called with `.unspecified`: follow the app's windows.
    @ObservationIgnored private var followsSystem = false
    /// The last text drawn per terminal, so a style or size change redraws
    /// every card at once (live or not) without waiting for output.
    @ObservationIgnored private var lastLines: [String: (lines: [String], grid: (cols: Int, rows: Int))] = [:]
    @ObservationIgnored private var observedWindows: [ObjectIdentifier: any UITraitChangeRegistration] = [:]

    /// Terminals open full screen: their card comes from the open view when
    /// it closes; no off-screen surface parses them meanwhile.
    @ObservationIgnored private var suspended: Set<String> = []
    /// Cards waiting for a surface to draw their first (or restyled) image.
    @ObservationIgnored private var pendingImage: [String] = []
    @ObservationIgnored private var lastWanted: [String] = []
    /// Terminals that ended on the Mac (their card says so; never attached again).
    @ObservationIgnored private var ended: Set<String> = []
    /// The light/dark style each card image was drawn in.
    @ObservationIgnored private var imageStyles: [String: UIUserInterfaceStyle] = [:]

    /// Card width in pixels (images are rendered at this width).
    public var cardPixelWidth: CGFloat { (cardSize.width * min(UIScreen.main.scale, 2)).rounded() }

    @ObservationIgnored private var pushTask: Task<Void, Never>?

    public init(connection: HostConnection, maxLive: Int = 6, refreshInterval: Duration = .milliseconds(500)) {
        self.connection = connection
        self.maxLive = maxLive
        self.refreshInterval = refreshInterval
        // Cards follow grid changes (a resize, the Mac's window) like the
        // live view does, so their layout matches.
        pushTask = Task { [weak self, connection] in
            for await push in connection.pushes() {
                guard case .terminalUpdated(let t) = push else { continue }
                self?.live[t.id]?.gridChanged(cols: t.cols, rows: t.rows)
            }
        }
    }

    isolated deinit { pushTask?.cancel() }

    /// Keeps these terminals live (attached and re-rendered on output).
    /// Others beyond `maxLive` are detached, oldest first. Cards render at
    /// `cardSize` (points) in `style` (light or dark).
    /// `.unspecified` follows the app's windows (their light/dark changes
    /// redraw the cards by themselves).
    public func show(_ terminalIds: [String], cardSize: CGSize, style: UIUserInterfaceStyle = .unspecified) {
        followsSystem = style == .unspecified
        if followsSystem { observeWindows() }
        let resolved = followsSystem ? windowStyle : style
        let restyled = resolved != self.style || cardSize != self.cardSize
        self.cardSize = cardSize
        self.style = resolved
        if restyled { redrawAll() }
        if connection.generation != generation {
            // A new link: every stream is gone, attach again.
            generation = connection.generation
            for t in live.values { t.stop() }
            live.removeAll()
        }
        let wanted = terminalIds.filter { !suspended.contains($0) }
        lastWanted = wanted
        for id in wanted {
            order.removeAll { $0 == id }
            order.append(id)
        }
        if restyled { for t in live.values { t.restyle(self.style, page: pageSize) } }
        // Cards with no image (or one in the other appearance) queue for a
        // slot; at most `maxLive` surfaces run. When a queued card is waiting,
        // a live card hands its slot over as soon as it has drawn its image
        // (it keeps that image), so every card gets one however many there
        // are. Cards that already have an image fill free slots to stay live.
        pendingImage = wanted.filter { live[$0] == nil && !ended.contains($0) && (images[$0] == nil || imageStyles[$0] != self.style) }
        let haveImage = wanted.filter { live[$0] == nil && !pendingImage.contains($0) }
        TerminalMemory.trace("thumbnails show \(terminalIds.count) ids, need \(pendingImage.count), live \(live.count), client \(connection.client != nil)")
        // Live cards that are not wanted any more make room first.
        for id in live.keys where !wanted.contains(id) && !pendingImage.isEmpty {
            live.removeValue(forKey: id)?.stop()
        }
        // Live cards whose image is current hand over to waiting ones now.
        for (id, _) in live where !pendingImage.isEmpty && images[id] != nil && imageStyles[id] == self.style && live.count >= maxLive {
            live.removeValue(forKey: id)?.stop()
        }
        startPending()
        _ = haveImage
        while live.count > maxLive, let oldest = order.first(where: { live[$0] != nil && !wanted.contains($0) }) {
            live.removeValue(forKey: oldest)?.stop()
        }
    }

    /// Starts queued cards while slots are free.
    private func startPending() {
        while live.count < maxLive, !pendingImage.isEmpty, connection.client != nil {
            start(pendingImage.removeFirst())
        }
        // Everyone has an image: free slots go back to shown cards, most
        // recently shown first, so they keep following their output.
        guard pendingImage.isEmpty else { return }
        for id in lastWanted.reversed() where live.count < maxLive && live[id] == nil && !suspended.contains(id) && !ended.contains(id) {
            start(id)
        }
    }

    private func start(_ id: String) {
        guard live[id] == nil, let client = connection.client else { return }
        let mirrored = connection.hostInfo?.supports(.terminalMirror) ?? false
        let headless = HeadlessTerminal(terminalId: id, client: client, interval: refreshInterval, mirrored: mirrored,
                                        style: self.style, page: pageSize) { [weak self] result in
            guard let self else { return }
            switch result {
            case .image(let image, let drawnStyle):
                self.images[id] = image
                self.imageStyles[id] = drawnStyle
                self.lastLines[id] = nil
            case .text(let lines, let grid):
                self.render(id, lines: lines, grid: grid)
            case .ended:
                self.images[id] = TerminalCardRenderer.endedImage(size: self.cardSize, style: self.style)
                self.imageStyles[id] = self.style
                self.ended.insert(id)
                self.live.removeValue(forKey: id)?.stop()
            }
            // Hand the slot to a card still waiting for its first image.
            if !self.pendingImage.isEmpty, self.imageStyles[id] == self.style, let done = self.live.removeValue(forKey: id) {
                done.stop()
            }
            self.startPending()
        }
        live[id] = headless
        headless.start()
    }

    /// The page a card shows, in points (the screen's width, the card's
    /// aspect) and the scale that makes it `cardPixelWidth` pixels wide.
    private var pageSize: (size: CGSize, scale: CGFloat) {
        let width = max(1, UIScreen.main.bounds.width)
        let aspect = cardSize.height / max(1, cardSize.width)
        return (CGSize(width: width, height: (width * aspect).rounded()), cardPixelWidth / width)
    }

    /// Frees one live surface not in `keeping` (least recently shown).
    private func evictOldest(keeping: [String]) -> Bool {
        guard let oldest = order.first(where: { live[$0] != nil && !keeping.contains($0) }) else { return false }
        live.removeValue(forKey: oldest)?.stop()
        return true
    }

    /// The terminal opened full screen: stop parsing it off screen.
    public func suspend(_ terminalId: String) {
        suspended.insert(terminalId)
        live.removeValue(forKey: terminalId)?.stop()
    }

    /// The full-screen terminal closed: its last screen becomes the card, and
    /// the next `show` resumes it off screen.
    public func resume(_ terminalId: String, lines: [String]? = nil, grid: (cols: Int, rows: Int)? = nil) {
        suspended.remove(terminalId)
        if let lines, let grid { render(terminalId, lines: lines, grid: grid) }
    }

    /// The full-screen terminal closed with this frame of its renderer.
    public func resume(_ terminalId: String, image: UIImage) {
        suspended.remove(terminalId)
        images[terminalId] = image
        imageStyles[terminalId] = style
        lastLines[terminalId] = nil
    }

    /// Detaches every live terminal; images stay until replaced.
    public func stopAll() {
        for t in live.values { t.stop() }
        live.removeAll()
    }

    /// Drops a terminal's image and stream (it was closed).
    public func forget(_ terminalId: String) {
        live.removeValue(forKey: terminalId)?.stop()
        images[terminalId] = nil
        lastLines[terminalId] = nil
        order.removeAll { $0 == terminalId }
    }

    private func render(_ id: String, lines: [String], grid: (cols: Int, rows: Int)) {
        lastLines[id] = (lines, grid)
        imageStyles[id] = style
        images[id] = TerminalCardRenderer.image(lines: lines, cols: grid.cols, size: cardSize, style: style)
    }

    /// Redraws every card from its last text in the current style and size.
    private func redrawAll() {
        for (id, entry) in lastLines {
            images[id] = TerminalCardRenderer.image(lines: entry.lines, cols: entry.grid.cols, size: cardSize, style: style)
        }
    }

    /// The light/dark style of the app's key window (its override included).
    /// The appearance the app's content is drawn in: the root view
    /// controller's traits, which carry the app's own override (SwiftUI
    /// `preferredColorScheme`, set on the hosting controller rather than the
    /// window) as well as the system's appearance.
    private var windowStyle: UIUserInterfaceStyle {
        let window = contentWindows.first(where: \.isKeyWindow) ?? contentWindows.first
        let style = window?.rootViewController?.traitCollection.userInterfaceStyle
            ?? window?.traitCollection.userInterfaceStyle ?? UIScreen.main.traitCollection.userInterfaceStyle
        return style == .dark ? .dark : .light
    }

    private var contentWindows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .filter { $0.windowLevel == .normal && !$0.isHidden }
    }

    /// Redraws when the app's content switches between light and dark (the
    /// system's appearance or the app's own setting).
    private func observeWindows() {
        for window in contentWindows {
            guard let root = window.rootViewController, observedWindows[ObjectIdentifier(root)] == nil else { continue }
            observedWindows[ObjectIdentifier(root)] = root.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                [weak self] (_: UIViewController, _: UITraitCollection) in
                // Read the new appearance after UIKit finished applying it.
                Task { @MainActor in self?.systemStyleChanged() }
            }
        }
    }

    private func systemStyleChanged() {
        guard followsSystem else { return }
        let resolved = windowStyle
        guard resolved != style else { return }
        style = resolved
        redrawAll()
        // Live cards draw again in the new theme; others when next shown.
        for t in live.values { t.restyle(resolved, page: pageSize) }
        // Cards not live now are redrawn in the new appearance in turn.
        pendingImage = lastWanted.filter { live[$0] == nil && !ended.contains($0) && imageStyles[$0] != style }
        startPending()
    }
}

/// A card for a terminal: the live image, or the theme background while the
/// first image is on its way.
public struct TerminalThumbnail: View {
    let thumbnails: TerminalThumbnails
    let terminalId: String

    public init(thumbnails: TerminalThumbnails, terminalId: String) {
        self.thumbnails = thumbnails
        self.terminalId = terminalId
    }

    public var body: some View {
        if let image = thumbnails.images[terminalId] {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Color.cn(\.terminalBackground)
        }
    }
}

/// Draws a grid's text into a card image (top-anchored, scaled so every
/// column fits the card's width).
struct TerminalCardRenderer {
    /// A card for a terminal that no longer exists on the Mac.
    static func endedImage(size requested: CGSize, style: UIUserInterfaceStyle) -> UIImage {
        let size = CGSize(width: min(max(requested.width, 1), 1024), height: min(max(requested.height, 1), 2048))
        let traits = UITraitCollection(userInterfaceStyle: style == .dark ? .dark : .light)
        let background = CNTheme.shared.palette.terminalBackground.resolvedColor(with: traits)
        let secondary = CNTheme.shared.palette.textSecondary.resolvedColor(with: traits)
        return UIGraphicsImageRenderer(size: size).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = TerminalText.endedTitle as NSString
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: secondary, .paragraphStyle: paragraph,
            ]
            let box = CGRect(x: 8, y: size.height * 0.4, width: size.width - 16, height: size.height * 0.2)
            text.draw(in: box, withAttributes: attributes)
        }
    }

    static func image(lines: [String], cols: Int, size requested: CGSize, style: UIUserInterfaceStyle) -> UIImage {
        // Cards are small: never draw an empty, non-finite or huge bitmap.
        let size = CGSize(width: requested.width.isFinite ? min(max(requested.width, 1), 1024) : 180,
                          height: requested.height.isFinite ? min(max(requested.height, 1), 2048) : 300)
        let traits = UITraitCollection(userInterfaceStyle: style == .dark ? .dark : .light)
        let background = CNTheme.shared.palette.terminalBackground.resolvedColor(with: traits)
        let foreground = (style == .dark ? UIColor.white : UIColor.black)
        let padding: CGFloat = 4
        let columns = max(cols, 20)
        // Monospaced advance is ~0.6 em.
        let fontSize = max(2, (size.width - 2 * padding) / (CGFloat(columns) * 0.6))
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let lineHeight = font.lineHeight
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(UIScreen.main.scale, 2)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            var y = padding
            for line in lines {
                if y > size.height { break }
                if !line.isEmpty {
                    (line as NSString).draw(at: CGPoint(x: padding, y: y), withAttributes: attributes)
                }
                y += lineHeight
            }
        }
    }
}

/// One terminal rendered off screen for its card: a Ghostty surface with its
/// real Metal renderer, laid out like the page (screen width, card aspect)
/// at card resolution, fed by its own attach stream; the card image is the
/// renderer's presented frame (same pixels as the live terminal). Text is
/// the fallback when no frame is available.
@MainActor
final class HeadlessTerminal {
    let terminalId: String
    let client: HostClient
    let interval: Duration
    let mirrored: Bool
    let onResult: (CardResult) -> Void

    enum CardResult {
        case image(UIImage, UIUserInterfaceStyle)
        case text([String], (cols: Int, rows: Int))
        /// The terminal is gone on the Mac.
        case ended
    }

    private let view: UIView
    private var style: UIUserInterfaceStyle
    private var page: (size: CGSize, scale: CGFloat)
    private var fontSize: Double = TerminalFontSize.stored
    private var fitPasses = 0
    private var delivered = false
    private var lastCellWidth: Double = 0
    private var appliedFont: Double?
    private var gridGeneration: UInt64 = 0
    private var ref: SurfaceRef?
    /// One serial parser queue for every off-screen surface.
    static let parserQueue = DispatchQueue(label: "cmux.next.terminal.thumbnails", qos: .utility)
    private var queue: DispatchQueue { Self.parserQueue }
    /// DEBUG: live off-screen surfaces.
    static var liveCount = 0
    private var task: Task<Void, Never>?
    private var streamId: UInt32?
    private var grid = (cols: 80, rows: 24)
    private var dirty = false
    private var rendering = false
    private var stopped = false

    init(terminalId: String, client: HostClient, interval: Duration, mirrored: Bool, style: UIUserInterfaceStyle,
         page: (size: CGSize, scale: CGFloat), onResult: @escaping (CardResult) -> Void) {
        self.terminalId = terminalId
        self.client = client
        self.interval = interval
        self.mirrored = mirrored
        self.style = style
        self.page = page
        self.onResult = onResult
        view = UIView(frame: CGRect(origin: .zero, size: page.size))
    }

    func start() {
        guard let app = try? GhosttyApp.shared() else { return }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = Double(page.scale)
        config.font_size = Float(fontSize)
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        guard let surface = ghostty_surface_new(app.app, &config) else { return }
        // Drawn (never shown): the page at card resolution.
        ghostty_surface_set_occlusion(surface, true)
        ref = SurfaceRef(surface)
        applyStyle()
        applySize()
        Self.liveCount += 1
        TerminalMemory.log()
        let client = self.client
        let id = terminalId
        task = Task { [weak self] in
            do {
                // The current grid, so a phone-owned terminal is not resized;
                // a mirrored one reports the Mac's grid anyway.
                let current = try await client.listTerminals().first { $0.id == id }
                let cols = current?.cols ?? 80, rows = current?.rows ?? 24
                let result = try await client.attachTerminal(id, cols: cols, rows: rows)
                guard let self, !self.stopped else {
                    try? await client.detachTerminal(streamId: result.streamId)
                    return
                }
                self.streamId = result.streamId
                self.setGrid(cols: result.terminal.cols, rows: result.terminal.rows)
                for await bytes in client.openStream(id: result.streamId) {
                    guard !self.stopped else { break }
                    self.feed(bytes)
                }
            } catch {
                TerminalMemory.trace("thumbnail \(id): attach failed: \(error)")
                if let rpc = error as? RPCError, rpc.code == .notFound, let self, !self.stopped { self.onResult(.ended) }
                return
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        task?.cancel()
        if let streamId {
            let client = self.client
            Task { try? await client.detachTerminal(streamId: streamId) }
        }
        guard let ref else { return }
        Self.liveCount -= 1
        TerminalMemory.log()
        let view = Retained(self.view)
        queue.async {
            DispatchQueue.main.async {
                ghostty_surface_free(ref.surface)
                _ = view
            }
        }
    }

    func requestRender() {
        dirty = true
        renderIfIdle()
    }

    /// A light/dark or card size change: new theme and drawable, then a frame.
    func restyle(_ style: UIUserInterfaceStyle, page: (size: CGSize, scale: CGFloat)) {
        self.style = style
        self.page = page
        view.frame = CGRect(origin: .zero, size: page.size)
        applyStyle()
        applySize()
        requestRender()
    }

    private func applyStyle() {
        guard let ref, let app = try? GhosttyApp.shared() else { return }
        ghostty_surface_set_color_scheme(ref.surface, style == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        ghostty_surface_update_config(ref.surface, app.config(for: style == .dark ? .dark : .light))
        applyFontSize()
    }

    private func applySize() {
        guard let ref, let px = GhosttyTerminalView.drawablePixels(page.size, scale: page.scale) else { return }
        ghostty_surface_set_content_scale(ref.surface, Double(page.scale), Double(page.scale))
        ghostty_surface_set_size(ref.surface, px.width, px.height)
    }

    private func applyFontSize() {
        guard let ref else { return }
        let action = "set_font_size:\(fontSize)"
        _ = action.withCString { ghostty_surface_binding_action(ref.surface, $0, UInt(action.utf8.count)) }
    }

    /// A Mac-owned grid: the text size at which every column fits the page
    /// width, like the live view (down to its 7 pt floor).
    private func fitMirrorFont() {
        guard mirrored, fitPasses < 8, let ref else { return }
        // Ghostty reports how many columns fit the view at the current size
        // (with its own pixel rounding), even with a locked grid.
        let size = ghostty_surface_size(ref.surface)
        let fits = Int(size.columns)
        guard fits > 0, size.cell_width_px > 0 else { return }
        // The report lags a font change by a frame: wait for a new cell width.
        if appliedFont != nil, Double(size.cell_width_px) == lastCellWidth { return }
        lastCellWidth = Double(size.cell_width_px)
        fitPasses += 1
        var next = fontSize
        if fits < grid.cols {
            // Every Mac column fits the card (cards are scaled pages, never
            // panned; at card resolution they may go below the live 7 pt).
            next = max(3, ((fontSize * Double(fits) / Double(grid.cols)) * 4).rounded(.down) / 4)
            if next >= fontSize { next = max(3, fontSize - 0.25) }
        } else if fits > grid.cols + 2, fontSize < TerminalFontSize.stored, appliedFont == nil {
            next = min(TerminalFontSize.stored, ((fontSize * Double(grid.cols) / Double(fits + 1)) * 4).rounded(.down) / 4)
        }
        if next != fontSize {
            fontSize = next
            appliedFont = next
            applyFontSize()
            requestRender()
        }
    }

    func gridChanged(cols: Int, rows: Int) {
        guard (cols, rows) != (grid.cols, grid.rows) else { return }
        setGrid(cols: cols, rows: rows)
        requestRender()
    }

    private func setGrid(cols: Int, rows: Int) {
        guard let ref, let c = UInt16(exactly: cols), let r = UInt16(exactly: rows), c > 0, r > 0 else { return }
        grid = (cols, rows)
        fitPasses = 0
        appliedFont = nil
        gridGeneration += 1
        let generation = gridGeneration
        queue.async { _ = ghostty_surface_set_grid(ref.surface, c, r, generation) }
    }

    private func feed(_ bytes: Data) {
        guard let ref else { return }
        queue.async {
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_process_output(ref.surface, base, UInt(raw.count))
            }
        }
        requestRender()
    }

    /// Renders now, then at most once per interval while output keeps coming.
    private func renderIfIdle() {
        guard dirty, !rendering, !stopped, let ref else { return }
        dirty = false
        rendering = true
        // After the output queued so far was parsed.
        queue.async {
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.fitMirrorFont()
                let before = GhosttySnapshot.frameID(of: self.view)
                ghostty_surface_refresh(ref.surface)
                ghostty_surface_draw(ref.surface)
                await self.deliverFrame(ref, after: before)
                do { try await Task.sleep(for: self.interval) } catch {}
                self.rendering = false
                self.renderIfIdle()
            }
        }
    }

    /// The presented frame once Ghostty has set it (a few main-actor turns
    /// at most); without one the card keeps its image and retries.
    private func deliverFrame(_ ref: SurfaceRef, after previous: (UInt32, UInt32)?) async {
        // Ghostty presents on its renderer thread: wait (bounded) for a frame
        // that is not the one shown before this draw.
        for _ in 0..<12 {
            await Task.yield()
            if stopped { return }
            if let id = GhosttySnapshot.frameID(of: view), previous.map({ $0 != id }) ?? true,
               let cg = GhosttySnapshot.image(of: view) {
                TerminalMemory.trace("thumbnail \(terminalId): frame \(cg.width)x\(cg.height) style=\(style == .dark ? "dark" : "light")")
                onResult(.image(UIImage(cgImage: cg), style))
                delivered = true
                return
            }
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        }
        // A frame from before this draw may be in the old theme: only use it
        // when the card has nothing yet.
        if !delivered, let cg = GhosttySnapshot.image(of: view) {
            TerminalMemory.trace("thumbnail \(terminalId): earlier frame (no new frame in time)")
            onResult(.image(UIImage(cgImage: cg), style))
            delivered = true
            dirty = true
            return
        }
        // No frame yet (the renderer had nothing to present): keep the last
        // image and try again on the next interval; never a monochrome text
        // stand-in.
        TerminalMemory.trace("thumbnail \(terminalId): no frame yet, retrying")
        dirty = true
    }

    /// The viewport's rows as text (output queue only), within the grid the
    /// surface really has.
    nonisolated private static func readLines(_ surface: ghostty_surface_t, cols wantedCols: Int, rows wantedRows: Int) -> [String] {
        let actual = ghostty_surface_grid(surface)
        return TerminalTextReader.lines(surface, cols: min(wantedCols, Int(actual.columns)), rows: min(wantedRows, Int(actual.rows)))
    }
}
#endif
