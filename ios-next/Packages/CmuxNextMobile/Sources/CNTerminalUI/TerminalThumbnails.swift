#if os(iOS)
public import CNCore
public import CNTransport
import CNDesign
import Foundation
import GhosttyNextKit
public import SwiftUI
public import UIKit

/// Static snapshot images of terminals for a tab grid (cards), including
/// terminals that are not on screen. Cards never render live.
///
/// A card's image comes from the live terminal's last presented frame when
/// the user leaves that terminal (`resume(_:image:)`, `setImage`), or, for a
/// terminal not open on this phone, from ONE off-screen frame: a headless
/// Ghostty surface at card resolution attaches to the host's stream, lets
/// the replay settle, draws once, hands over the frame and is torn down.
/// One surface at a time, in order (cards without an image first).
///
/// `show(_:cardSize:)` is called when the grid opens: cards with no image,
/// one in the other appearance, or one older than `minRefreshAge` queue for
/// one frame each (the host has no "output since" signal, so the age bounds
/// refreshes to at most one per card per grid opening and interval). Nothing
/// renders while the cards are hidden (`setVisible(false)`) or the app is in
/// the background; while the grid scrolls (`setPaused(true)`) only cards
/// with no image yet are drawn, and new images wait until it stops.
/// Mirrored (`term.mirror.v1`) terminals render at the Mac's grid; phone
/// owned ones attach at their current grid, so nothing is resized.
@MainActor
@Observable
public final class TerminalThumbnails {
    public let connection: HostConnection
    /// Kept for API compatibility: at most one off-screen surface runs.
    public let maxLive: Int
    /// A card's image is refreshed when the grid opens only if it is at
    /// least this old.
    public let minRefreshAge: Duration
    /// Latest card image per terminal id.
    public private(set) var images: [String: UIImage] = [:]
    /// For an image taken from the live terminal: the bottom of its last row
    /// with content, in points of the terminal (the image at its width).
    @ObservationIgnored private var contentBottoms: [String: CGFloat] = [:]

    @ObservationIgnored private var current: (id: String, terminal: HeadlessTerminal)?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var snapshotAt: [String: ContinuousClock.Instant] = [:]
    /// Images that arrived while the grid scrolled (published when it stops).
    @ObservationIgnored private var held: [String: (UIImage, UIUserInterfaceStyle)] = [:]
    @ObservationIgnored private var cardSize = CGSize(width: 180, height: 300)
    @ObservationIgnored private var generation = -1
    @ObservationIgnored private var style: UIUserInterfaceStyle = .light
    /// `show` was called with `.unspecified`: follow the app's windows.
    @ObservationIgnored private var followsSystem = false
    /// The last text drawn per terminal, so a style or size change redraws
    /// every text card at once without waiting for a frame.
    @ObservationIgnored private var lastLines: [String: (lines: [String], grid: (cols: Int, rows: Int))] = [:]
    @ObservationIgnored private var observedWindows: [ObjectIdentifier: any UITraitChangeRegistration] = [:]
    /// Terminals open full screen: their card comes from the open view.
    @ObservationIgnored private var suspended: Set<String> = []
    @ObservationIgnored private var lastWanted: [String] = []
    /// Terminals that ended on the Mac (their card says so; never attached again).
    @ObservationIgnored private var ended: Set<String> = []
    /// The light/dark style each card image was drawn in.
    @ObservationIgnored private var imageStyles: [String: UIUserInterfaceStyle] = [:]
    /// The grid is scrolling.
    @ObservationIgnored private var paused = false
    /// The cards are on screen (false: nothing renders).
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var active = true
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []

    /// Card width in pixels (images are rendered at this width).
    public var cardPixelWidth: CGFloat { (cardSize.width * min(UIScreen.main.scale, 2)).rounded() }

    public init(connection: HostConnection, maxLive: Int = 1, minRefreshAge: Duration = .seconds(10)) {
        self.connection = connection
        self.maxLive = maxLive
        self.minRefreshAge = minRefreshAge
        observeLifecycle()
    }

    isolated deinit {
        current?.terminal.stop()
        for o in lifecycleObservers { NotificationCenter.default.removeObserver(o) }
    }

