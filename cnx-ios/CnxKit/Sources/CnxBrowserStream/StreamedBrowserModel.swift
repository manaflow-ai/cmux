import CnxTransport
import Foundation
import Observation
import os

private let log = Logger(subsystem: "dev.cmux.cnx", category: "browser-stream")

/// What a browser tab's toolbar shows and does, whether the page is a local
/// web view or a Mac browser streamed as video.
@MainActor
public protocol BrowserTabState: AnyObject {
    var url: URL? { get }
    var title: String { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isLoading: Bool { get }
    var progress: Double { get }
    var host: String { get }
    func goBack()
    func goForward()
    func reloadOrStop()
    func navigate(to text: String)
    func takeSnapshot()
}

extension BrowserTabState {
    /// A URL, a bare host, or a search.
    public static func url(for text: String) -> URL? {
        if text.isEmpty { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) { return url }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://\(text)") { return url }
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    static func displayHost(_ url: URL?) -> String {
        guard let host = url?.host() else { return url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A browser tab whose page runs on the Mac (its browser host, the CEF fork
/// the cmux-next app uses for remote tabs) and streams here as H.264 video
/// over the link's `browser` service. Touches, scrolls and typing go back as
/// `cmux.rb/1` input; `rb.page` drives the toolbar. The page is laid out at
/// this phone's size (`rb.open` / `rb.screen`).
@MainActor
@Observable
public final class StreamedBrowserModel: BrowserTabState {
    public enum Phase: Equatable, Sendable {
        case connecting
        case live
        case waiting(String)
        /// The Mac cannot stream browser tabs (its build has no browser host).
        case unavailable
    }

    public let tab: String
    public private(set) var url: URL?
    public private(set) var title = ""
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isLoading = false
    public var progress: Double { isLoading ? 0.5 : 1 }
    public private(set) var phase: Phase = .connecting
    /// The newest numbers for the overlay: frames per second, kbit/s,
    /// capture-to-decoded latency (median of the last second), decode time.
    public private(set) var meter = Meter()
    /// The last shown picture for the grid card.
    public private(set) var snapshot: CGImageBox?
    public var host: String { Self.displayHost(url) }

    @ObservationIgnored public let decoder = BrowserVideoDecoder()
    @ObservationIgnored let wire = RemoteBrowserWire()
    @ObservationIgnored private let open: @Sendable (_ sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection
    @ObservationIgnored private var connection: (any BrowserStreamConnection)?
    @ObservationIgnored private var sink: Sink?
    @ObservationIgnored private var screen: RemoteBrowserWire.Screen?
    @ObservationIgnored private var appliedScreen: RemoteBrowserWire.Screen?
    @ObservationIgnored private var screenSeq = 0
    @ObservationIgnored private var welcomed = false
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var samples: [Meter.Sample] = []

    public struct Meter: Equatable, Sendable {
        struct Sample: Equatable, Sendable {
            var at: UInt64
            var bytes: Int
            var latency: Int64?
            var decode: UInt32
        }

        public var fps = 0
        public var kbps = 0
        public var latencyMillis: Double?
        public var decodeMillis: Double = 0
        public var width: Int32 = 0
        public var height: Int32 = 0
        public var frames: UInt64 = 0
    }

    /// `open` opens the `browser` service on the current link.
    public init(tab: String, url: URL?, open: @escaping @Sendable (_ sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection) {
        self.tab = tab
        self.url = url
        self.open = open
        let decoder = decoder
        decoder.shown = { [weak self] shown in
            Task { @MainActor in self?.note(shown) }
        }
    }

    /// The page view's size changed (and on first layout): lays the page out
    /// at the phone's size, and connects when not yet connected.
    public func layout(points: CGSize, screenScale: Double) {
        guard points.width > 10, points.height > 10 else { return }
        let next = RemoteBrowserWire.Screen(points: points, screenScale: screenScale)
        guard next != screen else { return }
        screen = next
        sendScreen()
        connect()
    }

    /// Connects when there is no stream (first layout, a new link).
    public func connect() {
        guard connection == nil, !connecting, screen != nil else { return }
        connecting = true
        phase = .connecting
        let sink = Sink(model: self)
        self.sink = sink
        let open = open
        let tab = tab
        // task-owner: one dial per connect; the result lands on the main actor
        Task { [weak self] in
            do {
                let connection = try await open(sink)
                self?.opened(connection, sink: sink)
            } catch {
                log.error("browser \(tab, privacy: .public): \(String(describing: error), privacy: .public)")
                if LinkErrorText.noBrowserHost(error) {
                    self?.unavailable()
                } else {
                    self?.failed(LinkErrorText.describe(error))
                }
            }
        }
    }

    /// The link changed: a dropped stream comes back on the new link.
    public func reconnect() {
        if connection == nil { connect() }
    }

    public func close() {
        connection?.close()
        connection = nil
        sink = nil
    }

    private func opened(_ connection: any BrowserStreamConnection, sink: Sink) {
        connecting = false
        guard self.sink === sink else {
            connection.close()
            return
        }
        self.connection = connection
        welcomed = false
        let decoder = decoder
        decoder.requestKeyframe = { [weak connection] in connection?.requestKeyframe() }
        decoder.now = { [weak connection] in connection?.nowMicros() ?? 0 }
        decoder.reset()
    }

    private func unavailable() {
        connecting = false
        sink = nil
        phase = .unavailable
    }

    private func failed(_ reason: String) {
        connecting = false
        sink = nil
        phase = .waiting(reason)
    }

    fileprivate func received(_ json: [String: Any], from sink: Sink) {
        guard sink === self.sink else { return }
        switch json["t"] as? String {
        case "welcome":
            welcomed = true
            appliedScreen = nil
            if let screen, let connection {
                screenSeq = 0
                try? connection.send(message: wire.open(tab: tab, viewer: "phone", screen: screen))
            }
        case "refused", "ended":
            phase = .waiting(json["reason"] as? String ?? "The Mac ended the page")
        case "rb.page":
            guard let page = RemoteBrowserPage(json: json) else { return }
            if let next = URL(string: page.url), !page.url.isEmpty { url = next }
            title = page.title
            isLoading = page.loading
            canGoBack = page.canGoBack
            canGoForward = page.canGoForward
        case "rb.screen_applied":
            phase = .live
        default:
            break
        }
    }

    fileprivate func closed(code: String, reason: String, from sink: Sink) {
        guard sink === self.sink else { return }
        connection = nil
        self.sink = nil
        decoder.reset()
        phase = .waiting(code == "unavailable" || code == "forbidden" ? reason : "Reconnecting to the Mac…")
        log.info("browser \(self.tab, privacy: .public) closed: \(code, privacy: .public) \(reason, privacy: .public)")
        // A replaced or dropped stream reconnects when the link does.
    }

    private func sendScreen() {
        guard welcomed, let screen, let connection else { return }
        screenSeq += 1
        try? connection.send(message: wire.screen(seq: screenSeq, screen))
    }

    private func note(_ shown: BrowserVideoDecoder.Shown) {
        if phase != .live { phase = .live }
        let now = connection?.nowMicros() ?? 0
        samples.append(.init(at: now, bytes: shown.bytes, latency: shown.latencyMicros, decode: shown.decodeMicros))
        samples.removeAll { now &- $0.at > 1_000_000 }
        var meter = Meter()
        meter.fps = samples.count
        meter.kbps = samples.reduce(0) { $0 + $1.bytes } * 8 / 1000
        let latencies = samples.compactMap(\.latency).sorted()
        meter.latencyMillis = latencies.isEmpty ? nil : Double(latencies[latencies.count / 2]) / 1000
        meter.decodeMillis = Double(samples.map(\.decode).reduce(0, +)) / Double(max(1, samples.count)) / 1000
        meter.width = shown.width
        meter.height = shown.height
        meter.frames = self.meter.frames + 1
        self.meter = meter
        if meter.frames % 30 == 1 {
            log.info("browser \(self.tab, privacy: .public): \(meter.fps) fps \(meter.kbps) kbps latency \(meter.latencyMillis ?? -1, format: .fixed(precision: 1)) ms decode \(meter.decodeMillis, format: .fixed(precision: 1)) ms \(meter.width)x\(meter.height)")
        }
    }

    // MARK: Toolbar

    public func goBack() { send(wire.history("back")) }
    public func goForward() { send(wire.history("forward")) }
    public func reloadOrStop() { send(wire.history(isLoading ? "stop" : "reload")) }

    public func navigate(to text: String) {
        guard let target = Self.url(for: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        url = target
        send(wire.navigate(target.absoluteString))
    }

    public func takeSnapshot() {
        decoder.lastPicture { [weak self] pixels in
            guard let pixels, let image = CGImageBox(pixels) else { return }
            Task { @MainActor in self?.snapshot = image }
        }
    }

    // MARK: Input (CSS pixels)

    func send(_ message: Data) {
        try? connection?.send(message: message)
    }

    func input(_ event: Data, mustDeliver: Bool = true) {
        try? connection?.send(input: event, mustDeliver: mustDeliver)
    }

    /// The CSS pixel under a point of a view of `size` points.
    func css(_ point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        let screen = screen ?? RemoteBrowserWire.Screen(points: size, screenScale: 2)
        return (Double(point.x / max(1, size.width)) * Double(screen.cssWidth),
                Double(point.y / max(1, size.height)) * Double(screen.cssHeight))
    }
}

/// Receives on a library thread and hops to the model.
final class Sink: BrowserStreamSink, @unchecked Sendable {
    weak var model: StreamedBrowserModel?
    private let decoder: BrowserVideoDecoder

    @MainActor init(model: StreamedBrowserModel) {
        self.model = model
        decoder = model.decoder
    }

    func browserFrame(_ frame: BrowserStreamFrame) {
        guard frame.stream == 0 else { return }
        decoder.submit(frame: frame.frame, accessUnit: frame.accessUnit, keyframe: frame.keyframe,
                       receivedMicros: frame.receivedMicros, ageMicros: frame.ageMicros)
    }

    func browserMessage(_ json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
        nonisolated(unsafe) let message = object
        Task { @MainActor [weak self] in
            guard let self, let model = self.model else { return }
            model.received(message, from: self)
        }
    }

    func browserClosed(code: String, reason: String) {
        Task { @MainActor [weak self] in
            guard let self, let model = self.model else { return }
            model.closed(code: code, reason: reason, from: self)
        }
    }
}

/// A decoded picture as a `CGImage` (grid cards).
public final class CGImageBox: @unchecked Sendable, Equatable {
    public let image: CGImage

    init?(_ pixels: CVPixelBuffer) {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return nil }
        self.image = image
    }

    public static func == (lhs: CGImageBox, rhs: CGImageBox) -> Bool { lhs === rhs }
}

enum LinkErrorText {
    /// The Mac has no browser host: cnx-hostd's `no_browser_host`, or an older
    /// Mac's "this build has no browser host" (never shown as is).
    static func noBrowserHost(_ error: any Error) -> Bool {
        guard let error = error as? LinkError else { return false }
        return error.code == "no_browser_host" || error.message.localizedCaseInsensitiveContains("no browser host")
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? LinkError {
            if error.code == "no-link" { return "Not connected to the Mac" }
            return error.message.isEmpty ? error.code : error.message
        }
        return String(describing: error)
    }
}

import VideoToolbox
