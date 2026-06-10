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
@Suite struct MainWindowHostingViewTests {
    @Test func testReportsPolicyMinimumInsteadOfChildMinimum() {
        _ = NSApplication.shared

        let root = HStack(spacing: 0) {
            Color.clear
                .frame(width: 900, height: 240)
        }
            .frame(
                minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
                minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight)
            )
        let hostingView = MainWindowHostingView(rootView: root)
        let expectedMinimumWidth = CGFloat(SessionPersistencePolicy.minimumWindowWidth)

        for width in [520, 1_200] as [CGFloat] {
            hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 500)
            hostingView.layoutSubtreeIfNeeded()

            #expect(
                abs(hostingView.fittingSize.width - expectedMinimumWidth) <= 0.001,
                "Main window AppKit fitting width must equal minimumWindowWidth at \(width)pt."
            )
            #expect(
                abs(hostingView.intrinsicContentSize.width - expectedMinimumWidth) <= 0.001,
                "Main window AppKit intrinsic width must equal minimumWindowWidth at \(width)pt."
            )
        }
    }

    @Test func testStandardFrameKeepsAppKitDefaultFrameWhenLargerThanPolicyMinimum() {
        let defaultFrame = NSRect(x: 20, y: 40, width: 1_000, height: 700)

        #expect(CmuxMainWindow.standardFrame(forDefaultFrame: defaultFrame) == defaultFrame)
    }

    @Test func testStandardFrameDoesNotShrinkBelowPolicyMinimum() {
        let tinyDefaultFrame = NSRect(x: 20, y: 40, width: 100, height: 80)
        let standardFrame = CmuxMainWindow.standardFrame(forDefaultFrame: tinyDefaultFrame)

        #expect(standardFrame.origin == tinyDefaultFrame.origin)
        #expect(standardFrame.width == CGFloat(SessionPersistencePolicy.minimumWindowWidth))
        #expect(standardFrame.height == CGFloat(SessionPersistencePolicy.minimumWindowHeight))
    }
}

#endif
