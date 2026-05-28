import QuartzCore
import SwiftUI
import UIKit
import GhosttyKit

public struct TerminalGridSize: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

@MainActor
public protocol GhosttyTerminalSurfaceViewDelegate: AnyObject {
    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didProduceInput data: Data)
    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didResize size: TerminalGridSize)
}

private func cmuxHarnessReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyRuntime.handleReadClipboard(userdata, location: location, state: state)
}

@MainActor
public final class GhosttyRuntime {
    public enum RuntimeError: LocalizedError {
        case backendInitFailed(code: Int32)
        case appCreationFailed

        public var errorDescription: String? {
            switch self {
            case .backendInitFailed(let code):
                String(
                    format: String(
                        localized: "ios.terminal.ghostty.initFailed",
                        defaultValue: "libghostty initialization failed (%d)"
                    ),
                    Int(code)
                )
            case .appCreationFailed:
                String(
                    localized: "ios.terminal.ghostty.appCreationFailed",
                    defaultValue: "libghostty app creation failed"
                )
            }
        }
    }

    private static var backendInitialized = false
    private static var sharedResult: Result<GhosttyRuntime, Error>?

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    public static func shared() throws -> GhosttyRuntime {
        if let sharedResult {
            return try sharedResult.get()
        }

        let result: Result<GhosttyRuntime, Error>
        do {
            result = .success(try GhosttyRuntime())
        } catch {
            result = .failure(error)
        }
        sharedResult = result
        return try result.get()
    }

    init() throws {
        Self.setupRuntimeEnvironment()
        try Self.initializeBackendIfNeeded()

        let config = ghostty_config_new()
        Self.loadConfig(config)
        ghostty_config_finalize(config)

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = { _ in
            Task { @MainActor in
                GhosttyTerminalSurfaceView.drawVisibleSurfacesForWakeup()
            }
        }
        runtimeConfig.action_cb = { _, target, action in
            GhosttyRuntime.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = cmuxHarnessReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.write_clipboard_cb = { _, _, content, len, _ in
            guard let content, len > 0 else { return }
            for index in 0..<len {
                let item = content[index]
                guard let mime = item.mime,
                      String(cString: mime) == "text/plain",
                      let data = item.data else { continue }
                UIPasteboard.general.string = String(cString: data)
                return
            }
        }
        runtimeConfig.close_surface_cb = { userdata, _ in
            GhosttySurfaceBridge.fromOpaque(userdata)?.detach()
        }

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            throw RuntimeError.appCreationFailed
        }

        self.config = config
        self.app = app
    }

