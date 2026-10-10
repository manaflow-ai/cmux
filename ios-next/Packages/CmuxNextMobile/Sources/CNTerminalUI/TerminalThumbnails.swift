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

    public init(connection: HostConnection, maxLive: Int = 20, refreshInterval: Duration = .milliseconds(500)) {
        self.connection = connection
        self.maxLive = maxLive
        self.refreshInterval = refreshInterval
    }

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
        for id in terminalIds {
            order.removeAll { $0 == id }
            order.append(id)
            if live[id] == nil, let client = connection.client {
                let headless = HeadlessTerminal(terminalId: id, client: client, interval: refreshInterval) { [weak self] lines, grid in
                    self?.render(id, lines: lines, grid: grid)
                }
                live[id] = headless
                headless.start()
            } else if restyled {
                live[id]?.requestRender()
            }
        }
        while live.count > maxLive, let oldest = order.first(where: { live[$0] != nil && !terminalIds.contains($0) }) {
            live.removeValue(forKey: oldest)?.stop()
            order.removeAll { $0 == oldest }
        }
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
        images[id] = TerminalCardRenderer.image(lines: lines, cols: grid.cols, size: cardSize, style: style)
    }

    /// Redraws every card from its last text in the current style and size.
    private func redrawAll() {
        for (id, entry) in lastLines {
            images[id] = TerminalCardRenderer.image(lines: entry.lines, cols: entry.grid.cols, size: cardSize, style: style)
        }
    }

    /// The light/dark style of the app's key window (its override included).
    private var windowStyle: UIUserInterfaceStyle {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        let style = window?.traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
        return style == .dark ? .dark : .light
    }

    /// Redraws when any app window switches between light and dark.
    private func observeWindows() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where observedWindows[ObjectIdentifier(window)] == nil {
            observedWindows[ObjectIdentifier(window)] = window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                [weak self] (_: UIWindow, _: UITraitCollection) in
                self?.systemStyleChanged()
            }
        }
    }

    private func systemStyleChanged() {
        guard followsSystem else { return }
        let resolved = windowStyle
        guard resolved != style else { return }
        style = resolved
        redrawAll()
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
    static func image(lines: [String], cols: Int, size: CGSize, style: UIUserInterfaceStyle) -> UIImage {
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

/// One terminal parsed off screen for its card: a Ghostty surface that is
/// never drawn, fed by its own attach stream.
@MainActor
final class HeadlessTerminal {
    let terminalId: String
    let client: HostClient
    let interval: Duration
    let onLines: ([String], (cols: Int, rows: Int)) -> Void

    private let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    private var ref: SurfaceRef?
    private let queue = DispatchQueue(label: "cmux.next.terminal.thumbnail", qos: .utility)
    private var task: Task<Void, Never>?
    private var streamId: UInt32?
    private var grid = (cols: 80, rows: 24)
    private var dirty = false
    private var rendering = false
    private var stopped = false

    init(terminalId: String, client: HostClient, interval: Duration, onLines: @escaping ([String], (cols: Int, rows: Int)) -> Void) {
        self.terminalId = terminalId
        self.client = client
        self.interval = interval
        self.onLines = onLines
    }

    func start() {
        guard let app = try? GhosttyApp.shared() else { return }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = 1
        config.font_size = 8
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        guard let surface = ghostty_surface_new(app.app, &config) else { return }
        ghostty_surface_set_occlusion(surface, false)
        ref = SurfaceRef(surface)
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

    private func setGrid(cols: Int, rows: Int) {
        guard let ref, let c = UInt16(exactly: cols), let r = UInt16(exactly: rows), c > 0, r > 0 else { return }
        grid = (cols, rows)
        queue.async { _ = ghostty_surface_set_grid(ref.surface, c, r, 1) }
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
        let grid = self.grid
        queue.async {
            let lines = Self.readLines(ref.surface, cols: grid.cols, rows: grid.rows)
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.onLines(lines, grid)
                do { try await Task.sleep(for: self.interval) } catch {}
                self.rendering = false
                self.renderIfIdle()
            }
        }
    }

    /// The viewport's rows as text (output queue only).
    nonisolated private static func readLines(_ surface: ghostty_surface_t, cols: Int, rows: Int) -> [String] {
        (0..<rows).map { row in
            var selection = ghostty_selection_s()
            selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row))
            selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                                     x: UInt32(max(0, cols - 1)), y: UInt32(row))
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
            defer { ghostty_surface_free_text(surface, &text) }
            guard let base = text.text, text.text_len > 0 else { return "" }
            let line = String(decoding: UnsafeRawBufferPointer(start: base, count: Int(text.text_len)), as: UTF8.self)
            return line.replacingOccurrences(of: "\n", with: "")
        }
    }
}
#endif
