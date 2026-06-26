import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WindowCommandPaletteOverlayObserverTests {
    @Test
    func deinitRemovesWindowKeyObservers() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        defer { window.close() }

        let notificationCenter = RecordingNotificationCenter()
        var controller: WindowCommandPaletteOverlayController? = WindowCommandPaletteOverlayController(
            window: window,
            notificationCenter: notificationCenter
        )

        #expect(notificationCenter.addedObservers.map(\.name) == [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ])
        #expect(notificationCenter.addedObservers.allSatisfy { $0.object === window })

        weak var weakController = controller
        controller = nil

        #expect(weakController == nil)
        #expect(
            notificationCenter.removedObserverIDs == notificationCenter.addedObservers.map(\.token.id),
            "Window command palette overlays must unregister both block observer tokens when their controller is released."
        )
    }
}

private final class RecordingObserverToken: NSObject {
    let id: Int

    init(id: Int) {
        self.id = id
        super.init()
    }
}

// Test helper is used on MainActor only; the conformance restates NotificationCenter's inherited contract.
private final class RecordingNotificationCenter: NotificationCenter, @unchecked Sendable {
    struct AddedObserver {
        let name: Notification.Name?
        weak var object: AnyObject?
        let token: RecordingObserverToken
    }

    private(set) var addedObservers: [AddedObserver] = []
    private(set) var removedObserverIDs: [Int] = []

    override func addObserver(
        forName name: Notification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        let token = RecordingObserverToken(id: addedObservers.count + 1)
        addedObservers.append(AddedObserver(name: name, object: obj as AnyObject?, token: token))
        return token
    }

    override func removeObserver(_ observer: Any) {
        guard let token = observer as? RecordingObserverToken else { return }
        removedObserverIDs.append(token.id)
    }
}
