import AppKit

/// A titled window that never becomes key or main, so the demo never takes
/// the keyboard from the user's apps.
final class DemoWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows exactly one variant window on the last screen without activating
/// the app, prints its CGWindowID, and exits after `--hold` seconds.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: LaunchArguments
    private var window: DemoWindow?
    private var exitTask: Task<Void, Never>?

    init(arguments: LaunchArguments) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tokens = Tokens.make(dark: arguments.appearance == .dark)
        let material = SurfaceMaterial.resolve(arguments.material)
        let content = VariantFactory.content(for: arguments.variant, tokens: tokens, material: material)
        let size = HostComposer.contentSize

        let window = DemoWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "rdpane-variants · \(arguments.variant.rawValue) · \(arguments.appearance.rawValue) · \(material.rawValue)"
        window.appearance = NSAppearance(named: arguments.appearance == .dark ? .darkAqua : .aqua)
        window.backgroundColor = tokens.windowBackground
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(content)
        Surface.pin(content, to: container)
        window.contentView = container
        window.setFrame(Self.placement(for: window, contentSize: size), display: false)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        self.window = window

        let line = "CGWindowID=\(window.windowNumber) pid=\(ProcessInfo.processInfo.processIdentifier) variant=\(arguments.variant.rawValue) appearance=\(arguments.appearance.rawValue) material=\(material.rawValue)\n"
        FileHandle.standardOutput.write(Data(line.utf8))

        if let path = arguments.snapshotPath {
            let ok = Self.snapshot(container, to: path)
            FileHandle.standardOutput.write(Data((ok ? "snapshot=\(path)\n" : "snapshot-failed\n").utf8))
            NSApp.terminate(nil)
            return
        }

        let hold = arguments.holdSeconds
        exitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(hold))
            NSApp.terminate(nil)
        }
    }

    /// Draws `view` (and its subviews) into a bitmap at the backing scale.
    private static func snapshot(_ view: NSView, to path: String) -> Bool {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Centered on the last screen's visible frame (a secondary display when
    /// one exists), clamped so the window stays on that screen.
    private static func placement(for window: NSWindow, contentSize: NSSize) -> NSRect {
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        guard let screen = NSScreen.screens.last else { return NSRect(origin: .zero, size: frameSize) }
        let visible = screen.visibleFrame
        let x = max(visible.minX, visible.midX - frameSize.width / 2)
        let y = max(visible.minY, visible.midY - frameSize.height / 2)
        return NSRect(x: x, y: y, width: frameSize.width, height: frameSize.height)
    }
}

/// Maps a variant name to its content view.
@MainActor
enum VariantFactory {
    static func content(for variant: Variant, tokens: Tokens, material: SurfaceMaterial) -> NSView {
        switch variant {
        case .chromeA: PaneComposer.make(chrome: .hoverToolbar, state: .live, tokens: tokens, material: material)
        case .chromeB: PaneComposer.make(chrome: .statusStrip, state: .live, tokens: tokens, material: material)
        case .chromeC: PaneComposer.make(chrome: .noChrome, state: .live, tokens: tokens, material: material)
        case .stateConnecting: PaneComposer.make(chrome: .hoverToolbar, state: .connecting, tokens: tokens, material: material)
        case .stateHighLatency: PaneComposer.make(chrome: .hoverToolbar, state: .highLatency, tokens: tokens, material: material)
        case .stateConsentWait: PaneComposer.make(chrome: .hoverToolbar, state: .consentWait, tokens: tokens, material: material)
        case .stateDisconnectedBy: PaneComposer.make(chrome: .hoverToolbar, state: .disconnectedBy("Sam"), tokens: tokens, material: material)
        case .stateHostStopped: PaneComposer.make(chrome: .hoverToolbar, state: .hostStopped, tokens: tokens, material: material)
        case .hostI1: HostComposer.make(.borderAndPill, tokens: tokens, material: material)
        case .hostI2: HostComposer.make(.pillOnly, tokens: tokens, material: material)
        case .hostI3: HostComposer.make(.menuBarOnly, tokens: tokens, material: material)
        case .hostConsent: HostComposer.make(.consent, tokens: tokens, material: material)
        }
    }
}
