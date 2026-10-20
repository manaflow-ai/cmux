#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// The live page of a streamed browser tab: the Mac's frames, laid out
/// between the status bar and the tab toolbar at this phone's size, with
/// touch, scroll, pinch and typing going back to the page.
public struct StreamedBrowserPage: View {
    let model: StreamedBrowserModel
    var insets: EdgeInsets
    var reportScroll: @MainActor (CGFloat) -> Void
    @State private var keyboard = false
    @Environment(\.openURL) private var openURL

    /// What the page says when the Mac cannot stream browser tabs.
    public static let unavailableText = String(localized: "Browser tabs aren't available from this Mac yet.")

    public init(model: StreamedBrowserModel, insets: EdgeInsets, reportScroll: @escaping @MainActor (CGFloat) -> Void) {
        self.model = model
        self.insets = insets
        self.reportScroll = reportScroll
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            StreamSurface(model: model, keyboard: $keyboard, reportScroll: reportScroll)
                .accessibilityIdentifier("browser.stream")
            if model.phase == .unavailable {
                unavailable
            } else if case let .waiting(reason) = model.phase {
                status(reason)
            } else if model.phase == .connecting {
                status("Opening on your Mac…")
            }
            Button {
                keyboard.toggle()
            } label: {
                Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(12)
            .accessibilityIdentifier("browser.keyboard")
            if StreamedBrowserOverlay.enabled {
                StreamedBrowserOverlay(model: model)
                    // Bottom left, clear of the page's own top area (a page clock).
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }
        }
        .padding(.top, insets.top)
        .padding(.bottom, insets.bottom)
        .background(Color.black)
        .onAppear {
            model.setVisible(true)
            model.reconnect()
        }
        .onDisappear { model.setVisible(false) }
    }

