import OSLog
import QuartzCore
import SwiftUI
import UIKit

#if DEBUG
private let cmxGhosttySurfaceLogger = Logger(subsystem: "dev.cmux.ios", category: "ghostty-surface")

private func cmuxDebugLog(_ message: String) {
    cmxGhosttySurfaceLogger.debug("\(message, privacy: .public)")
}
#endif

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

public enum TerminalFontZoomDirection: Equatable {
    case decrease
    case increase

    func bindingAction(delta: Float32) -> String {
        // Keep this on Ghostty's native relative zoom actions so upstream owns
        // font metric invalidation as it does for desktop shortcuts.
        switch self {
        case .decrease:
            "decrease_font_size:\(delta)"
        case .increase:
            "increase_font_size:\(delta)"
        }
    }
}

public enum TerminalInputAccessoryAction: Int, CaseIterable {
    case hideKeyboard
    case control
    case alternate
    case command
    case shift
    case zoomOut
    case zoomIn
    case escape
    case tab
    case enter
    case backspace
    case deleteForward
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case home
    case end
    case pageUp
    case pageDown
    case tilde
    case pipe
    case ctrlC
    case ctrlD
    case ctrlZ
    case ctrlL

    var title: String {
        title(isMacRemote: false)
    }

    func title(isMacRemote: Bool) -> String {
        switch self {
        case .hideKeyboard:
            ""
        case .control:
            isMacRemote ? "⌃" : String(localized: "ios.terminal.inputAccessory.control", defaultValue: "Ctrl")
        case .alternate:
            isMacRemote ? "⌥" : String(localized: "ios.terminal.inputAccessory.alt", defaultValue: "Alt")
        case .command:
            "⌘"
        case .shift:
            "⇧"
        case .zoomOut, .zoomIn:
            ""
        case .escape:
            String(localized: "ios.terminal.inputAccessory.escape", defaultValue: "Esc")
        case .tab:
            String(localized: "ios.terminal.inputAccessory.tab", defaultValue: "Tab")
        case .enter:
            String(localized: "ios.terminal.inputAccessory.enter", defaultValue: "Enter")
        case .backspace:
            "⌫"
        case .deleteForward:
            "⌦"
        case .upArrow:
            "↑"
        case .downArrow:
            "↓"
        case .leftArrow:
            "←"
        case .rightArrow:
            "→"
        case .home:
            String(localized: "ios.terminal.inputAccessory.home", defaultValue: "Home")
        case .end:
            String(localized: "ios.terminal.inputAccessory.end", defaultValue: "End")
        case .pageUp:
            String(localized: "ios.terminal.inputAccessory.pageUp", defaultValue: "PgUp")
        case .pageDown:
            String(localized: "ios.terminal.inputAccessory.pageDown", defaultValue: "PgDn")
        case .tilde:
            "~"
        case .pipe:
            "|"
        case .ctrlC:
            String(localized: "ios.terminal.inputAccessory.ctrlC", defaultValue: "^C")
        case .ctrlD:
            String(localized: "ios.terminal.inputAccessory.ctrlD", defaultValue: "^D")
        case .ctrlZ:
            String(localized: "ios.terminal.inputAccessory.ctrlZ", defaultValue: "^Z")
        case .ctrlL:
            String(localized: "ios.terminal.inputAccessory.ctrlL", defaultValue: "^L")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .hideKeyboard: "terminal.inputAccessory.hideKeyboard"
        case .control: "terminal.inputAccessory.control"
        case .alternate: "terminal.inputAccessory.alt"
        case .command: "terminal.inputAccessory.command"
        case .shift: "terminal.inputAccessory.shift"
        case .zoomOut: "terminal.inputAccessory.zoomOut"
        case .zoomIn: "terminal.inputAccessory.zoomIn"
        case .escape: "terminal.inputAccessory.escape"
        case .tab: "terminal.inputAccessory.tab"
        case .enter: "terminal.inputAccessory.enter"
        case .backspace: "terminal.inputAccessory.backspace"
        case .deleteForward: "terminal.inputAccessory.deleteForward"
        case .upArrow: "terminal.inputAccessory.up"
        case .downArrow: "terminal.inputAccessory.down"
        case .leftArrow: "terminal.inputAccessory.left"
        case .rightArrow: "terminal.inputAccessory.right"
        case .home: "terminal.inputAccessory.home"
        case .end: "terminal.inputAccessory.end"
        case .pageUp: "terminal.inputAccessory.pageUp"
        case .pageDown: "terminal.inputAccessory.pageDown"
        case .tilde: "terminal.inputAccessory.tilde"
        case .pipe: "terminal.inputAccessory.pipe"
        case .ctrlC: "terminal.inputAccessory.ctrlC"
        case .ctrlD: "terminal.inputAccessory.ctrlD"
        case .ctrlZ: "terminal.inputAccessory.ctrlZ"
        case .ctrlL: "terminal.inputAccessory.ctrlL"
        }
    }

    var accessibilityLabel: String? {
        switch self {
        case .hideKeyboard:
            String(localized: "ios.terminal.inputAccessory.hideKeyboard", defaultValue: "Hide Keyboard")
        case .zoomOut:
            String(localized: "ios.terminal.inputAccessory.zoomOut", defaultValue: "Zoom Out")
        case .zoomIn:
            String(localized: "ios.terminal.inputAccessory.zoomIn", defaultValue: "Zoom In")
        default:
            nil
        }
    }

    var symbolName: String? {
        switch self {
        case .hideKeyboard:
            "keyboard.chevron.compact.down"
        case .zoomOut:
            "minus.magnifyingglass"
        case .zoomIn:
            "plus.magnifyingglass"
        default:
            nil
        }
    }