    isolated deinit {
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }

    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private static func initializeBackendIfNeeded() throws {
        guard !backendInitialized else { return }
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            throw RuntimeError.backendInitFailed(code: result)
        }
        backendInitialized = true
    }

    private static func loadConfig(_ config: ghostty_config_t?) {
        guard let config else { return }
        Self.setupRuntimeEnvironment()
        let theme = """
        font-family = Menlo
        font-size = 10
        window-padding-balance = false
        window-padding-y = 0
        cursor-style = bar
        cursor-style-blink = true
        background = #272822
        foreground = #fdfff1
        cursor-color = #c0c1b5
        selection-background = #57584f
        selection-foreground = #fdfff1
        palette = 0=#272822
        palette = 1=#f92672
        palette = 2=#a6e22e
        palette = 3=#e6db74
        palette = 4=#fd971f
        palette = 5=#ae81ff
        palette = 6=#66d9ef
        palette = 7=#fdfff1
        palette = 8=#6e7066
        palette = 9=#f92672
        palette = 10=#a6e22e
        palette = 11=#e6db74
        palette = 12=#fd971f
        palette = 13=#ae81ff
        palette = 14=#66d9ef
        palette = 15=#fdfff1
        """
        theme.withCString { themePointer in
            "cmux-ios-defaults".withCString { namePointer in
                ghostty_config_load_string(config, themePointer, UInt(theme.utf8.count), namePointer)
            }
        }
    }

    private static func setupRuntimeEnvironment() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        setenv("HOME", appSupport.path, 1)
        setenv("XDG_CONFIG_HOME", appSupport.path, 1)
        setenv("XDG_CACHE_HOME", appSupport.path, 1)
        setenv("XDG_STATE_HOME", appSupport.path, 1)
    }

    nonisolated fileprivate static func handleAction(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        if action.tag == GHOSTTY_ACTION_OPEN_URL {
            let payload = action.action.open_url
            guard let urlPointer = payload.url else { return false }
            let data = Data(bytes: urlPointer, count: Int(payload.len))
            guard let value = String(data: data, encoding: .utf8),
                  let url = URL(string: value) else { return false }
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
            return true
        }

        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else { return false }

        if action.tag == GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD {
            Task { @MainActor in
                GhosttyTerminalSurfaceView.view(for: surface)?.focusInput()
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_SET_TITLE,
           let title = action.action.set_title.title {
            Task { @MainActor in
                GhosttyTerminalSurfaceView.view(for: surface)?.title = String(cString: title)
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_RING_BELL {
            Task { @MainActor in
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            return true
        }

        return false
    }

    nonisolated fileprivate static func handleReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        false
    }
}

final class GhosttySurfaceBridge {
    weak var surfaceView: GhosttyTerminalSurfaceView?

    func attach(to surfaceView: GhosttyTerminalSurfaceView) {
        self.surfaceView = surfaceView
    }

    func detach() {
        surfaceView = nil
    }

    static func fromOpaque(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceBridge? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
    }
}

private enum GhosttySurfaceDisposer {
    static let queue = DispatchQueue(label: "GhosttySurfaceDisposer.queue")

    static func dispose(surface: ghostty_surface_t, bridge: GhosttySurfaceBridge) {
        let retainedBridge = Unmanaged.passRetained(bridge)
        let retainedBridgeBits = UInt(bitPattern: retainedBridge.toOpaque())
        let surfaceBits = UInt(bitPattern: UnsafeRawPointer(surface))
        queue.async {
            let retainedBridge = Unmanaged<GhosttySurfaceBridge>.fromOpaque(
                UnsafeRawPointer(bitPattern: retainedBridgeBits)!
            )
            let surface = UnsafeMutableRawPointer(bitPattern: surfaceBits)!
            ghostty_surface_free(surface)
            retainedBridge.release()
        }
    }
}

@MainActor
public final class GhosttyTerminalSurfaceView: UIView {
    private weak var runtime: GhosttyRuntime?
    private weak var delegate: GhosttyTerminalSurfaceViewDelegate?
    private let bridge = GhosttySurfaceBridge()
    private var displayLink: CADisplayLink?
    private var lastReportedSize: TerminalGridSize?
    private var hasFedInitialOutput = false
    public private(set) var surface: ghostty_surface_t?
    public var title: String?

    private lazy var inputProxy: GhosttyInputTextView = {
        let textView = GhosttyInputTextView()
        textView.onText = { [weak self] text in
            guard let self else { return }
            let normalized = text.replacingOccurrences(of: "\n", with: "\r")
            self.delegate?.ghosttyTerminalSurfaceView(self, didProduceInput: Data(normalized.utf8))
        }
        textView.onBackspace = { [weak self] in
            guard let self else { return }
            self.delegate?.ghosttyTerminalSurfaceView(self, didProduceInput: Data([0x7f]))
        }
        return textView
    }()

    public init(runtime: GhosttyRuntime, delegate: GhosttyTerminalSurfaceViewDelegate) {
        self.runtime = runtime
        self.delegate = delegate
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
        bridge.attach(to: self)
        backgroundColor = .black
        isOpaque = true
        isAccessibilityElement = true
        accessibilityIdentifier = "terminal.surface"
        addSubview(inputProxy)
        initializeSurface()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focusInput)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        disposeSurface()
    }

    public override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        inputProxy.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        syncSurfaceGeometry()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            syncSurfaceGeometry()
            ghostty_surface_set_occlusion(surface, true)
            ghostty_surface_set_focus(surface, true)
            startDisplayLink()
        } else {
            ghostty_surface_set_focus(surface, false)
            ghostty_surface_set_occlusion(surface, false)
            stopDisplayLink()
        }
    }

    public func processOutput(_ data: Data) {
        guard let surface else { return }
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ghostty_surface_process_output(
                surface,
                baseAddress.assumingMemoryBound(to: CChar.self),
                UInt(buffer.count)
            )
        }
        hasFedInitialOutput = true
        ghostty_surface_render_now(surface)
        accessibilityValue = accessibilityRenderedTextForTesting()
    }

    public func applyViewSize(cols: Int, rows: Int) {
        guard let surface,
              cols > 0,
              rows > 0 else { return }
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        ghostty_surface_set_size(surface, UInt32(cols * cellWidth), UInt32(rows * cellHeight))
        syncSurfaceGeometry(reportResize: false)
    }

    @objc public func focusInput() {
        inputProxy.becomeFirstResponder()
    }

    public func simulateTextInputForTesting(_ text: String) {
        inputProxy.insertText(text)
    }

    public func renderedTextForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let pointer = text.text, text.text_len > 0 else {
            return ""
        }
        return String(decoding: Data(bytes: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    public func accessibilityRenderedTextForTesting() -> String? {
        let candidates = [
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SURFACE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SCREEN),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_ACTIVE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT),
        ].compactMap { $0 }

        return candidates.max { lhs, rhs in
            lhs.utf8.count < rhs.utf8.count
        }
    }

    public func disposeSurface() {
        stopDisplayLink()
        guard let surface else { return }
        Self.unregister(surface: surface)
        self.surface = nil
        bridge.detach()
        GhosttySurfaceDisposer.dispose(surface: surface, bridge: bridge)
    }

    private func initializeSurface() {
        guard let app = runtime?.app else { return }
        var surfaceConfig = ghostty_surface_config_new()
        let bridgePointer = Unmanaged.passUnretained(bridge).toOpaque()
        surfaceConfig.userdata = bridgePointer
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque())
        )
        surfaceConfig.scale_factor = screenScale
        surfaceConfig.font_size = 10
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = { userdata, buffer, length in
            guard let userdata, let buffer, length > 0 else { return }
            let data = Data(bytes: buffer, count: Int(length))
            Task { @MainActor in
                GhosttySurfaceBridge.fromOpaque(userdata)?.surfaceView?.handleOutboundBytes(data)
            }
        }
        surfaceConfig.io_write_userdata = bridgePointer
        surface = ghostty_surface_new(app, &surfaceConfig)
        if let surface {
            GhosttyTerminalSurfaceView.register(surface: surface, for: self)
            applyConfiguredBackground()
            syncSurfaceGeometry()
        }
    }

    private func handleOutboundBytes(_ data: Data) {
        delegate?.ghosttyTerminalSurfaceView(self, didProduceInput: data)
    }

    private var screenScale: CGFloat {
        window?.windowScene?.screen.scale ?? traitCollection.displayScale.nonZero ?? 2
    }

    private func syncSurfaceGeometry(reportResize: Bool = true) {
        guard let surface else { return }
        let scale = screenScale
        let width = UInt32(max(1, Int((max(bounds.width, 1) * scale).rounded(.down))))
        let height = UInt32(max(1, Int((max(bounds.height, 1) * scale).rounded(.down))))
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, width, height)
        let size = ghostty_surface_size(surface)
        let gridSize = TerminalGridSize(
            columns: Int(size.columns),
            rows: Int(size.rows),
            pixelWidth: Int(size.width_px),
            pixelHeight: Int(size.height_px)
        )
        if reportResize, gridSize != lastReportedSize {
            lastReportedSize = gridSize
            delegate?.ghosttyTerminalSurfaceView(self, didResize: gridSize)
        }
        for sublayer in layer.sublayers ?? [] where String(describing: type(of: sublayer)) == "IOSurfaceLayer" {
            sublayer.frame = bounds
            sublayer.bounds = CGRect(origin: .zero, size: bounds.size)
            sublayer.contentsScale = scale
        }
        if hasFedInitialOutput {
            ghostty_surface_render_now(surface)
        }
    }

    private func applyConfiguredBackground() {
        guard let config = runtime?.config else { return }
        var color = ghostty_config_color_s()
        let key = "background"
        if ghostty_config_get(config, &color, key, UInt(key.utf8.count)) {
            backgroundColor = UIColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1
            )
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleDisplayLink() {
        guard let surface else { return }
        ghostty_surface_render_now(surface)
    }

    @MainActor
    static func drawVisibleSurfacesForWakeup() {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        for view in registeredSurfaceViews.values.compactMap(\.value) where view.window != nil {
            view.runtime?.tick()
            if let surface = view.surface {
                ghostty_surface_refresh(surface)
            }
        }
    }
}

