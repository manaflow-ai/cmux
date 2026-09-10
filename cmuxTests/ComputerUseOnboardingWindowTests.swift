import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use onboarding windows", .serialized)
struct ComputerUseOnboardingWindowTests {
    @Test @MainActor func offscreenCompanionReturnsWithoutMovingTheOverview() throws {
        var companions: [NSWindow] = []
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService(),
            externalWindowCompanionPresenter: ExternalWindowCompanionPresenter {
                companions.append($0)
                $0.orderBack(nil)
            }
        )
        controller.present()
        defer { controller.dismiss() }
        let main = try #require(NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding"
        } as? ComputerUseOnboardingWindow)
        let originalFrame = main.frame
        controller.configureForPermissionCompanion(
            main, frame: NSRect(origin: originalFrame.origin, size: ComputerUsePermissionCompanionLayout.size)
        )
        let first = try #require(companions.first)
        controller.handleSystemSettingsWindowEvent(.offscreen)
        #expect(!first.isVisible)
        #expect(main.isVisible)
        #expect(main.frame == originalFrame)

        let targetFrame = try #require(NSScreen.screens.first).visibleFrame.insetBy(dx: 40, dy: 40)
        controller.handleSystemSettingsWindowEvent(.visible(.init(
            windowID: 17, ownerProcessIdentifier: 42, frame: targetFrame
        )))

        #expect(companions.count == 2)
        #expect(companions.last?.isVisible == true)
        #expect(main.frame == originalFrame)
    }

    @Test @MainActor func offscreenWindowMetadataPreservesItsIdentity() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderBack(nil)
        let windowID = CGWindowID(window.windowNumber)
        window.orderOut(nil)

        let snapshot = ExternalApplicationWindowTracker.windowSnapshot(
            windowID: windowID,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0
        )

        #expect(snapshot?.windowID == windowID)
    }

    @Test @MainActor func unavailableTargetDismissesOnlyItsCompanion() throws {
        var companion: NSWindow?
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService(),
            externalWindowCompanionPresenter: ExternalWindowCompanionPresenter {
                companion = $0
                $0.orderBack(nil)
            }
        )
        let mainWindow = controller.makeWindow()
        mainWindow.orderBack(nil)
        defer {
            controller.dismiss()
            mainWindow.close()
        }
        let originalFrame = mainWindow.frame
        let wasActive = NSApp.isActive
        controller.configureForPermissionCompanion(
            mainWindow,
            frame: NSRect(origin: mainWindow.frame.origin, size: ComputerUsePermissionCompanionLayout.size)
        )
        let panel = try #require(companion)
        #expect(panel.isVisible)

        controller.handleSystemSettingsWindowEvent(.unavailable)

        #expect(!panel.isVisible)
        #expect(mainWindow.isVisible)
        #expect(mainWindow.frame == originalFrame)
        #expect(NSApp.isActive == wasActive)
    }

    @Test @MainActor func onboardingCreatesFreshWindowAndRootForEveryRun() {
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let first = controller.makeWindow()
        let second = controller.makeWindow()
        defer {
            first.close()
            second.close()
        }

        #expect(first !== second)
        #expect(first.contentView !== second.contentView)
        #expect(first.frame.size == CGSize(width: 600, height: 440))
        #expect(first.contentView?.frame.size == CGSize(width: 600, height: 440))
        #expect(!first.styleMask.contains(.miniaturizable))
        #expect(!first.styleMask.contains(.resizable))
        #expect(!first.hasShadow)
    }

    @Test @MainActor func onboardingContentCannotOutgrowItsAppKitWindow() async {
        let expandedSize = CGSize(width: 600, height: 440)
        let companionSize = ComputerUsePermissionCompanionLayout.size
        let oversizedContent = Color.clear.frame(width: 680, height: 883)
        let window = ComputerUseOnboardingWindow(
            contentRect: NSRect(origin: .zero, size: expandedSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let contentView = ComputerUseOnboardingHostingView(rootView: oversizedContent)
        window.contentView = contentView
        defer { window.close() }
        window.center()
        window.orderBack(nil)
        #expect(window.isVisible)

        // The live failure repeatedly measured the host at 883 points high,
        // then AppKit terminated cmux after its recursive constraint-pass limit
        // was exceeded. Drive real visible SwiftUI/AppKit layout passes at both
        // controller-owned onboarding sizes instead of invoking a frame setter.
        for expectedSize in [expandedSize, companionSize, expandedSize] {
            window.setAppKitOwnedFrame(
                NSRect(origin: window.frame.origin, size: expectedSize),
                display: true
            )
            if expectedSize == companionSize {
                let placementFrame = NSRect(
                    origin: NSPoint(x: window.frame.minX + 12, y: window.frame.minY + 12),
                    size: expectedSize
                )
                window.setFrame(placementFrame, display: true, animate: false)
                #expect(window.frame == placementFrame)
            }
            for _ in 0..<12 {
                contentView.invalidateIntrinsicContentSize()
                contentView.needsLayout = true
                contentView.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await Task.yield()
            }

            #expect(window.frame.size == expectedSize)
            #expect(contentView.frame.size == expectedSize)
        }
    }

    @Test @MainActor func permissionCompanionUsesItsEntireFixedFrameForContent() {
        let companionSize = ComputerUsePermissionCompanionLayout.size
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let mainWindow = controller.makeWindow()
        defer {
            controller.dismiss()
            mainWindow.close()
        }

        controller.configureForPermissionCompanion(
            mainWindow,
            frame: NSRect(origin: mainWindow.frame.origin, size: companionSize)
        )
        let companionWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding.permissionCompanion"
        }

        #expect(mainWindow.frame.size == CGSize(width: 600, height: 440))
        #expect(companionWindow?.frame.size == companionSize)
        #expect(companionWindow?.contentView?.frame.size == companionSize)
        #expect(companionWindow?.contentLayoutRect.size == companionSize)
    }

    @Test @MainActor func permissionCompanionKeepsMainWindowVisibleAndUntouched() {
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let window = controller.makeWindow()
        defer {
            controller.dismiss()
            window.close()
        }
        window.orderBack(nil)
        let expandedStyle = window.styleMask
        let expandedFrame = window.frame

        controller.configureForPermissionCompanion(
            window,
            frame: NSRect(
                origin: window.frame.origin,
                size: ComputerUsePermissionCompanionLayout.size
            )
        )

        #expect(window.isVisible)
        #expect(window.styleMask == expandedStyle)
        #expect(window.frame == expandedFrame)
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            #expect(window.standardWindowButton(buttonType)?.isHidden == false)
        }
    }

    @Test @MainActor func permissionCompanionUsesASeparateBorderlessWindow() {
        let companionSize = ComputerUsePermissionCompanionLayout.size
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let mainWindow = controller.makeWindow()
        defer {
            controller.dismiss()
            mainWindow.close()
        }
        mainWindow.center()
        mainWindow.orderBack(nil)
        let mainFrame = mainWindow.frame
        let destinationFrame = NSRect(
            x: mainFrame.maxX + 24,
            y: mainFrame.midY - companionSize.height / 2,
            width: companionSize.width,
            height: companionSize.height
        )

        controller.configureForPermissionCompanion(
            mainWindow,
            frame: destinationFrame
        )

        let companionWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding.permissionCompanion"
        }
        #expect(mainWindow.isVisible)
        #expect(mainWindow.frame == mainFrame)
        #expect(companionWindow !== mainWindow)
        #expect(companionWindow?.styleMask == [.borderless, .nonactivatingPanel])
        #expect(companionWindow?.frame == destinationFrame)
        #expect(companionWindow?.contentLayoutRect.size == companionSize)
        #expect(companionWindow?.standardWindowButton(.closeButton) == nil)
        #expect(companionWindow?.standardWindowButton(.miniaturizeButton) == nil)
        #expect(companionWindow?.standardWindowButton(.zoomButton) == nil)
        #expect(companionWindow?.hasShadow == false)
    }

    @Test @MainActor func completionClosesCompanionAndRevealsCenteredMainWindowWithoutReturnGlide() {
        let companionSize = ComputerUsePermissionCompanionLayout.size
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let mainWindow = controller.makeWindow()
        defer {
            controller.dismiss()
            mainWindow.close()
        }
        mainWindow.center()
        mainWindow.orderBack(nil)
        let originalMainFrame = mainWindow.frame
        let destinationFrame = NSRect(
            x: originalMainFrame.maxX + 24,
            y: originalMainFrame.midY - companionSize.height / 2,
            width: companionSize.width,
            height: companionSize.height
        )
        controller.configureForPermissionCompanion(
            mainWindow,
            frame: destinationFrame
        )
        let companionWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding.permissionCompanion"
        }
        #expect(companionWindow?.isVisible == true)
        let visibleFrame = mainWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? originalMainFrame
        let expandedSize = CGSize(width: 600, height: 440)
        let expectedCenteredFrame = NSRect(
            x: visibleFrame.midX - expandedSize.width / 2,
            y: visibleFrame.midY - expandedSize.height / 2,
            width: expandedSize.width,
            height: expandedSize.height
        )

        controller.revealExpandedOnboarding(
            mainWindow,
            resetStep: false,
            completed: true
        )

        #expect(companionWindow?.isVisible == false)
        #expect(mainWindow.isVisible)
        #expect(mainWindow.frame.size == expandedSize)
        #expect(abs(mainWindow.frame.midX - expectedCenteredFrame.midX) <= 0.5)
        #expect(abs(mainWindow.frame.midY - expectedCenteredFrame.midY) <= 0.5)
    }

    /// Regression: interacting with the companion beside System Settings
    /// (dragging the helper tile, pressing Back) must never activate cmux.
    /// Activation raised the main terminal window over the permission pane the
    /// user was dragging into.
    @Test @MainActor func permissionCompanionNeverActivatesTheApp() {
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let mainWindow = controller.makeWindow()
        defer {
            controller.dismiss()
            mainWindow.close()
        }

        controller.configureForPermissionCompanion(
            mainWindow,
            frame: NSRect(
                origin: .zero,
                size: ComputerUsePermissionCompanionLayout.size
            )
        )
        let companionWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding.permissionCompanion"
        }

        let companionPanel = companionWindow as? NSPanel
        #expect(companionPanel != nil)
        #expect(companionPanel?.styleMask.contains(.nonactivatingPanel) == true)
        #expect(companionPanel?.becomesKeyOnlyIfNeeded == true)
        #expect(companionPanel?.hidesOnDeactivate == false)
        #expect(companionPanel?.level == .floating)
        #expect(companionPanel?.collectionBehavior.contains(.moveToActiveSpace) == false)
        #expect(companionPanel?.collectionBehavior.contains(.managed) == true)
        #expect(companionPanel?.collectionBehavior.contains(.canJoinAllSpaces) == false)
    }

    /// Regression: Command-Tab must not remove the companion. Its floating
    /// level keeps it available while another application is active.
    @Test @MainActor func permissionCompanionRemainsWhenAnotherApplicationActivates() throws {
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        controller.present()
        defer { controller.dismiss() }

        let mainWindow = try #require(NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding"
        } as? ComputerUseOnboardingWindow)
        #expect(mainWindow.level == .normal)
        #expect(mainWindow.collectionBehavior.contains(.managed))
        controller.configureForPermissionCompanion(
            mainWindow,
            frame: NSRect(
                origin: mainWindow.frame.origin,
                size: ComputerUsePermissionCompanionLayout.size
            )
        )
        let companionWindow = try #require(NSApp.windows.first {
            $0.identifier?.rawValue
                == "cmux.computerUse.onboarding.permissionCompanion"
        })
        #expect(companionWindow.isVisible)

        controller.handleSystemSettingsWindowEvent(.hidden)

        #expect(companionWindow.isVisible)
        #expect(mainWindow.isVisible)
    }

    @Test @MainActor func externalWindowCompanionUsesFloatingNonactivatingPresentation() {
        var orderedWindow: NSWindow?
        let presenter = ExternalWindowCompanionPresenter { window in
            orderedWindow = window
        }
        let companionWindow = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer { companionWindow.close() }
        companionWindow.level = .normal
        companionWindow.collectionBehavior = [.canJoinAllSpaces]
        companionWindow.hidesOnDeactivate = true

        presenter.present(companionWindow)

        #expect(orderedWindow === companionWindow)
        #expect(companionWindow.level == .floating)
        #expect(companionWindow.hidesOnDeactivate == false)
        #expect(!companionWindow.collectionBehavior.contains(.moveToActiveSpace))
        #expect(companionWindow.collectionBehavior.contains(.managed))
        #expect(!companionWindow.collectionBehavior.contains(.canJoinAllSpaces))
    }

    @Test @MainActor func permissionCompanionUsesReusablePresenter() {
        var presentedWindow: NSWindow?
        let presenter = ExternalWindowCompanionPresenter { window in
            presentedWindow = window
        }
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService(),
            externalWindowCompanionPresenter: presenter
        )
        let mainWindow = controller.makeWindow()
        defer {
            controller.dismiss()
            mainWindow.close()
        }

        controller.configureForPermissionCompanion(
            mainWindow,
            frame: NSRect(
                origin: mainWindow.frame.origin,
                size: ComputerUsePermissionCompanionLayout.size
            )
        )

        #expect(presentedWindow?.identifier?.rawValue
            == "cmux.computerUse.onboarding.permissionCompanion")
    }
}