    var zoomDirection: TerminalFontZoomDirection? {
        switch self {
        case .zoomOut:
            .decrease
        case .zoomIn:
            .increase
        default:
            nil
        }
    }

    var isModifier: Bool {
        switch self {
        case .control, .alternate, .command, .shift:
            true
        default:
            false
        }
    }

    var output: Data? {
        switch self {
        case .hideKeyboard, .control, .alternate, .command, .shift, .zoomOut, .zoomIn:
            nil
        case .escape:
            Data([0x1B])
        case .tab:
            Data([0x09])
        case .enter:
            Data([0x0D])
        case .backspace:
            Data([0x7F])
        case .deleteForward:
            Data([0x1B, 0x5B, 0x33, 0x7E])
        case .upArrow:
            Data([0x1B, 0x5B, 0x41])
        case .downArrow:
            Data([0x1B, 0x5B, 0x42])
        case .leftArrow:
            Data([0x1B, 0x5B, 0x44])
        case .rightArrow:
            Data([0x1B, 0x5B, 0x43])
        case .home:
            Data([0x1B, 0x5B, 0x48])
        case .end:
            Data([0x1B, 0x5B, 0x46])
        case .pageUp:
            Data([0x1B, 0x5B, 0x35, 0x7E])
        case .pageDown:
            Data([0x1B, 0x5B, 0x36, 0x7E])
        case .tilde:
            Data([0x7E])
        case .pipe:
            Data([0x7C])
        case .ctrlC:
            Data([0x03])
        case .ctrlD:
            Data([0x04])
        case .ctrlZ:
            Data([0x1A])
        case .ctrlL:
            Data([0x0C])
        }
    }
}

@MainActor
private enum TerminalHardwareKeyResolver {
    private static let supportedModifierFlags: UIKeyModifierFlags = [.shift, .control, .alternate]