private final class WeakGhosttySurfaceViewBox {
    weak var value: GhosttyTerminalSurfaceView?

    init(_ value: GhosttyTerminalSurfaceView) {
        self.value = value
    }
}

private extension GhosttyTerminalSurfaceView {
    @MainActor
    static var registeredSurfaceViews: [UInt: WeakGhosttySurfaceViewBox] = [:]

    @MainActor
    static func register(surface: ghostty_surface_t, for view: GhosttyTerminalSurfaceView) {
        registeredSurfaceViews[surfaceIdentifier(for: surface)] = WeakGhosttySurfaceViewBox(view)
    }

    @MainActor
    static func unregister(surface: ghostty_surface_t) {
        registeredSurfaceViews.removeValue(forKey: surfaceIdentifier(for: surface))
    }

    @MainActor
    static func view(for surface: ghostty_surface_t) -> GhosttyTerminalSurfaceView? {
        registeredSurfaceViews[surfaceIdentifier(for: surface)]?.value
    }

    static func surfaceIdentifier(for surface: ghostty_surface_t) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(surface))
    }
}

private final class GhosttyInputTextView: UITextView {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardType = .default
        textContainerInset = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        onText?(text)
    }

    override func deleteBackward() {
        onBackspace?()
    }
}

private extension CGFloat {
    var nonZero: CGFloat? {
        self > 0 ? self : nil
    }
}