    /// The grid opened (or its cards or size changed): queues one frame for
    /// each card that needs one. Cards render at `cardSize` (points) in
    /// `style` (light or dark); `.unspecified` follows the app's windows.
    public func show(_ terminalIds: [String], cardSize: CGSize, style: UIUserInterfaceStyle = .unspecified) {
        followsSystem = style == .unspecified
        if followsSystem { observeWindows() }
        let resolved = followsSystem ? windowStyle : style
        let restyled = resolved != self.style || cardSize != self.cardSize
        self.cardSize = cardSize
        self.style = resolved
        if restyled { redrawAll() }
        if connection.generation != generation {
            // A new link: a running stream is gone.
            generation = connection.generation
            stopCurrent(requeue: false)
        }
        let wanted = terminalIds.filter { !suspended.contains($0) && !ended.contains($0) }
        lastWanted = wanted
        let now = ContinuousClock.now
        let missing = wanted.filter { images[$0] == nil }
        let stale = wanted.filter { id in
            images[id] != nil && (imageStyles[id] != resolved || snapshotAt[id].map { now - $0 >= minRefreshAge } ?? true)
        }
        queue = missing + stale
        if let current, !wanted.contains(current.id) { stopCurrent(requeue: false) }
        if let current { queue.removeAll { $0 == current.id } }
        TerminalMemory.trace("thumbnails show \(terminalIds.count) ids, missing \(missing.count), stale \(stale.count), client \(connection.client != nil)")
        pump()
    }