    static func makeKeyCommands(target: Any, action: Selector) -> [UIKeyCommand] {
        let navigationInputs = [
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow,
            UIKeyCommand.inputHome,
            UIKeyCommand.inputEnd,
            UIKeyCommand.inputPageUp,
            UIKeyCommand.inputPageDown,
            UIKeyCommand.inputDelete,
            UIKeyCommand.inputEscape,
            "\t",
        ]
        let navigation = navigationInputs.map {
            UIKeyCommand(input: $0, modifierFlags: [], action: action)
        }
        let altNavigation = [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.alternate], action: action),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [.alternate], action: action),
            UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [.alternate], action: action),
        ]
        let controlInputs = Array("abcdefghijklmnopqrstuvwxyz[]\\ 234567/").map(String.init)
            .map { UIKeyCommand(input: $0, modifierFlags: [.control], action: action) }
        let shiftedControlInputs = Array("@^_?").map(String.init)
            .map { UIKeyCommand(input: $0, modifierFlags: [.control, .shift], action: action) }
        return navigation + altNavigation + controlInputs + shiftedControlInputs
    }

    static func data(input: String, modifierFlags: UIKeyModifierFlags) -> Data? {
        let normalizedFlags = modifierFlags.intersection(supportedModifierFlags)
        return switch (input, normalizedFlags) {
        case (UIKeyCommand.inputLeftArrow, [.alternate]):
            Data([0x1B, 0x62])
        case (UIKeyCommand.inputRightArrow, [.alternate]):
            Data([0x1B, 0x66])
        case (UIKeyCommand.inputDelete, [.alternate]):
            Data([0x1B, 0x7F])
        case (UIKeyCommand.inputUpArrow, []):
            Data([0x1B, 0x5B, 0x41])
        case (UIKeyCommand.inputDownArrow, []):
            Data([0x1B, 0x5B, 0x42])
        case (UIKeyCommand.inputRightArrow, []):
            Data([0x1B, 0x5B, 0x43])
        case (UIKeyCommand.inputLeftArrow, []):
            Data([0x1B, 0x5B, 0x44])
        case (UIKeyCommand.inputHome, []):
            Data([0x1B, 0x5B, 0x48])
        case (UIKeyCommand.inputEnd, []):
            Data([0x1B, 0x5B, 0x46])
        case (UIKeyCommand.inputPageUp, []):
            Data([0x1B, 0x5B, 0x35, 0x7E])
        case (UIKeyCommand.inputPageDown, []):
            Data([0x1B, 0x5B, 0x36, 0x7E])
        case (UIKeyCommand.inputDelete, []):
            Data([0x1B, 0x5B, 0x33, 0x7E])
        case (UIKeyCommand.inputEscape, []):
            Data([0x1B])
        case ("\t", []):
            Data([0x09])
        case ("\t", [.shift]):
            Data([0x1B, 0x5B, 0x5A])
        case let (input, flags) where flags == [.control] || flags == [.control, .shift]:
            controlCharacter(for: input)
        default:
            nil
        }
    }

    private static func controlCharacter(for input: String) -> Data? {
        switch input {
        case " ", "2":
            return Data([0x00])
        case "3":
            return Data([0x1B])
        case "4":
            return Data([0x1C])
        case "5":
            return Data([0x1D])
        case "6":
            return Data([0x1E])
        case "7", "/":
            return Data([0x1F])
        case "?":
            return Data([0x7F])
        default:
            break
        }

        guard let scalar = input.uppercased().unicodeScalars.first,
              input.unicodeScalars.count == 1,
              (0x40...0x5F).contains(scalar.value) else { return nil }
        return Data([UInt8(scalar.value & 0x1F)])
    }
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
    private static var clipboardReader: @MainActor @Sendable () -> String? = { UIPasteboard.general.string }
    private static var clipboardWriter: @MainActor @Sendable (String?) -> Void = { UIPasteboard.general.string = $0 }
    private static var remoteConfigOverride: String?

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    // Ghostty may emit wakeups in bursts during font metric churn. Treat them
    // as a frame-cadenced signal so pinch zoom cannot starve UIKit's run loop.
    private let wakeupTickLock = NSLock()
    private var wakeupTickPending = false

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
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
            runtime.scheduleWakeupTick()
        }
        runtimeConfig.action_cb = { _, target, action in
            GhosttyRuntime.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = cmuxHarnessReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.write_clipboard_cb = { userdata, location, content, len, confirm in
            GhosttyRuntime.handleWriteClipboard(
                userdata,
                location: location,
                content: content,
                len: len,
                confirm: confirm
            )
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

    private func scheduleWakeupTick() {
        wakeupTickLock.lock()
        wakeupTickPending = true
        wakeupTickLock.unlock()
    }

    @MainActor
    func drainScheduledWakeupTick() {
        wakeupTickLock.lock()
        let shouldTick = wakeupTickPending
        wakeupTickPending = false
        wakeupTickLock.unlock()

        guard shouldTick else { return }
        tick()
        GhosttyTerminalSurfaceView.drawVisibleSurfacesForWakeup()
    }

    public static func configuredUIColor(named key: String, fallback: UIColor) -> UIColor {
        guard let runtime = try? shared(),
              let config = runtime.config else { return fallback }
        var color = ghostty_config_color_s()
        if ghostty_config_get(config, &color, key, UInt(key.utf8.count)) {
            return UIColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1
            )
        }
        return fallback
    }

    @MainActor
    @discardableResult
    public static func applyRemoteConfigOverride(_ configText: String?) -> Bool {
        let normalized = configText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = normalized?.isEmpty == false ? normalized : nil
        guard next != remoteConfigOverride else { return false }
        remoteConfigOverride = next
        guard let runtime = try? shared() else { return true }
        runtime.reloadConfig()
        return true
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
        let defaults = """
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
        defaults.withCString { themePointer in
            "cmux-ios-defaults".withCString { namePointer in
                ghostty_config_load_string(config, themePointer, UInt(defaults.utf8.count), namePointer)
            }
        }
        ghostty_config_load_default_files(config)
        for url in configURLs() {
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
        }
        if let remoteConfigOverride {
            remoteConfigOverride.withCString { configPointer in
                "cmux-remote-appearance".withCString { namePointer in
                    ghostty_config_load_string(config, configPointer, UInt(remoteConfigOverride.utf8.count), namePointer)
                }
            }
        }
    }

    @MainActor
    private func reloadConfig() {
        guard let newConfig = ghostty_config_new() else { return }
        Self.loadConfig(newConfig)
        ghostty_config_finalize(newConfig)
        if let app {
            ghostty_app_update_config(app, newConfig)
        }
        if let oldConfig = config {
            ghostty_config_free(oldConfig)
        }
        config = newConfig
        GhosttyTerminalSurfaceView.applyRuntimeConfigToVisibleSurfaces()
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

    nonisolated static func configURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = []
        if let overridePath = environment["CMUX_GHOSTTY_CONFIG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            let overrideURL = URL(fileURLWithPath: overridePath)
            if isReadableConfigFile(at: overrideURL, fileManager: fileManager) {
                urls.append(overrideURL)
            }
        }

        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let candidates = [
                appSupport.appendingPathComponent("ghostty/config.ghostty", isDirectory: false),
                appSupport.appendingPathComponent("ghostty/config", isDirectory: false),
            ]
            for url in candidates where isReadableConfigFile(at: url, fileManager: fileManager) {
                urls.append(url)
            }
        }
        return urls
    }

    nonisolated private static func isReadableConfigFile(at url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
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

        if action.tag == GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD {
            Task { @MainActor in
                GhosttyRuntime.clipboardWriter(GhosttyTerminalSurfaceView.view(for: surface)?.title)
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
        guard let userdataBits = userdata.map({ UInt(bitPattern: $0) }),
              let stateBits = state.map({ UInt(bitPattern: $0) }) else {
            return false
        }
        Task { @MainActor in
            guard let userdata = UnsafeMutableRawPointer(bitPattern: userdataBits),
                  let state = UnsafeMutableRawPointer(bitPattern: stateBits) else { return }
            guard let bridge = GhosttySurfaceBridge.fromOpaque(userdata),
                  let surfaceView = bridge.surfaceView,
                  let surface = surfaceView.surface else { return }
            let value = GhosttyRuntime.clipboardReader() ?? ""
            value.withCString { pointer in
                guard surfaceView.surface == surface else { return }
                ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
            }
        }
        return true
    }

    nonisolated private static func handleWriteClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        for index in 0..<len {
            let item = content[index]
            guard let mime = item.mime,
                  String(cString: mime) == "text/plain",
                  let data = item.data else { continue }
            let value = String(cString: data)
            Task { @MainActor in
                GhosttyRuntime.clipboardWriter(value)
            }
            return
        }
    }

    @MainActor
    static func setClipboardHandlersForTesting(
        reader: @escaping @MainActor @Sendable () -> String?,
        writer: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        clipboardReader = reader
        clipboardWriter = writer
    }

    @MainActor
    static func resetClipboardHandlersForTesting() {
        clipboardReader = { UIPasteboard.general.string }
        clipboardWriter = { UIPasteboard.general.string = $0 }
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
    static func dispose(surface: ghostty_surface_t, bridge: GhosttySurfaceBridge, queue: DispatchQueue) {
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
    private static let defaultMobileFontSize: Float32 = 16
    private static let minimumMobileFontSize: Float32 = 9
    private static let maximumMobileFontSize: Float32 = 30
    private static let mobileFontZoomStep: Float32 = 1

    private weak var runtime: GhosttyRuntime?
    private weak var delegate: GhosttyTerminalSurfaceViewDelegate?
    private let bridge = GhosttySurfaceBridge()
    private var displayLink: CADisplayLink?
    private var lastReportedSize: TerminalGridSize?
    private var hasFedInitialOutput = false
    private var needsDraw = false
    private var pinchAccumulatedScale: CGFloat = 1
    private var pinchTargetFontSize: Float32?
    private var currentFontSize = GhosttyTerminalSurfaceView.defaultMobileFontSize
    #if DEBUG
    var onOutputProcessedForTesting: (() -> Void)?
    private var hasRunUITestingZoomStress = false
    #endif
    // Keep `ghostty_surface_process_output` off the main thread. This is
    // per surface so a slow free or render on one terminal cannot block input
    // and output processing for every other visible terminal.
    private let outputQueue = DispatchQueue(
        label: "ai.manaflow.cmux.comeup.ghostty.output.\(UUID().uuidString)",
        qos: .userInitiated
    )
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
        textView.onEscapeSequence = { [weak self] data in
            guard let self else { return }
            self.delegate?.ghosttyTerminalSurfaceView(self, didProduceInput: data)
        }
        textView.onZoom = { [weak self] direction in
            self?.performFontZoom(direction)
        }
        textView.onHideKeyboard = { [weak self] in
            self?.inputProxy.resignFirstResponder()
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
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
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
        let forwarded = Self.forwardTerminalOutputBytes(data)
        let surfaceBits = UInt(bitPattern: UnsafeRawPointer(surface))
        outputQueue.async { [weak self] in
            guard let surface = UnsafeMutableRawPointer(bitPattern: surfaceBits) else { return }
            forwarded.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                ghostty_surface_process_output(
                    surface,
                    baseAddress.assumingMemoryBound(to: CChar.self),
                    UInt(buffer.count)
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.surface == surface else { return }
                self.hasFedInitialOutput = true
                self.needsDraw = true
                ghostty_surface_render_now(surface)
                self.accessibilityValue = self.accessibilityRenderedTextForTesting()
                #if DEBUG
                self.onOutputProcessedForTesting?()
                #endif
            }
        }
    }

    static func forwardTerminalOutputBytes(_ data: Data) -> Data {
        // The Rust daemon owns terminal byte semantics. iOS must hand the exact
        // PTY stream to libghostty so colors, cursor state, and scrollback match
        // the cmux TUI attachment.
        data
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

    public func reportCurrentGridSize() {
        syncSurfaceGeometry(reportResize: true, forceReport: true)
    }

    @objc public func focusInput() {
        #if DEBUG
        cmuxDebugLog("ios.ghostty.focusInput")
        #endif
        inputProxy.becomeFirstResponder()
        #if DEBUG
        runUITestingZoomStressIfNeeded()
        #endif
    }

    func updateHostPlatform(_ platform: CmxHostPlatform) {
        inputProxy.updateModifierLabels(isMacRemote: platform.usesMacModifiers)
    }

    public func simulateTextInputForTesting(_ text: String) {
        inputProxy.insertText(text)
    }

    public func simulateHardwareKeyForTesting(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        inputProxy.simulateHardwareKeyForTesting(input: input, modifierFlags: modifierFlags)
    }

    public func simulateAccessoryActionForTesting(_ action: TerminalInputAccessoryAction) {
        inputProxy.simulateAccessoryActionForTesting(action)
    }

    public var accessoryActionIdentifiersForTesting: [String] {
        inputProxy.accessoryActionIdentifiersForTesting
    }

    @discardableResult
    public func simulateFontZoomForTesting(_ direction: TerminalFontZoomDirection) -> Bool {
        performFontZoom(direction)
    }

    #if DEBUG
    public func simulatePinchZoomCycleForTesting(_ directions: [TerminalFontZoomDirection]) {
        pinchTargetFontSize = currentFontSize
        for direction in directions {
            let baseFontSize = pinchTargetFontSize ?? currentFontSize
            pinchTargetFontSize = nextMobileFontSize(from: baseFontSize, after: direction)
        }
        if let target = pinchTargetFontSize,
           target != currentFontSize {
            _ = applyMobileFontSize(target, reportResize: true)
        }
        pinchTargetFontSize = nil
    }

    private func runUITestingZoomStressIfNeeded() {
        guard !hasRunUITestingZoomStress,
              let value = ProcessInfo.processInfo.environment["CMUX_IOS_UI_TESTING_ZOOM_STRESS_CYCLES"],
              let cycles = Int(value),
              cycles > 0 else { return }
        hasRunUITestingZoomStress = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            for index in 0..<cycles {
                self.simulatePinchZoomCycleForTesting([.decrease])
                self.simulatePinchZoomCycleForTesting([.increase])
                if index.isMultiple(of: 20) {
                    await Task.yield()
                }
            }
            let renderedText = self.accessibilityRenderedTextForTesting() ?? ""
            self.accessibilityValue = renderedText + "\nZOOM_STRESS_DONE"
        }
    }
    #endif

    public var fontSizeForTesting: Float32 {
        currentFontSize
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
        GhosttySurfaceDisposer.dispose(surface: surface, bridge: bridge, queue: outputQueue)
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
        surfaceConfig.font_size = Self.defaultMobileFontSize
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

    private func syncSurfaceGeometry(
        reportResize: Bool = true,
        forceReport: Bool = false,
        renderNow: Bool = true
    ) {
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
        if reportResize, forceReport || gridSize != lastReportedSize {
            lastReportedSize = gridSize
            delegate?.ghosttyTerminalSurfaceView(self, didResize: gridSize)
        }
        for sublayer in layer.sublayers ?? [] where String(describing: type(of: sublayer)) == "IOSurfaceLayer" {
            sublayer.frame = bounds
            sublayer.bounds = CGRect(origin: .zero, size: bounds.size)
            sublayer.contentsScale = scale
        }
        if hasFedInitialOutput {
            if renderNow {
                ghostty_surface_render_now(surface)
            } else {
                ghostty_surface_refresh(surface)
            }
        }
    }

    private func applyConfiguredBackground() {
        backgroundColor = GhosttyRuntime.configuredUIColor(
            named: "background",
            fallback: UIColor(red: 0x27 / 255, green: 0x28 / 255, blue: 0x22 / 255, alpha: 1)
        )
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let surface, gesture.state == .changed else { return }
        let translation = gesture.translation(in: self)
        ghostty_surface_mouse_scroll(surface, 0, Double(translation.y / 10), 0)
        gesture.setTranslation(.zero, in: self)
        needsDraw = true
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            #if DEBUG
            cmuxDebugLog("ios.ghostty.pinch.begin font=\(currentFontSize)")
            #endif
            pinchAccumulatedScale = 1
            pinchTargetFontSize = currentFontSize
        case .changed:
            let delta = gesture.scale - pinchAccumulatedScale
            guard abs(delta) >= 0.15 else { return }
            let baseFontSize = pinchTargetFontSize ?? currentFontSize
            pinchTargetFontSize = nextMobileFontSize(from: baseFontSize, after: delta > 0 ? .increase : .decrease)
            #if DEBUG
            cmuxDebugLog("ios.ghostty.pinch.changed target=\(pinchTargetFontSize ?? currentFontSize)")
            #endif
            pinchAccumulatedScale = gesture.scale
        case .ended, .cancelled:
            if let target = pinchTargetFontSize,
               target != currentFontSize {
                _ = applyMobileFontSize(target, reportResize: true)
            }
            #if DEBUG
            cmuxDebugLog("ios.ghostty.pinch.end font=\(currentFontSize)")
            #endif
            pinchTargetFontSize = nil
        default:
            break
        }
    }

    @discardableResult
    private func performFontZoom(
        _ direction: TerminalFontZoomDirection,
        reportResize: Bool = true,
        synchronizeGeometry: Bool = true
    ) -> Bool {
        let nextFontSize = nextMobileFontSize(from: currentFontSize, after: direction)
        #if DEBUG
        cmuxDebugLog("ios.ghostty.zoom direction=\(String(describing: direction)) next=\(nextFontSize)")
        #endif
        return applyMobileFontSize(
            nextFontSize,
            reportResize: reportResize,
            synchronizeGeometry: synchronizeGeometry
        )
    }

    @discardableResult
    private func applyMobileFontSize(
        _ nextFontSize: Float32,
        reportResize: Bool = true,
        synchronizeGeometry: Bool = true
    ) -> Bool {
        guard let surface else { return false }
        guard nextFontSize != currentFontSize else { return false }
        let direction: TerminalFontZoomDirection = nextFontSize > currentFontSize ? .increase : .decrease
        let action = direction.bindingAction(delta: abs(nextFontSize - currentFontSize))
        let handled = action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
        guard handled else {
            #if DEBUG
            cmuxDebugLog("ios.ghostty.fontSize.failed target=\(nextFontSize)")
            #endif
            return false
        }
        currentFontSize = nextFontSize
        #if DEBUG
        cmuxDebugLog("ios.ghostty.fontSize.applied target=\(nextFontSize) reportResize=\(reportResize ? 1 : 0)")
        #endif
        if synchronizeGeometry {
            syncSurfaceGeometry(reportResize: reportResize, renderNow: false)
        }
        return true
    }

    private func nextMobileFontSize(from fontSize: Float32, after direction: TerminalFontZoomDirection) -> Float32 {
        let delta = switch direction {
        case .decrease:
            -Self.mobileFontZoomStep
        case .increase:
            Self.mobileFontZoomStep
        }
        return min(
            Self.maximumMobileFontSize,
            max(Self.minimumMobileFontSize, fontSize + delta)
        )
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleDisplayLink() {
        runtime?.drainScheduledWakeupTick()
        guard let surface else { return }
        if needsDraw {
            needsDraw = false
            ghostty_surface_render_now(surface)
        }
    }

    @MainActor
    static func drawVisibleSurfacesForWakeup() {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        for view in registeredSurfaceViews.values.compactMap(\.value) where view.window != nil {
            if let surface = view.surface {
                ghostty_surface_refresh(surface)
            }
        }
    }

    @MainActor
    static func applyRuntimeConfigToVisibleSurfaces() {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            view.applyConfiguredBackground()
            if let surface = view.surface {
                ghostty_surface_refresh(surface)
                view.needsDraw = true
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
    var onEscapeSequence: ((Data) -> Void)?
    var onZoom: ((TerminalFontZoomDirection) -> Void)?
    var onHideKeyboard: (() -> Void)?
    private var controlAccessoryArmed = false
    private var alternateAccessoryArmed = false
    private var commandAccessoryArmed = false
    private var shiftAccessoryArmed = false
    private var controlAccessorySticky = false
    private var alternateAccessorySticky = false
    private var commandAccessorySticky = false
    private var shiftAccessorySticky = false
    private var lastControlTapTime: Date?
    private var lastAlternateTapTime: Date?
    private var lastCommandTapTime: Date?
    private var lastShiftTapTime: Date?
    private weak var accessoryStackView: UIStackView?
    private var commandAccessoryButton: UIButton?
    private var isMacRemote = false

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        TerminalHardwareKeyResolver.makeKeyCommands(
            target: self,
            action: #selector(handleHardwareKeyCommand(_:))
        )
    }

    private static let accessoryBackground = UIColor(red: 0x27 / 255, green: 0x28 / 255, blue: 0x22 / 255, alpha: 1)
    private static let accessoryButtonNormalBackground = UIColor(white: 0.35, alpha: 1)
    private static let accessoryButtonHeight: CGFloat = 28
    private static let accessoryButtonMinWidth: CGFloat = 44
    private static let stickyDoubleTapInterval: TimeInterval = 0.4

    private lazy var terminalAccessoryToolbar: UIView = {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        container.backgroundColor = Self.accessoryBackground

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center

        for action in TerminalInputAccessoryAction.allCases {
            let button = makeAccessoryButton(for: action)
            if action == .command {
                commandAccessoryButton = button
            } else {
                stack.addArrangedSubview(button)
            }
        }

        scrollView.addSubview(stack)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -8),
        ])

        accessoryStackView = stack
        return container
    }()

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
        inputAccessoryView = terminalAccessoryToolbar
        isAccessibilityElement = true
        accessibilityIdentifier = "terminal.input"
        accessibilityLabel = String(localized: "ios.terminal.input.accessibility", defaultValue: "Terminal input")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        emitCommittedText(text)
    }

    override func deleteBackward() {
        if commandAccessoryArmed {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            onEscapeSequence?(Data([0x15]))
            return
        }
        if alternateAccessoryArmed {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let output = TerminalHardwareKeyResolver.data(input: UIKeyCommand.inputDelete, modifierFlags: [.alternate]) {
                onEscapeSequence?(output)
            }
            return
        }
        if controlAccessoryArmed {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            onBackspace?()
            return
        }
        onBackspace?()
    }

    func updateModifierLabels(isMacRemote: Bool) {
        guard self.isMacRemote != isMacRemote else { return }
        self.isMacRemote = isMacRemote
        guard let stack = accessoryStackView else { return }
        for case let button as UIButton in stack.arrangedSubviews {
            guard let action = TerminalInputAccessoryAction(rawValue: button.tag) else { continue }
            button.setTitle(action.title(isMacRemote: isMacRemote), for: .normal)
        }
        if let commandAccessoryButton {
            if isMacRemote {
                if commandAccessoryButton.superview == nil {
                    let insertIndex = stack.arrangedSubviews.firstIndex {
                        $0.tag == TerminalInputAccessoryAction.alternate.rawValue
                    }.map { $0 + 1 } ?? stack.arrangedSubviews.count
                    stack.insertArrangedSubview(commandAccessoryButton, at: insertIndex)
                }
            } else if commandAccessoryButton.superview != nil {
                stack.removeArrangedSubview(commandAccessoryButton)
                commandAccessoryButton.removeFromSuperview()
            }
        }
        if !isMacRemote && commandAccessoryArmed {
            setCommandAccessoryArmed(false)
        }
    }

    func simulateHardwareKeyForTesting(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        handleHardwareKeyInput(input: input, modifierFlags: modifierFlags)
    }

    func simulateAccessoryActionForTesting(_ action: TerminalInputAccessoryAction) {
        resetStickyTapTimeForTesting(action)
        handleAccessoryAction(action)
    }

    var accessoryActionIdentifiersForTesting: [String] {
        guard let stack = accessoryStackView else { return [] }
        return stack.arrangedSubviews.compactMap(\.accessibilityIdentifier)
    }

    private func resetStickyTapTimeForTesting(_ action: TerminalInputAccessoryAction) {
        switch action {
        case .control:
            lastControlTapTime = nil
        case .alternate:
            lastAlternateTapTime = nil
        case .command:
            lastCommandTapTime = nil
        case .shift:
            lastShiftTapTime = nil
        default:
            break
        }
    }

    @objc private func handleHardwareKeyCommand(_ sender: UIKeyCommand) {
        guard let input = sender.input else { return }
        _ = handleHardwareKeyInput(input: input, modifierFlags: sender.modifierFlags)
    }

    @objc private func handleAccessoryButton(_ sender: UIButton) {
        guard let action = TerminalInputAccessoryAction(rawValue: sender.tag) else { return }
        handleAccessoryAction(action)
    }

    @discardableResult
    private func handleHardwareKeyInput(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        guard let data = TerminalHardwareKeyResolver.data(input: input, modifierFlags: modifierFlags) else {
            return false
        }
        onEscapeSequence?(data)
        return true
    }

    private func handleAccessoryAction(_ action: TerminalInputAccessoryAction) {
        if action == .hideKeyboard {
            disarmAllModifiers()
            refreshAccessoryButtonStyles()
            onHideKeyboard?()
            return
        }

        if let zoomDirection = action.zoomDirection {
            disarmAllModifiers()
            refreshAccessoryButtonStyles()
            onZoom?(zoomDirection)
            return
        }

        if controlAccessoryArmed, !action.isModifier {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            if let output = action.output {
                onEscapeSequence?(output)
            }
            return
        }

        if alternateAccessoryArmed, !action.isModifier {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let output = alternateAccessoryOutput(for: action) {
                onEscapeSequence?(output)
            }
            return
        }

        if commandAccessoryArmed, !action.isModifier {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            if let output = commandAccessoryOutput(for: action) {
                onEscapeSequence?(output)
            }
            return
        }

        if let output = action.output {
            onEscapeSequence?(output)
            return
        }

        switch action {
        case .control:
            toggleControlModifier()
        case .alternate:
            toggleAlternateModifier()
        case .command:
            toggleCommandModifier()
        case .shift:
            toggleShiftModifier()
        default:
            break
        }
    }

    private func makeAccessoryButton(for action: TerminalInputAccessoryAction) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tag = action.rawValue
        button.accessibilityIdentifier = action.accessibilityIdentifier
        button.accessibilityLabel = action.accessibilityLabel
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        button.tintColor = .white
        button.layer.cornerRadius = 6
        if let symbolName = action.symbolName {
            button.setImage(UIImage(systemName: symbolName), for: .normal)
        } else {
            button.setTitle(action.title, for: .normal)
        }
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = Self.accessoryButtonNormalBackground
        button.heightAnchor.constraint(equalToConstant: Self.accessoryButtonHeight).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.accessoryButtonMinWidth).isActive = true
        button.addTarget(self, action: #selector(handleAccessoryButton(_:)), for: .touchUpInside)
        return button
    }

    private func emitCommittedText(_ text: String) {
        if controlAccessoryArmed {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            if let controlSequence = controlSequence(for: text) {
                onEscapeSequence?(controlSequence)
            } else {
                onText?(text)
            }
            return
        }
        if alternateAccessoryArmed {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let alternateSequence = alternateSequence(for: text) {
                onEscapeSequence?(alternateSequence)
            } else {
                onText?(text)
            }
            return
        }
        if commandAccessoryArmed {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            if let commandSequence = commandTextSequence(for: text) {
                onEscapeSequence?(commandSequence)
            } else {
                onText?(text)
            }
            return
        }
        if shiftAccessoryArmed {
            if !shiftAccessorySticky {
                setShiftAccessoryArmed(false)
            }
            onText?(text.uppercased())
            return
        }
        onText?(text)
    }

    private func disarmAllModifiers() {
        controlAccessoryArmed = false; controlAccessorySticky = false; lastControlTapTime = nil
        alternateAccessoryArmed = false; alternateAccessorySticky = false; lastAlternateTapTime = nil
        commandAccessoryArmed = false; commandAccessorySticky = false; lastCommandTapTime = nil
        shiftAccessoryArmed = false; shiftAccessorySticky = false; lastShiftTapTime = nil
    }

    private func toggleControlModifier() {
        let now = Date()
        if controlAccessorySticky {
            disarmAllModifiers()
        } else if controlAccessoryArmed, let lastControlTapTime, now.timeIntervalSince(lastControlTapTime) < Self.stickyDoubleTapInterval {
            controlAccessorySticky = true
            self.lastControlTapTime = nil
        } else {
            let shouldArm = !controlAccessoryArmed
            disarmAllModifiers()
            controlAccessoryArmed = shouldArm
            lastControlTapTime = shouldArm ? now : nil
        }
        refreshAccessoryButtonStyles()
    }

    private func toggleAlternateModifier() {
        let now = Date()
        if alternateAccessorySticky {
            disarmAllModifiers()
        } else if alternateAccessoryArmed, let lastAlternateTapTime, now.timeIntervalSince(lastAlternateTapTime) < Self.stickyDoubleTapInterval {
            alternateAccessorySticky = true
            self.lastAlternateTapTime = nil
        } else {
            let shouldArm = !alternateAccessoryArmed
            disarmAllModifiers()
            alternateAccessoryArmed = shouldArm
            lastAlternateTapTime = shouldArm ? now : nil
        }
        refreshAccessoryButtonStyles()
    }

    private func toggleCommandModifier() {
        let now = Date()
        if commandAccessorySticky {
            disarmAllModifiers()
        } else if commandAccessoryArmed, let lastCommandTapTime, now.timeIntervalSince(lastCommandTapTime) < Self.stickyDoubleTapInterval {
            commandAccessorySticky = true
            self.lastCommandTapTime = nil
        } else {
            let shouldArm = !commandAccessoryArmed
            disarmAllModifiers()
            commandAccessoryArmed = shouldArm
            lastCommandTapTime = shouldArm ? now : nil
        }
        refreshAccessoryButtonStyles()
    }

    private func toggleShiftModifier() {
        let now = Date()
        if shiftAccessorySticky {
            disarmAllModifiers()
        } else if shiftAccessoryArmed, let lastShiftTapTime, now.timeIntervalSince(lastShiftTapTime) < Self.stickyDoubleTapInterval {
            shiftAccessorySticky = true
            self.lastShiftTapTime = nil
        } else {
            let shouldArm = !shiftAccessoryArmed
            disarmAllModifiers()
            shiftAccessoryArmed = shouldArm
            lastShiftTapTime = shouldArm ? now : nil
        }
        refreshAccessoryButtonStyles()
    }

    private func refreshAccessoryButtonStyles() {
        guard let stack = accessoryStackView else { return }
        for case let button as UIButton in stack.arrangedSubviews {
            guard let action = TerminalInputAccessoryAction(rawValue: button.tag) else { continue }
            let armed = isAccessoryActionArmed(action)
            let sticky = isAccessoryActionSticky(action)
            if sticky {
                button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
                button.layer.borderWidth = 2
                button.layer.borderColor = UIColor.white.cgColor
            } else if armed {
                button.backgroundColor = .systemBlue
                button.layer.borderWidth = 0
            } else {
                button.backgroundColor = Self.accessoryButtonNormalBackground
                button.layer.borderWidth = 0
            }
            button.setTitleColor(.white, for: .normal)
            button.tintColor = .white
        }
    }

    private func controlSequence(for text: String) -> Data? {
        guard text.count == 1 else { return nil }
        return TerminalHardwareKeyResolver.data(input: text, modifierFlags: [.control])
    }

    private func alternateSequence(for text: String) -> Data? {
        guard let encoded = text.data(using: .utf8), !encoded.isEmpty else { return nil }
        var sequence = Data([0x1B])
        sequence.append(encoded)
        return sequence
    }

    private func commandTextSequence(for text: String) -> Data? {
        guard text.count == 1, let char = text.lowercased().first else { return nil }
        switch char {
        case "a": return Data([0x01])
        case "c": return Data([0x03])
        case "d": return Data([0x04])
        case "e": return Data([0x05])
        case "k": return Data([0x0B])
        case "l": return Data([0x0C])
        case "u": return Data([0x15])
        case "w": return Data([0x17])
        default: return nil
        }
    }

    private func alternateAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            TerminalHardwareKeyResolver.data(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.alternate])
        case .rightArrow:
            TerminalHardwareKeyResolver.data(input: UIKeyCommand.inputRightArrow, modifierFlags: [.alternate])
        case .control, .alternate, .command, .shift:
            nil
        default:
            action.output.map { output in
                var sequence = Data([0x1B])
                sequence.append(output)
                return sequence
            }
        }
    }

    private func commandAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            Data([0x01])
        case .rightArrow:
            Data([0x05])
        case .backspace:
            Data([0x15])
        case .control, .alternate, .command, .shift:
            nil
        default:
            action.output
        }
    }

    private func isAccessoryActionArmed(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: controlAccessoryArmed
        case .alternate: alternateAccessoryArmed
        case .command: commandAccessoryArmed
        case .shift: shiftAccessoryArmed
        default: false
        }
    }

    private func isAccessoryActionSticky(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: controlAccessorySticky
        case .alternate: alternateAccessorySticky
        case .command: commandAccessorySticky
        case .shift: shiftAccessorySticky
        default: false
        }
    }

    private func setControlAccessoryArmed(_ armed: Bool) {
        guard controlAccessoryArmed != armed else { return }
        controlAccessoryArmed = armed
        if !armed {
            controlAccessorySticky = false
            lastControlTapTime = nil
        }
        refreshAccessoryButtonStyles()
    }

    private func setAlternateAccessoryArmed(_ armed: Bool) {
        guard alternateAccessoryArmed != armed else { return }
        alternateAccessoryArmed = armed
        if !armed {
            alternateAccessorySticky = false
            lastAlternateTapTime = nil
        }
        refreshAccessoryButtonStyles()
    }

    private func setCommandAccessoryArmed(_ armed: Bool) {
        guard commandAccessoryArmed != armed else { return }
        commandAccessoryArmed = armed
        if !armed {
            commandAccessorySticky = false
            lastCommandTapTime = nil
        }
        refreshAccessoryButtonStyles()
    }

    private func setShiftAccessoryArmed(_ armed: Bool) {
        guard shiftAccessoryArmed != armed else { return }
        shiftAccessoryArmed = armed
        if !armed {
            shiftAccessorySticky = false
            lastShiftTapTime = nil
        }
        refreshAccessoryButtonStyles()
    }
}

private extension CGFloat {
    var nonZero: CGFloat? {
        self > 0 ? self : nil
    }
}

struct CmxGhosttyTerminalView: UIViewRepresentable {
    @ObservedObject var store: CmxConnectionStore
    let terminalID: UInt64
    let hostPlatform: CmxHostPlatform

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    func makeUIView(context: Context) -> UIView {
        let container = CmxTerminalHostedViewContainer()
        container.backgroundColor = GhosttyRuntime.configuredUIColor(
            named: "background",
            fallback: UIColor(red: 0x27 / 255, green: 0x28 / 255, blue: 0x22 / 255, alpha: 1)
        )
        do {
            let surfaceView = GhosttyTerminalSurfaceView(
                runtime: try GhosttyRuntime.shared(),
                delegate: context.coordinator
            )
            container.setHostedView(surfaceView)
            context.coordinator.apply(
                store: store,
                terminalID: terminalID,
                hostPlatform: hostPlatform,
                to: surfaceView
            )
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
            fallback.accessibilityValue = fallback.text
            container.setHostedView(fallback)
        }
        return container
    }

    @MainActor
    func updateUIView(_ view: UIView, context: Context) {
        guard let container = view as? CmxTerminalHostedViewContainer,
              let surfaceView = container.hostedView as? GhosttyTerminalSurfaceView else { return }
        context.coordinator.apply(
            store: store,
            terminalID: terminalID,
            hostPlatform: hostPlatform,
            to: surfaceView
        )
    }

    @MainActor
    final class Coordinator: GhosttyTerminalSurfaceViewDelegate {
        private weak var store: CmxConnectionStore?
        private var terminalID: UInt64?
        private var lastAppliedOutputID = 0

        func apply(
            store: CmxConnectionStore,
            terminalID: UInt64,
            hostPlatform: CmxHostPlatform,
            to surfaceView: GhosttyTerminalSurfaceView
        ) {
            let didChangeTerminal = self.terminalID != terminalID
            if didChangeTerminal {
                lastAppliedOutputID = 0
            }
            self.store = store
            self.terminalID = terminalID
            surfaceView.updateHostPlatform(hostPlatform)

            for chunk in store.outputChunks(for: terminalID) where chunk.id > lastAppliedOutputID {
                surfaceView.processOutput(chunk.data)
                lastAppliedOutputID = chunk.id
            }
            if didChangeTerminal {
                surfaceView.reportCurrentGridSize()
            }
        }

        func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didProduceInput data: Data) {
            guard let terminalID else { return }
            store?.sendInput(data, terminalID: terminalID)
        }

        func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didResize size: TerminalGridSize) {
            guard let terminalID else { return }
            store?.updateTerminalSize(
                terminalID: terminalID,
                size: CmxTerminalSize(cols: size.columns, rows: size.rows)
            )
        }
    }
}

private final class CmxTerminalHostedViewContainer: UIView {
    private(set) var hostedView: UIView?

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedView?.frame = bounds
    }

    func setHostedView(_ view: UIView) {
        guard hostedView !== view else { return }

        hostedView?.removeFromSuperview()
        hostedView = view

        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