private final class PreviewGhosttySurfaceDelegate: GhosttyTerminalSurfaceViewDelegate {
    var producedInput: [Data] = []
    var resizeEvents: [TerminalGridSize] = []

    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didProduceInput data: Data) {
        producedInput.append(data)
    }

    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didResize size: TerminalGridSize) {
        resizeEvents.append(size)
    }
}

public struct GhosttyTerminalRepresentable: UIViewRepresentable {
    let terminal: CmuxMobileTerminal

    public init(terminal: CmuxMobileTerminal) {
        self.terminal = terminal
    }

    @MainActor
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    public func makeUIView(context: Context) -> UIView {
        do {
            let surfaceView = GhosttyTerminalSurfaceView(
                runtime: try GhosttyRuntime.shared(),
                delegate: context.coordinator.delegate
            )
            context.coordinator.render(terminal, into: surfaceView)
            return surfaceView
        } catch {
            let fallback = UILabel()
            fallback.backgroundColor = .black
            fallback.textColor = .white
            fallback.numberOfLines = 0
            fallback.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            fallback.text = String(
                localized: "ios.terminal.ghostty.renderFailed",
                defaultValue: "libghostty failed to start"
            )
            fallback.isAccessibilityElement = true
            fallback.accessibilityIdentifier = "terminal.surface"
            fallback.accessibilityValue = "libghostty failed: \(error.localizedDescription)"
            return fallback
        }
    }

    @MainActor
    public func updateUIView(_ view: UIView, context: Context) {
        guard let surfaceView = view as? GhosttyTerminalSurfaceView else { return }
        context.coordinator.render(terminal, into: surfaceView)
    }

    @MainActor
    public final class Coordinator {
        fileprivate let delegate = PreviewGhosttySurfaceDelegate()
        private var renderedTerminalID: String?

        fileprivate func render(_ terminal: CmuxMobileTerminal, into surfaceView: GhosttyTerminalSurfaceView) {
            guard renderedTerminalID != terminal.id else { return }
            renderedTerminalID = terminal.id
            surfaceView.applyViewSize(cols: terminal.size.cols, rows: terminal.size.rows)
            surfaceView.processOutput(Data((terminal.rows.joined(separator: "\r\n") + "\r\n").utf8))
        }
    }
}

public struct LiveGhosttyTerminalRepresentable: UIViewRepresentable {
    @ObservedObject var store: ComeupLiveTerminalStore
    let initialSize: CmuxTerminalSize

    public init(store: ComeupLiveTerminalStore, initialSize: CmuxTerminalSize) {
        self.store = store
        self.initialSize = initialSize
    }

    @MainActor
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    public func makeUIView(context: Context) -> UIView {
        do {
            let surfaceView = GhosttyTerminalSurfaceView(
                runtime: try GhosttyRuntime.shared(),
                delegate: store
            )
            surfaceView.applyViewSize(cols: initialSize.cols, rows: initialSize.rows)
            return surfaceView
        } catch {
            let fallback = UILabel()
            fallback.backgroundColor = .black
            fallback.textColor = .white
            fallback.numberOfLines = 0
            fallback.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            fallback.text = String(
                localized: "ios.terminal.ghostty.renderFailed",
                defaultValue: "libghostty failed to start"
            )
            fallback.isAccessibilityElement = true
            fallback.accessibilityIdentifier = "terminal.surface"
            fallback.accessibilityValue = "libghostty failed: \(error.localizedDescription)"
            return fallback
        }
    }

    @MainActor
    public func updateUIView(_ view: UIView, context: Context) {
        guard let surfaceView = view as? GhosttyTerminalSurfaceView else { return }
        if context.coordinator.lastAppliedSize != store.size {
            context.coordinator.lastAppliedSize = store.size
            surfaceView.applyViewSize(cols: store.size.cols, rows: store.size.rows)
        }
        for chunk in store.outputChunks where chunk.id > context.coordinator.lastAppliedOutputID {
            surfaceView.processOutput(chunk.data)
            context.coordinator.lastAppliedOutputID = chunk.id
        }
    }

    @MainActor
    public final class Coordinator {
        var lastAppliedOutputID = 0
        var lastAppliedSize: CmuxTerminalSize?
    }
}
