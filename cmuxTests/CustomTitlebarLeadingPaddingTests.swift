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


@Suite("Custom titlebar leading padding")
struct CustomTitlebarLeadingPaddingTests {
    @Test func hiddenSidebarUsesMinimumSidebarTitleInset() {
        #expect(
            ContentView.customTitlebarLeadingPadding(
                isFullScreen: false,
                isSidebarVisible: false,
                sidebarWidth: 216,
                minimumSidebarWidth: 216,
                titlebarLeadingInset: 82
            ) == 228
        )
    }

    @Test func minimumWidthVisibleSidebarMatchesHiddenSidebarTitleInset() {
        let hidden = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: false,
            sidebarWidth: 216,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )
        let visible = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: true,
            sidebarWidth: 216,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )

        #expect(visible == hidden)
    }

    @Test func widerSidebarPushesTitlebarContentRight() {
        let hidden = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: false,
            sidebarWidth: 216,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )
        let visible = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: true,
            sidebarWidth: 320,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )

        #expect(visible > hidden)
        #expect(visible == 332)
    }

    @Test func fullscreenHiddenSidebarKeepsCompactInset() {
        #expect(
            ContentView.customTitlebarLeadingPadding(
                isFullScreen: true,
                isSidebarVisible: false,
                sidebarWidth: 216,
                minimumSidebarWidth: 216,
                titlebarLeadingInset: 82
            ) == 8
        )
    }
}


#endif
