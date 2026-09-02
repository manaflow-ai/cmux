import AppKit
@testable import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxWorkspaces
import QuartzCore
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct WindowAppearanceSnapshotPaneBackgroundTests {
    /// Verifies translucent hosting keeps a filterless root below pane-local OSC fills.
    @MainActor
    @Test func transparentRootBackdropUsesOrdinaryLayerBelowWindowContent() throws {
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 180)
        let contentView = NSView(frame: bounds)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView

        let plan = WindowBackdropPlan(
            hostingPhase: .transparentRootBackdrop,
            windowBackgroundColor: .clear,
            windowIsOpaque: false,
            rootPolicy: .ghosttyTerminalBackdrop(
                color: .systemPurple,
                opacity: 0.42,
                renderingMode: .windowHostBackdrop
            ),
            glass: nil,
            shouldApplyGhosttyCompositorBlur: false
        )

        _ = AppWindowChromeComposition().backdropController.apply(plan: plan, to: window)

        let themeFrame = try #require(contentView.superview)
        let rootBackdrop = try #require(
            themeFrame.subviews.first { $0 is WindowRootBackdropView } as? WindowRootBackdropView
        )
        let rootIndex = try #require(themeFrame.subviews.firstIndex { $0 === rootBackdrop })
        let contentIndex = try #require(themeFrame.subviews.firstIndex { $0 === contentView })
        let rootColor = try #require(
            rootBackdrop.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )

        #expect(rootIndex < contentIndex)
        #expect(abs(rootColor.alphaComponent - 0.42) < 0.0001)
        #expect(rootBackdrop.layer?.isOpaque == false)
        #expect(!rootBackdrop.layerUsesCoreImageFilters)
        #expect(rootBackdrop.compositingFilter == nil)
    }

    /// Verifies late OSC 11 changes paint through ordinary out-of-process layer compositing.
    @MainActor
    @Test func lateOSCOverrideUsesPaneLayerWithoutCoreImageFilters() throws {
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 180)
        let host = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: bounds))
        host.frame = bounds

        let contentView = NSView(frame: bounds)
        contentView.addSubview(host)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let paneBackground = try #require(
            host.subviews.first { $0 is TerminalPaneBackgroundView } as? TerminalPaneBackgroundView
        )
        #expect(!usesInProcessCoreImageCompositing(in: host))

        host.setBackgroundColor(try #require(NSColor(hex: "#EEF5F8")))

        let paintedColor = try #require(paneBackground.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(paintedColor.hexString(includeAlpha: true) == "#EEF5F8FF")
        #expect(paneBackground.layer?.isOpaque == true)
        #expect(!usesInProcessCoreImageCompositing(in: host))

        host.setBackgroundColor(.clear)
        let resetColor = try #require(paneBackground.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(resetColor.alphaComponent == 0)
        #expect(paneBackground.layer?.isOpaque == false)
        #expect(!usesInProcessCoreImageCompositing(in: host))
    }

    /// Verifies portal geometry and visibility remain the root mask's source of truth.
    @MainActor
    @Test func portalReconcilesRootExclusionOnNoninteractiveMoveResetAndHide() async throws {
        let bounds = NSRect(x: 0, y: 0, width: 360, height: 180)
        let contentView = NSView(frame: bounds)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        let backdropController = AppWindowChromeComposition().backdropController
        _ = backdropController.apply(
            plan: WindowBackdropPlan(
                hostingPhase: .transparentRootBackdrop,
                windowBackgroundColor: .clear,
                windowIsOpaque: false,
                rootPolicy: .ghosttyTerminalBackdrop(
                    color: .systemPurple,
                    opacity: 0.42,
                    renderingMode: .windowHostBackdrop
                ),
                glass: nil,
                shouldApplyGhosttyCompositorBlur: false
            ),
            to: window
        )

        let themeFrame = try #require(contentView.superview)
        themeFrame.layoutSubtreeIfNeeded()
        let root = try #require(
            themeFrame.subviews.first { $0 is WindowRootBackdropView } as? WindowRootBackdropView
        )
        let anchor = NSView(frame: NSRect(x: 30, y: 35, width: 80, height: 60))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(origin: .zero, size: anchor.bounds.size))
        )
        hosted.setBackgroundColor(
            .systemOrange.withAlphaComponent(0.42),
            excludesSharedRootBackdrop: true
        )
        let portal = WindowTerminalPortal(window: window)
        defer { portal.tearDown() }
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        let initialPoint = anchor.convert(
            NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY),
            to: nil
        )
        #expect(!(try rootMaskShowsBackdrop(atWindowPoint: initialPoint, in: root)))

        anchor.frame.origin.x += 150
        portal.synchronizeHostedViewForAnchor(anchor)
        let movedPoint = anchor.convert(
            NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY),
            to: nil
        )
        #expect(try rootMaskShowsBackdrop(atWindowPoint: initialPoint, in: root))
        #expect(!(try rootMaskShowsBackdrop(atWindowPoint: movedPoint, in: root)))

        hosted.setBackgroundColor(.clear, excludesSharedRootBackdrop: false)
        try await waitForRootMask(
            atWindowPoint: movedPoint,
            in: root,
            showsBackdrop: true
        )

        hosted.setBackgroundColor(
            .systemOrange.withAlphaComponent(0.42),
            excludesSharedRootBackdrop: true
        )
        try await waitForRootMask(
            atWindowPoint: movedPoint,
            in: root,
            showsBackdrop: false
        )

        portal.hideEntry(forHostedId: ObjectIdentifier(hosted))
        #expect(try rootMaskShowsBackdrop(atWindowPoint: movedPoint, in: root))
    }

    /// Verifies pane-local OSC colors paint the surface without replacing the shared window root.
    @Test func surfaceOSCOverrideUsesHostFillAndKeepsSharedWindowRootDefault() throws {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: true,
            backgroundHex: "#272822",
            backgroundOpacity: 1.0
        )
        let override = try #require(NSColor(hex: "#E6BE78"))
        let fillPlan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: snapshot.terminalRenderingMode,
            surfaceBackgroundColor: override,
            defaultBackgroundColor: snapshot.terminalBackgroundColor,
            backgroundOpacity: Double(snapshot.terminalBackgroundOpacity),
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )
        let windowRoot = snapshot.windowRootBackdropResolution(
            surfaceBackgroundColor: override
        )

        #expect(fillPlan.owner == .surfaceHostLayer)
        #expect(fillPlan.hostLayerColor.hexString(includeAlpha: true) == "#E6BE78FF")
        #expect(!fillPlan.excludesSharedRootBackdrop)
        #expect(windowRoot.source == "defaultBackground(surfaceOverrideLocal)")
        #expect(windowRoot.overrideHex == "#E6BE78")
        #expect(windowRoot.snapshot.terminalBackgroundColor.hexString() == "#272822")
        #expect(
            windowRoot.snapshot.compositedTerminalBackgroundColor.hexString(includeAlpha: true) == "#272822FF"
        )
        #expect(
            windowRoot.snapshot.windowGlassSettings.terminalGlassTintColor?.hexString(includeAlpha: true) == "#272822FF"
        )
    }

    /// Verifies fractional pane fills exclude the root while the opaque threshold does not.
    @Test func surfaceOSCOverrideExclusionTracksOpaqueHostingThreshold() throws {
        let override = try #require(NSColor(hex: "#E6BE78"))
        let defaultBackground = try #require(NSColor(hex: "#272822"))
        let translucent = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: override,
            defaultBackgroundColor: defaultBackground,
            backgroundOpacity: 0.42,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )
        let effectivelyOpaque = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: override,
            defaultBackgroundColor: defaultBackground,
            backgroundOpacity: 0.999,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        #expect(translucent.excludesSharedRootBackdrop)
        #expect(abs(translucent.hostLayerColor.alphaComponent - 0.42) < 0.0001)
        #expect(!effectivelyOpaque.excludesSharedRootBackdrop)
        #expect(abs(effectivelyOpaque.hostLayerColor.alphaComponent - 1) < 0.0001)
    }

    @MainActor
    private func usesInProcessCoreImageCompositing(in view: NSView) -> Bool {
        view.layerUsesCoreImageFilters
            || view.compositingFilter != nil
            || view.subviews.contains(where: usesInProcessCoreImageCompositing)
    }

    @MainActor
    private func rootMaskShowsBackdrop(
        atWindowPoint point: NSPoint,
        in root: WindowRootBackdropView
    ) throws -> Bool {
        root.superview?.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let mask = try #require(root.layer?.mask as? CAShapeLayer)
        let path = try #require(mask.path)
        return path.contains(root.convert(point, from: nil), using: .evenOdd)
    }

    @MainActor
    private func waitForRootMask(
        atWindowPoint point: NSPoint,
        in root: WindowRootBackdropView,
        showsBackdrop expected: Bool
    ) async throws {
        for _ in 0..<32 {
            let isShowingBackdrop = try rootMaskShowsBackdrop(atWindowPoint: point, in: root)
            if isShowingBackdrop == expected {
                return
            }
            await Task.yield()
        }
        let isShowingBackdrop = try rootMaskShowsBackdrop(atWindowPoint: point, in: root)
        #expect(
            isShowingBackdrop == expected,
            "Deferred root-mask publication did not reach the expected state"
        )
    }

    private func makeSnapshot(
        unifySurfaceBackdrops: Bool,
        backgroundHex: String,
        backgroundOpacity: CGFloat
    ) -> WindowAppearanceSnapshot {
        let backgroundColor = NSColor(hex: backgroundHex) ?? .black
        return WindowAppearanceSnapshot(
            terminalBackgroundColor: backgroundColor,
            terminalBackgroundOpacity: backgroundOpacity,
            terminalBackgroundBlur: .disabled,
            terminalRenderingMode: .windowHostBackdrop,
            unifySurfaceBackdrops: unifySurfaceBackdrops,
            sidebarSettings: SidebarBackdropSettingsSnapshot(
                materialRawValue: SidebarMaterialOption.sidebar.rawValue,
                blendModeRawValue: SidebarBlendModeOption.withinWindow.rawValue,
                stateRawValue: SidebarStateOption.followWindow.rawValue,
                tintHex: "#000000",
                tintHexLight: nil,
                tintHexDark: nil,
                tintOpacity: 0.18,
                cornerRadius: 0,
                blurOpacity: 1,
                colorScheme: .dark
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: SidebarBlendModeOption.withinWindow.rawValue,
                isEnabled: false,
                tintHex: "#000000",
                tintOpacity: 0.03,
                terminalBackgroundBlur: .disabled,
                terminalGlassTintColor: backgroundColor.withAlphaComponent(backgroundOpacity)
            )
        )
    }
}