    /// Holds (true) or resumes (false) refreshes while the grid scrolls:
    /// only cards with no image yet are drawn; new images of other cards
    /// wait until it stops.
    public func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if !paused {
            for (id, entry) in held { publish(id, entry.0, entry.1) }
            held.removeAll()
            pump()
        }
    }

    /// Whether the cards are on screen. Hidden cards never render.
    public func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        if visible { pump() } else { stopCurrent(requeue: true) }
    }

    /// Starts the next queued card when nothing is rendering.
    private func pump() {
        guard current == nil, visible, active, let client = connection.client else { return }
        guard let index = queue.firstIndex(where: { !paused || images[$0] == nil }) else { return }
        let id = queue.remove(at: index)
        let mirrored = connection.hostInfo?.supports(.terminalMirror) ?? false
        let style = self.style
        let headless = HeadlessTerminal(terminalId: id, client: client, mirrored: mirrored, style: style, page: pageSize) { [weak self] result in
            guard let self else { return }
            switch result {
            case .image(let image, let drawnStyle):
                if self.paused, self.images[id] != nil {
                    self.held[id] = (image, drawnStyle)
                } else {
                    self.publish(id, image, drawnStyle)
                }
            case .text(let lines, let grid):
                self.render(id, lines: lines, grid: grid)
            case .ended:
                self.images[id] = TerminalCardRenderer.endedImage(size: self.cardSize, style: self.style)
                self.imageStyles[id] = self.style
                self.ended.insert(id)
            }
        } onSettled: { [weak self] in
            guard let self, self.current?.id == id else { return }
            self.current?.terminal.stop()
            self.current = nil
            self.pump()
        }
        current = (id, headless)
        headless.start()
    }

    /// How far a card showing only the top `visibleHeight` points (at the
    /// terminal's width) of `terminalId`'s image moves it up so its prompt and
    /// cursor are in view. Off-screen frames are drawn at the card's shape
    /// and need none (0).
    public func cardOffset(_ terminalId: String, visibleHeight: CGFloat) -> CGFloat {
        Self.cardOffset(contentBottom: contentBottoms[terminalId], visibleHeight: visibleHeight)
    }

    /// The prompt row plus a little room, kept inside a card `visibleHeight` tall.
    nonisolated static func cardOffset(contentBottom: CGFloat?, visibleHeight: CGFloat) -> CGFloat {
        guard let contentBottom, contentBottom.isFinite, visibleHeight.isFinite, visibleHeight > 0 else { return 0 }
        return max(0, (contentBottom + 8 - visibleHeight).rounded(.up))
    }

    private func publish(_ id: String, _ image: UIImage, _ drawnStyle: UIUserInterfaceStyle, contentBottom: CGFloat? = nil) {
        images[id] = image
        contentBottoms[id] = contentBottom
        imageStyles[id] = drawnStyle
        lastLines[id] = nil
        snapshotAt[id] = .now
    }

    private func stopCurrent(requeue: Bool) {
        guard let current else { return }
        current.terminal.stop()
        self.current = nil
        if requeue, !queue.contains(current.id) { queue.insert(current.id, at: 0) }
    }

    /// The app went to the background: the running surface and its stream
    /// stop; the grid queues its cards again in the foreground.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.active = false
                self.stopCurrent(requeue: true)
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.active = true
                self.pump()
            }
        })
    }

    /// The page a card shows, in points (the screen's width, the card's
    /// aspect) and the scale that makes it `cardPixelWidth` pixels wide.
    private var pageSize: (size: CGSize, scale: CGFloat) {
        let width = max(1, UIScreen.main.bounds.width)
        let aspect = cardSize.height / max(1, cardSize.width)
        return (CGSize(width: width, height: (width * aspect).rounded()), cardPixelWidth / width)
    }

    /// The terminal opened full screen: no off-screen frame for it.
    public func suspend(_ terminalId: String) {
        suspended.insert(terminalId)
        queue.removeAll { $0 == terminalId }
        if current?.id == terminalId { stopCurrent(requeue: false); pump() }
    }

    /// The full-screen terminal closed without a frame: its last text
    /// becomes the card (if given), and it queues for one off-screen frame.
    public func resume(_ terminalId: String, lines: [String]? = nil, grid: (cols: Int, rows: Int)? = nil) {
        suspended.remove(terminalId)
        if let lines, let grid { render(terminalId, lines: lines, grid: grid) }
        if !queue.contains(terminalId), current?.id != terminalId { queue.insert(terminalId, at: 0) }
        pump()
    }

    /// The full-screen terminal closed with this frame of its renderer.
    public func resume(_ terminalId: String, image: UIImage, contentBottom: CGFloat? = nil) {
        suspended.remove(terminalId)
        setImage(terminalId, image: image, contentBottom: contentBottom)
    }

    /// A card image taken from the live terminal (its last presented frame);
    /// `contentBottom` places its prompt (see `cardOffset`).
    public func setImage(_ terminalId: String, image: UIImage, contentBottom: CGFloat? = nil) {
        queue.removeAll { $0 == terminalId }
        held[terminalId] = nil
        publish(terminalId, image, style, contentBottom: contentBottom)
    }

    /// Stops the running surface; images stay until replaced.
    public func stopAll() {
        stopCurrent(requeue: false)
        queue.removeAll()
    }

    /// Drops a terminal's image (it was closed).
    public func forget(_ terminalId: String) {
        if current?.id == terminalId { stopCurrent(requeue: false) }
        queue.removeAll { $0 == terminalId }
        images[terminalId] = nil
        contentBottoms[terminalId] = nil
        lastLines[terminalId] = nil
        snapshotAt[terminalId] = nil
        held[terminalId] = nil
        pump()
    }

    private func render(_ id: String, lines: [String], grid: (cols: Int, rows: Int)) {
        lastLines[id] = (lines, grid)
        contentBottoms[id] = nil
        imageStyles[id] = style
        images[id] = TerminalCardRenderer.image(lines: lines, cols: grid.cols, size: cardSize, style: style)
    }

    /// Redraws every text card from its last text in the current style and size.
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
        // Cards in the other appearance get one frame each, in turn.
        stopCurrent(requeue: true)
        let restyle = lastWanted.filter { !ended.contains($0) && imageStyles[$0] != style && !queue.contains($0) }
        queue.insert(contentsOf: restyle, at: 0)
        pump()
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

/// One frame of a terminal rendered off screen for its card: a Ghostty
/// surface with its real Metal renderer, laid out like the page (screen
/// width, card aspect) at card resolution, fed by its own attach stream.
/// Once the replay has settled (no output for `quiet`, or `maxWait` after
/// attaching while output keeps coming) it draws one frame, delivers the
/// presented pixels (same as the live terminal) and calls `onSettled`; the
/// owner then stops it. Never draws again on its own.
@MainActor
final class HeadlessTerminal {
    let terminalId: String
    let client: HostClient
    let mirrored: Bool
    let onResult: (CardResult) -> Void
    let onSettled: () -> Void
    /// Output pause that counts as "the replay arrived" (a UI debounce).
    static let quiet: Duration = .milliseconds(150)
    /// Draw even if output keeps coming (a busy terminal).
    static let maxWait: Duration = .milliseconds(1500)
    /// Give up (the owner moves to the next card).
    static let timeout: Duration = .seconds(6)
    /// Draws for one card: the frame, font fitting passes, retries.
    static let maxRenders = 6

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
    private var settled = false
    private var renders = 0
    private var quietTask: Task<Void, Never>?
    private var deadlineTasks: [Task<Void, Never>] = []

