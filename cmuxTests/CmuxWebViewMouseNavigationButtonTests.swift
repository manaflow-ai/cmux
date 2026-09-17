import AppKit
import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("CmuxWebView mouse navigation buttons")
struct CmuxWebViewMouseNavigationButtonTests {
    @Test("Button three uses BrowserPanel restored back history")
    func buttonThreeUsesPanelBackHistory() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/d"
            ],
            currentURLString: "https://example.com/c"
        )

        panel.webView.otherMouseDown(with: try makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 3))
        panel.webView.otherMouseUp(with: try makeOtherMouseEvent(type: .otherMouseUp, buttonNumber: 3))

        let snapshot = panel.sessionNavigationHistorySnapshot()
        #expect(snapshot.backHistoryURLStrings == ["https://example.com/a"])
        #expect(snapshot.forwardHistoryURLStrings == ["https://example.com/c", "https://example.com/d"])
    }

    @Test("Button four uses BrowserPanel restored forward history")
    func buttonFourUsesPanelForwardHistory() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [
                "https://example.com/a"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/c",
                "https://example.com/d"
            ],
            currentURLString: "https://example.com/b"
        )

        panel.webView.otherMouseDown(with: try makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 4))
        panel.webView.otherMouseUp(with: try makeOtherMouseEvent(type: .otherMouseUp, buttonNumber: 4))

        let snapshot = panel.sessionNavigationHistorySnapshot()
        #expect(snapshot.backHistoryURLStrings == ["https://example.com/a", "https://example.com/b"])
        #expect(snapshot.forwardHistoryURLStrings == ["https://example.com/d"])
    }

    @Test("Replacement web views keep BrowserPanel restored back history")
    func replacementWebViewButtonThreeUsesPanelBackHistory() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.reattachToWorkspace(
            UUID(),
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: UUID(),
            proxyEndpoint: nil,
            remoteStatus: nil
        )
        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [],
            currentURLString: "https://example.com/c"
        )
        let recorder = BrowserClickNotificationRecorder()
        NotificationCenter.default.addObserver(
            recorder,
            selector: #selector(BrowserClickNotificationRecorder.record(_:)),
            name: .webViewDidReceiveClick,
            object: nil
        )
        defer {
            NotificationCenter.default.removeObserver(recorder)
        }

        panel.webView.otherMouseDown(with: try makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 3))
        panel.webView.otherMouseUp(with: try makeOtherMouseEvent(type: .otherMouseUp, buttonNumber: 3))

        let snapshot = panel.sessionNavigationHistorySnapshot()
        #expect(recorder.postedObject === panel.webView)
        #expect(recorder.postCount == 1)
        #expect(snapshot.backHistoryURLStrings == ["https://example.com/a"])
        #expect(snapshot.forwardHistoryURLStrings == ["https://example.com/c"])
    }

    @Test("Side-button navigation posts browser click notification")
    func sideButtonNavigationPostsBrowserClickNotification() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let recorder = BrowserClickNotificationRecorder()
        NotificationCenter.default.addObserver(
            recorder,
            selector: #selector(BrowserClickNotificationRecorder.record(_:)),
            name: .webViewDidReceiveClick,
            object: nil
        )
        defer {
            NotificationCenter.default.removeObserver(recorder)
        }

        panel.webView.otherMouseDown(with: try makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 3))
        panel.webView.otherMouseUp(with: try makeOtherMouseEvent(type: .otherMouseUp, buttonNumber: 3))

        #expect(recorder.postedObject === panel.webView)
        #expect(recorder.postCount == 1)
    }

    private func makeOtherMouseEvent(type: NSEvent.EventType, buttonNumber: Int) throws -> NSEvent {
        let cgEventType: CGEventType
        switch type {
        case .otherMouseDown:
            cgEventType = .otherMouseDown
        case .otherMouseUp:
            cgEventType = .otherMouseUp
        default:
            fatalError("Unsupported event type \(type)")
        }

        let mouseButton = try #require(CGMouseButton(rawValue: UInt32(buttonNumber)))
        let cgEvent = try #require(
            CGEvent(
                mouseEventSource: nil,
                mouseType: cgEventType,
                mouseCursorPosition: .zero,
                mouseButton: mouseButton
            )
        )
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))

        return try #require(NSEvent(cgEvent: cgEvent))
    }
}

private final class BrowserClickNotificationRecorder: NSObject {
    var postedObject: AnyObject?
    var postCount = 0

    @objc func record(_ notification: Notification) {
        postCount += 1
        postedObject = notification.object as AnyObject?
    }
}
