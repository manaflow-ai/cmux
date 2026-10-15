#if os(iOS)
public import CNTransport
import Foundation
import Observation
public import UIKit

/// Terminal handles and live card images for a screen that shows many
/// terminals (the Tabs grid), with bounded memory:
///
/// - At most `maxLiveRenderers` handles keep a Ghostty renderer (the one on
///   screen and the most recently closed); the others are torn down to their
///   card image and re-attach when opened again.
/// - The thumbnails keep at most `thumbnails.maxLive` off-screen surfaces on
///   one parser queue; a terminal open full screen is not parsed off screen
///   (its card is taken from the open view when it closes).
/// - On a memory warning every renderer and off-screen surface is released
///   except the terminal on screen.
@MainActor
@Observable
public final class TerminalHandlePool {
    public let connection: HostConnection
    public let thumbnails: TerminalThumbnails
    public let maxLiveRenderers: Int
    public let accessoryPlacement: TerminalAccessoryPlacement

    @ObservationIgnored private var handles: [String: TerminalHandle] = [:]
    /// Most recently on screen last.
    @ObservationIgnored private var recent: [String] = []
    @ObservationIgnored private var memoryObserver: (any NSObjectProtocol)?

    public init(connection: HostConnection, maxLiveRenderers: Int = 2, maxThumbnails: Int = 8,
                accessoryPlacement: TerminalAccessoryPlacement = .external) {
        self.connection = connection
        self.maxLiveRenderers = max(1, maxLiveRenderers)
        self.accessoryPlacement = accessoryPlacement
        thumbnails = TerminalThumbnails(connection: connection, maxLive: maxThumbnails)
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseForMemoryWarning() }
        }
        #if DEBUG
        // Headless simulators cannot send a memory warning: DEBUG builds also
        // take the Darwin notification `dev.cmux.next.memory-warning`
        // (`xcrun simctl spawn <udid> notifyutil -p dev.cmux.next.memory-warning`).
        TerminalHandlePool.debugPools.append(WeakPool(self))
        if !TerminalHandlePool.debugObserving {
            TerminalHandlePool.debugObserving = true
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
                Task { @MainActor in
                    for pool in TerminalHandlePool.debugPools { pool.pool?.releaseForMemoryWarning() }
                }
            }, "dev.cmux.next.memory-warning" as CFString, nil, .deliverImmediately)
        }
        #endif
    }

    #if DEBUG
    struct WeakPool { weak var pool: TerminalHandlePool?; init(_ p: TerminalHandlePool) { pool = p } }
    static var debugPools: [WeakPool] = []
    static var debugObserving = false
    #endif

    isolated deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    /// The handle for a terminal (created on first use, cheap).
    public func handle(_ terminalId: String) -> TerminalHandle {
        if let h = handles[terminalId] { return h }
        let h = TerminalHandle(connection: connection, terminalId: terminalId, accessoryPlacement: accessoryPlacement)
        h.onVisibilityChange = { [weak self] handle, visible in self?.visibilityChanged(handle, visible) }
        handles[terminalId] = h
        return h
    }

    /// Forgets terminals that are gone (closed on the Mac).
    public func retain(_ terminalIds: [String]) {
        for (id, h) in handles where !terminalIds.contains(id) {
            h.releaseRenderer()
            handles[id] = nil
            recent.removeAll { $0 == id }
            thumbnails.forget(id)
        }
    }

    /// Card images for these terminals (see `TerminalThumbnails.show`).
    public func showCards(_ terminalIds: [String], cardSize: CGSize, style: UIUserInterfaceStyle = .unspecified) {
        thumbnails.show(terminalIds, cardSize: cardSize, style: style)
    }

    /// The open terminal's live view becomes its static card: its last
    /// presented frame (when it has one) is the card image, and it stops
    /// drawing until `showLive`. Returns false when it has no live view.
    @discardableResult
    public func showAsCard(_ terminalId: String) -> Bool {
        guard let h = handles[terminalId], h.hasRenderer else { return false }
        if let image = h.snapshot(maxPixelWidth: thumbnails.cardPixelWidth) {
            thumbnails.setImage(terminalId, image: image, contentBottom: h.model.controller?.contentBottom)
        }
        h.setRendering(false)
        return true
    }

    /// The terminal's live view draws again (it is being opened).
    public func showLive(_ terminalId: String) {
        handles[terminalId]?.setRendering(true)
    }

    /// Releases every renderer and off-screen surface except the terminal on
    /// screen (called on a memory warning; hosts may call it when hidden).
    public func releaseForMemoryWarning() {
        defer { TerminalMemory.log() }
        for h in handles.values where !h.isOnScreen { h.releaseRenderer() }
        recent = recent.filter { handles[$0]?.hasRenderer ?? false }
        thumbnails.stopAll()
    }

    /// DEBUG: renderers alive now.
    public var liveRendererCount: Int { handles.values.filter(\.hasRenderer).count }

    private func visibilityChanged(_ handle: TerminalHandle, _ visible: Bool) {
        guard let id = handle.terminalId else { return }
        recent.removeAll { $0 == id }
        recent.append(id)
        if visible {
            thumbnails.suspend(id)
        } else {
            // The card shows the screen as it was when the terminal closed.
            // The card shows the live renderer's last frame (same pixels).
            if let controller = handle.model.controller, let image = controller.snapshot(maxPixelWidth: thumbnails.cardPixelWidth) {
                thumbnails.resume(id, image: image, contentBottom: controller.contentBottom)
            } else {
                // No frame to keep: the off-screen renderer draws the card.
                thumbnails.resume(id)
            }
        }
        enforceRendererCap()
    }

    /// Keeps the most recent `maxLiveRenderers` renderers (never the one on
    /// screen is released).
    private func enforceRendererCap() {
        let alive = Set(handles.filter { $0.value.hasRenderer }.map(\.key))
        let onScreen = Set(handles.filter { $0.value.isOnScreen || $0.value.isInWindow }.map(\.key))
        let evict = TerminalRendererCap(max: maxLiveRenderers).evictions(recent: recent, alive: alive, protected: onScreen)
        for id in evict {
            if handles[id]?.releaseRenderer() ?? true { recent.removeAll { $0 == id } }
        }
    }
}
#endif