    init(terminalId: String, client: HostClient, mirrored: Bool, style: UIUserInterfaceStyle,
         page: (size: CGSize, scale: CGFloat), onResult: @escaping (CardResult) -> Void,
         onSettled: @escaping () -> Void) {
        self.terminalId = terminalId
        self.client = client
        self.mirrored = mirrored
        self.style = style
        self.page = page
        self.onResult = onResult
        self.onSettled = onSettled
        view = UIView(frame: CGRect(origin: .zero, size: page.size))
    }

    private func settle() {
        guard !settled, !stopped else { return }
        settled = true
        onSettled()
    }

    /// Draws once output has paused for `quiet` (bounded delay, restarted
    /// by each chunk; `maxWait` caps it).
    private func scheduleQuietRender() {
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.quiet) } catch { return }
            self?.requestRender()
        }
    }

    func start() {
        guard let app = try? GhosttyApp.shared() else { return }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = Double(page.scale)
        config.font_size = Float(fontSize)
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        guard let surface = ghostty_surface_new(app.app, &config) else { settle(); return }
        // Drawn (never shown): the page at card resolution. Visible to the
        // renderer for its short life (one card frame, then torn down).
        ghostty_surface_set_occlusion(surface, true)
        ref = SurfaceRef(surface)
        applyStyle()
        applySize()
        Self.liveCount += 1
        TerminalMemory.log()
        let client = self.client
        let id = terminalId
        deadlineTasks.append(Task { [weak self] in
            do { try await Task.sleep(for: Self.maxWait) } catch { return }
            guard let self, self.renders == 0 else { return }
            self.requestRender()
        })
        deadlineTasks.append(Task { [weak self] in
            do { try await Task.sleep(for: Self.timeout) } catch { return }
            self?.settle()
        })
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
                // An empty terminal sends nothing: draw after the quiet time.
                self.scheduleQuietRender()
                for await bytes in client.openStream(id: result.streamId) {
                    guard !self.stopped else { break }
                    self.feed(bytes)
                }
            } catch {
                TerminalMemory.trace("thumbnail \(id): attach failed: \(error)")
                if let rpc = error as? RPCError, rpc.code == .notFound, let self, !self.stopped { self.onResult(.ended) }
                self?.settle()
                return
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        task?.cancel()
        quietTask?.cancel()
        for t in deadlineTasks { t.cancel() }
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
        scheduleQuietRender()
    }

    /// Draws the card's frame (after the output queued so far was parsed);
    /// settles once a frame was delivered and nothing asks for another
    /// (font fitting), or after `maxRenders`.
    private func renderIfIdle() {
        guard dirty, !rendering, !stopped, !settled, let ref else { return }
        dirty = false
        rendering = true
        renders += 1
        // After the output queued so far was parsed.
        queue.async {
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.fitMirrorFont()
                let before = GhosttySnapshot.frameID(of: self.view)
                ghostty_surface_refresh(ref.surface)
                ghostty_surface_draw(ref.surface)
                await self.deliverFrame(ref, after: before)
                if self.stopped { return }
                self.rendering = false
                if self.dirty, self.renders < Self.maxRenders {
                    self.renderIfIdle()
                } else if self.delivered || self.renders >= Self.maxRenders {
                    self.settle()
                }
            }
        }
    }

    /// The presented frame as an image, read off the main thread.
    private func readFrame() async -> CGImage? {
        guard let frame = GhosttySnapshot.presentedFrame(of: view) else { return nil }
        return await Task.detached(priority: .utility) { GhosttySnapshot.image(of: frame) }.value
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
               let cg = await readFrame() {
                if stopped { return }
                TerminalMemory.trace("thumbnail \(terminalId): frame \(cg.width)x\(cg.height) style=\(style == .dark ? "dark" : "light")")
                onResult(.image(UIImage(cgImage: cg), style))
                delivered = true
                return
            }
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        }
        // A frame from before this draw may be in the old theme: only use it
        // when the card has nothing yet.
        if !delivered, let cg = await readFrame(), !stopped {
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
