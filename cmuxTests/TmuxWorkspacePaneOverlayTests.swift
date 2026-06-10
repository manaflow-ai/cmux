import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG


@MainActor
final class TmuxWorkspacePaneOverlayTests: XCTestCase {
    func testTmuxWorkspacePaneOverlayModelTracksFlashReason() {
        let model = TmuxWorkspacePaneOverlayModel()
        let initialState = TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            flashToken: 1,
            flashReason: .notificationArrival
        )
        let laterState = TmuxWorkspacePaneOverlayRenderState(
            workspaceId: initialState.workspaceId,
            unreadRects: [],
            flashRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            flashToken: 2,
            flashReason: .navigation
        )

        model.apply(initialState)
        model.apply(laterState)

        XCTAssertEqual(model.flashReason, .navigation)
    }

    func testTmuxWorkspacePaneOverlayModelAnimatesFlashAfterWorkspaceSwitchBackWhenTokenChanges() {
        let model = TmuxWorkspacePaneOverlayModel()
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let firstFlashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: firstWorkspaceId,
            unreadRects: [firstFlashRect],
            flashRect: firstFlashRect,
            flashToken: 0,
            flashReason: nil
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: secondWorkspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 0,
            flashReason: nil
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: firstWorkspaceId,
                unreadRects: [],
                flashRect: firstFlashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    func testTmuxWorkspacePaneOverlayModelWaitsForFlashRectBeforeConsumingToken() {
        let model = TmuxWorkspacePaneOverlayModel()
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let firstFlashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: firstWorkspaceId,
            unreadRects: [],
            flashRect: firstFlashRect,
            flashToken: 0,
            flashReason: nil
        ))
        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: secondWorkspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 0,
            flashReason: nil
        ))

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: firstWorkspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 1,
            flashReason: .unreadIndicatorDismiss
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: firstWorkspaceId,
                unreadRects: [],
                flashRect: firstFlashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    func testTmuxWorkspacePaneOverlayModelAnimatesFirstObservedFlashToken() {
        let model = TmuxWorkspacePaneOverlayModel()
        let workspaceId = UUID()
        let flashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: workspaceId,
                unreadRects: [],
                flashRect: flashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    func testTmuxWorkspacePaneOverlayModelWaitsForRectBeforeFirstObservedFlashToken() {
        let model = TmuxWorkspacePaneOverlayModel()
        let workspaceId = UUID()
        let flashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: workspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 1,
            flashReason: .unreadIndicatorDismiss
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: workspaceId,
                unreadRects: [],
                flashRect: flashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    func testAllFlashReasonsUseNotificationRingAccent() {
        let reasons: [WorkspaceAttentionFlashReason] = [
            .navigation,
            .notificationArrival,
            .notificationDismiss,
            .unreadIndicatorDismiss,
            .debug,
        ]

        for reason in reasons {
            XCTAssertEqual(
                WorkspaceAttentionCoordinator.flashStyle(for: reason).accent,
                WorkspaceAttentionCoordinator.notificationRingStyle.accent
            )
        }
    }

    func testFocusFlashUsesNotificationRingColor() {
        XCTAssertEqual(
            WorkspaceAttentionCoordinator.flashStyle(for: .navigation).accent.strokeColor.hexString(),
            WorkspaceAttentionCoordinator.notificationRingStyle.accent.strokeColor.hexString()
        )
    }

    func testTmuxWorkspacePaneExactRectReturnsContentRelativeFrameForDescendantView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected contentView")
            return
        }

        let targetView = NSView(frame: NSRect(x: 120, y: 48, width: 300, height: 200))
        contentView.addSubview(targetView)

        XCTAssertEqual(
            ContentView.tmuxWorkspacePaneExactRect(for: targetView, in: contentView),
            CGRect(x: 120, y: 48, width: 300, height: 200)
        )
    }
}

#endif