    /// An honest state, with the page in Safari on this iPhone when it has a web address.
    private var unavailable: some View {
        VStack(spacing: 12) {
            Text(Self.unavailableText)
                .font(.callout)
                .multilineTextAlignment(.center)
            if let url = model.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Button("Open in Safari") { openURL(url) }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("browser.openInSafari")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("browser.unavailable")
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The measurement overlay (DEBUG, or `-cnx-browser-meter`): frame rate,
/// bitrate, capture-to-decoded latency, decode time, and this phone's wall
/// clock in milliseconds to compare with a clock rendered by the Mac's page.
struct StreamedBrowserOverlay: View {
    let model: StreamedBrowserModel

    static var enabled: Bool {
        #if DEBUG
        true
        #else
        // Release (Production, TestFlight): only for a measurement launch with
        // the explicit argument, never from a stored setting (Codex QA F13).
        ProcessInfo.processInfo.arguments.contains("-cnx-browser-meter")
        #endif
    }

    var body: some View {
        TimelineView(.animation) { context in
            let meter = model.meter
            VStack(alignment: .leading, spacing: 1) {
                Text("phone \(Self.clock(context.date))")
                Text("\(meter.fps) fps · \(meter.kbps) kbps · \(meter.width)×\(meter.height) · \(meter.carrier)")
                Text("latency \(meter.latencyMillis.map { String(format: "%.0f", $0) } ?? "–") ms · decode \(String(format: "%.1f", meter.decodeMillis)) ms")
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
            .padding(6)
            .accessibilityIdentifier("browser.meter")
        }
    }

    static func clock(_ date: Date) -> String {
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        return String(format: "%02d:%02d.%03d", (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

/// The grid card: the last frame, else a globe.
public struct StreamedBrowserCard: View {
    let model: StreamedBrowserModel

    public init(model: StreamedBrowserModel) { self.model = model }

    public var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            if let image = model.snapshot?.image {
                GeometryReader { geo in
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                        .frame(width: geo.size.width,
                               height: geo.size.width * CGFloat(image.height) / CGFloat(max(1, image.width)))
                }
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct StreamSurface: UIViewRepresentable {
    let model: StreamedBrowserModel
    @Binding var keyboard: Bool
    var reportScroll: @MainActor (CGFloat) -> Void

    func makeUIView(context: Context) -> StreamView {
        let view = StreamView(model: model)
        view.keyboardChanged = { shown in
            if keyboard != shown { keyboard = shown }
        }
        return view
    }

    func updateUIView(_ view: StreamView, context: Context) {
        view.reportScroll = reportScroll
        if keyboard, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !keyboard, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

/// Shows the decoder's layer and turns touches into rb input (CSS pixels).
final class StreamView: UIView, UIKeyInput {
    let model: StreamedBrowserModel
    var reportScroll: (@MainActor (CGFloat) -> Void)?
    var keyboardChanged: ((Bool) -> Void)?
    private let video: AVSampleBufferDisplayLayer
    private var lastPan: CGPoint = .zero
    private var momentum: CADisplayLink?
    private var velocity: CGPoint = .zero
    private var momentumAt: CGPoint = .zero
    private var lastStep: CFTimeInterval = 0

    init(model: StreamedBrowserModel) {
        self.model = model
        video = model.decoder.layer
        super.init(frame: .zero)
        backgroundColor = .black
        video.removeFromSuperlayer()
        layer.addSublayer(video)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(tap)
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityIdentifier = "browser.page"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
        model.layout(points: bounds.size, screenScale: Double(window?.screen.scale ?? traitCollection.displayScale))
    }

    private func css(_ point: CGPoint) -> (x: Double, y: Double) { model.css(point, in: bounds.size) }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        let (x, y) = css(gesture.location(in: self))
        model.input(model.wire.pointer("move", x: x, y: y, buttons: 0), mustDeliver: false)
        model.input(model.wire.pointer("down", x: x, y: y, buttons: 1))
        model.input(model.wire.pointer("up", x: x, y: y, buttons: 0))
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let at = css(gesture.location(in: self))
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            stopMomentum()
            lastPan = translation
            model.input(model.wire.wheel(x: at.x, y: at.y, dx: 0, dy: 0, phase: "began", momentum: "none"))
        case .changed:
            let dx = translation.x - lastPan.x
            let dy = translation.y - lastPan.y
            lastPan = translation
            model.input(model.wire.wheel(x: at.x, y: at.y, dx: dx, dy: dy, phase: "changed", momentum: "none"), mustDeliver: false)
            reportScroll?(dy)
        case .ended, .cancelled, .failed:
            model.input(model.wire.wheel(x: at.x, y: at.y, dx: 0, dy: 0, phase: "ended", momentum: "none"))
            let v = gesture.velocity(in: self)
            if gesture.state == .ended, hypot(v.x, v.y) > 200 { startMomentum(velocity: v, at: CGPoint(x: at.x, y: at.y)) }
        default:
            break
        }
    }

    /// The fling after a pan, as macOS momentum wheel events (decay 0.95 per 1/60 s).
    private func startMomentum(velocity: CGPoint, at: CGPoint) {
        self.velocity = velocity
        momentumAt = at
        lastStep = CACurrentMediaTime()
        model.input(model.wire.wheel(x: at.x, y: at.y, dx: 0, dy: 0, phase: "none", momentum: "began"))
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = max(0, min(0.05, now - lastStep))
        lastStep = now
        let decay = pow(0.95, dt * 60)
        velocity = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
        if hypot(velocity.x, velocity.y) < 20 {
            stopMomentum()
            return
        }
        model.input(model.wire.wheel(x: momentumAt.x, y: momentumAt.y, dx: velocity.x * dt, dy: velocity.y * dt,
                                     phase: "none", momentum: "changed"), mustDeliver: false)
    }

    private func stopMomentum() {
        guard let link = momentum else { return }
        link.invalidate()
        momentum = nil
        model.input(model.wire.wheel(x: momentumAt.x, y: momentumAt.y, dx: 0, dy: 0, phase: "none", momentum: "ended"))
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let (x, y) = css(gesture.location(in: self))
        let phase: String = switch gesture.state {
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        default: "cancelled"
        }
        model.input(model.wire.pinch(phase: phase, scale: gesture.scale, x: x, y: y), mustDeliver: phase != "changed")
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { keyboardChanged?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keyboardChanged?(false) }
        return resigned
    }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var keyboardType: UIKeyboardType { get { .default } set {} }

    func insertText(_ text: String) {
        if text == "\n" {
            key("Enter", key: "Enter", text: "\r")
        } else if text == "\t" {
            key("Tab", key: "Tab", text: "\t")
        } else {
            model.input(model.wire.commit(text))
        }
    }

    func deleteBackward() { key("Backspace", key: "Backspace") }

    private func key(_ code: String, key: String, text: String = "") {
        model.input(model.wire.key(code, key: key, text: text, down: true))
        model.input(model.wire.key(code, key: key, text: text, down: false))
    }
}
#endif
