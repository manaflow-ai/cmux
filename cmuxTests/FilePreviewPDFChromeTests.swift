import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import XCTest
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications
// Selective imports: the app target also defines AppIconMode/StoredShortcut/etc.,
// so a blanket `import CmuxSettings` here makes those names ambiguous. Import only
// the settings symbols this file needs.
import struct CmuxSettings.AccountCatalogSection
import struct CmuxSettings.AppCatalogSection
import struct CmuxSettings.FileRouteSettingsStore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class FilePreviewPDFChromeNotificationFlag: @unchecked Sendable {
    var didNotify = false
}


@MainActor
@Suite(.serialized)
final class FilePreviewPDFChromeTests {
    @Test func testChromeHostsAcceptFirstMouse() {
        let host = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))

        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
    }

    #if DEBUG
    @Test func testPDFChromeStyleVariantPersistsForDebugWindow() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.string(forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
        let notificationFlag = FilePreviewPDFChromeNotificationFlag()
        let observer = NotificationCenter.default.addObserver(
            forName: .filePreviewPDFChromeStyleDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationFlag.didNotify = true
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            if let previousValue {
                defaults.set(previousValue, forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
            } else {
                defaults.removeObject(forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
            }
        }

        defaults.removeObject(forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
        XCTAssertEqual(FilePreviewPDFChromeStyleVariant.current(), .liquidGlass)

        FilePreviewPDFChromeStyleVariant.thinOutline.persist()
        XCTAssertEqual(FilePreviewPDFChromeStyleVariant.current(), .thinOutline)
        XCTAssertTrue(notificationFlag.didNotify)
    }
    #endif

    @Test func testPDFChromeControlsUseSwiftUILiquidGlassHosts() throws {
        let container = FilePreviewPDFContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let mirror = Mirror(reflecting: container)
        let sidebarChromeHost = try XCTUnwrap(
            mirror.descendant("sidebarChromeHost") as? FilePreviewPDFChromeHostingView
        )
        let zoomChromeHost = try XCTUnwrap(
            mirror.descendant("zoomChromeHost") as? FilePreviewPDFChromeHostingView
        )
        let chromeHost = try XCTUnwrap(
            mirror.descendant("chromeHost") as? FilePreviewPDFChromeHostView
        )

        XCTAssertFalse(sidebarChromeHost.isHidden)
        XCTAssertFalse(zoomChromeHost.isHidden)
        XCTAssertEqual(chromeHost.interactiveOverlayViews.count, 2)
        XCTAssertTrue(chromeHost.interactiveOverlayViews.contains { $0 === sidebarChromeHost })
        XCTAssertTrue(chromeHost.interactiveOverlayViews.contains { $0 === zoomChromeHost })
    }

    @Test func testPDFChromeControlsAreHitTestedAbovePDFContent() throws {
        let container = FilePreviewPDFContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let hostView = NSView(frame: container.frame)
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: hostView.topAnchor),
            container.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
        window.layoutIfNeeded()
        hostView.needsLayout = true
        hostView.layoutSubtreeIfNeeded()
        container.needsLayout = true
        container.layout()
        container.layoutSubtreeIfNeeded()

        let mirror = Mirror(reflecting: container)
        let chromeHost = try XCTUnwrap(mirror.descendant("chromeHost") as? NSView)
        let sidebarChromeHost = try XCTUnwrap(mirror.descendant("sidebarChromeHost") as? NSView)
        let zoomChromeHost = try XCTUnwrap(mirror.descendant("zoomChromeHost") as? NSView)
        let contentHost = mirror.descendant("contentHost") as? NSView
        chromeHost.needsLayout = true
        chromeHost.layoutSubtreeIfNeeded()
        sidebarChromeHost.layoutSubtreeIfNeeded()
        zoomChromeHost.layoutSubtreeIfNeeded()

        let leftProbe = chromeHost.convert(
            NSPoint(x: sidebarChromeHost.frame.midX, y: sidebarChromeHost.frame.midY),
            to: container
        )
        let rightProbe = chromeHost.convert(
            NSPoint(x: zoomChromeHost.frame.midX, y: zoomChromeHost.frame.midY),
            to: container
        )
        let shareProbe = chromeHost.convert(
            NSPoint(x: zoomChromeHost.frame.maxX - 20, y: zoomChromeHost.frame.midY),
            to: container
        )
        let leftChromeHit = container.hitTest(leftProbe)
        let rightChromeHit = container.hitTest(rightProbe)
        let shareChromeHit = container.hitTest(shareProbe)
        let debugFrames = "container=\(container.frame) content=\(String(describing: contentHost?.frame)) chromeHost=\(chromeHost.frame) left=\(sidebarChromeHost.frame) right=\(zoomChromeHost.frame) leftProbe=\(leftProbe) rightProbe=\(rightProbe) shareProbe=\(shareProbe) leftHit=\(String(describing: leftChromeHit)) rightHit=\(String(describing: rightChromeHit)) shareHit=\(String(describing: shareChromeHit))"

        XCTAssertTrue(isView(leftChromeHit, inside: sidebarChromeHost), debugFrames)
        XCTAssertTrue(isView(rightChromeHit, inside: zoomChromeHost), debugFrames)
        XCTAssertTrue(isView(shareChromeHit, inside: zoomChromeHost), debugFrames)
    }

    @Test func testThumbnailSidebarUsesFullWidthSingleColumnLayout() throws {
        let sidebar = FilePreviewPDFThumbnailSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))

        sidebar.layoutSubtreeIfNeeded()

        let mirror = Mirror(reflecting: sidebar)
        let collectionView = try XCTUnwrap(
            mirror.descendant("collectionView") as? NSCollectionView
        )
        let flowLayout = try XCTUnwrap(
            mirror.descendant("flowLayout") as? NSCollectionViewFlowLayout
        )
        let itemSize = sidebar.collectionView(
            collectionView,
            layout: flowLayout,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        )

        XCTAssertGreaterThanOrEqual(itemSize.width, sidebar.bounds.width)
        XCTAssertGreaterThan(itemSize.width, sidebar.bounds.width / 2)
    }

    @Test func testThumbnailSidebarPreferredWidthShrinksToPortraitContent() throws {
        let document = try makePDFDocument(pageSizes: [NSSize(width: 80, height: 160)])

        let width = FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: document)

        XCTAssertEqual(width, FilePreviewPDFSizing.minimumThumbnailSidebarWidth, accuracy: 0.001)
    }

    @Test func testThumbnailSidebarPreferredWidthUsesThumbnailMinimumWithoutDocument() {
        let width = FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: nil)

        XCTAssertEqual(width, FilePreviewPDFSizing.minimumThumbnailSidebarWidth, accuracy: 0.001)
    }

    @Test func testThumbnailSidebarPreferredWidthExpandsForLandscapeContent() throws {
        let document = try makePDFDocument(pageSizes: [NSSize(width: 160, height: 90)])

        let width = FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: document)

        XCTAssertGreaterThan(width, 200)
        XCTAssertLessThan(width, FilePreviewPDFSizing.maximumSidebarWidth)
    }

    @Test func testSidebarWidthClampReservesMinimumContentWidth() {
        let width = FilePreviewPDFSizing.clampedSidebarWidth(
            240,
            containerWidth: FilePreviewPDFSizing.minimumSidebarWidth
                + FilePreviewPDFSizing.minimumContentWidth
                - 40,
            dividerThickness: 1
        )

        XCTAssertEqual(width, FilePreviewPDFSizing.minimumSidebarWidth, accuracy: 0.001)
    }

    @Test func testThumbnailSidebarKeepsSingleSelectionWhenProgrammaticallyChangingPage() throws {
        let sidebar = FilePreviewPDFThumbnailSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let document = try makePDFDocument(pageCount: 5)

        sidebar.setDocument(document)
        sidebar.selectPage(at: 1, scrollToVisible: false)
        sidebar.selectPage(at: 3, scrollToVisible: false)

        let mirror = Mirror(reflecting: sidebar)
        let collectionView = try XCTUnwrap(
            mirror.descendant("collectionView") as? NSCollectionView
        )

        let previousItem = sidebar.collectionView(
            collectionView,
            itemForRepresentedObjectAt: IndexPath(item: 1, section: 0)
        )
        let currentItem = sidebar.collectionView(
            collectionView,
            itemForRepresentedObjectAt: IndexPath(item: 3, section: 0)
        )

        XCTAssertFalse(try thumbnailItemSelectedState(previousItem))
        XCTAssertTrue(try thumbnailItemSelectedState(currentItem))
    }

    @Test func testPDFViewportOriginUsesVisibleClipWidth() {
        let origin = FilePreviewViewport.clampedClipOrigin(
            documentPoint: CGPoint(x: 500, y: 700),
            anchorOffsetInClip: CGPoint(x: 200, y: 300),
            documentBounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_400),
            clipSize: CGSize(width: 400, height: 600)
        )

        XCTAssertEqual(origin.x, 300, accuracy: 0.001)
        XCTAssertEqual(origin.y, 400, accuracy: 0.001)
    }

    @Test func testPDFViewportOriginCentersSmallerDocuments() {
        let origin = FilePreviewViewport.clampedClipOrigin(
            documentPoint: CGPoint(x: 54, y: 224.5),
            anchorOffsetInClip: CGPoint(x: 300, y: 400),
            documentBounds: CGRect(x: 0, y: 0, width: 108, height: 449),
            clipSize: CGSize(width: 600, height: 800)
        )

        XCTAssertEqual(origin.x, -246, accuracy: 0.001)
        XCTAssertEqual(origin.y, -175.5, accuracy: 0.001)
    }

    private func isView(_ view: NSView?, inside container: NSView) -> Bool {
        var current = view
        while let next = current {
            if next === container {
                return true
            }
            current = next.superview
        }
        return false
    }

    private func makePDFDocument(pageCount: Int) throws -> PDFDocument {
        try makePDFDocument(pageSizes: Array(repeating: NSSize(width: 80, height: 80), count: pageCount))
    }

    private func makePDFDocument(pageSizes: [NSSize]) throws -> PDFDocument {
        let document = PDFDocument()
        for (pageIndex, pageSize) in pageSizes.enumerated() {
            let image = NSImage(size: pageSize)
            image.lockFocus()
            NSColor(
                calibratedHue: CGFloat(pageIndex) / CGFloat(max(pageSizes.count, 1)),
                saturation: 0.5,
                brightness: 0.8,
                alpha: 1
            ).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: pageSize)).fill()
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            document.insert(page, at: pageIndex)
        }
        return document
    }

    private func thumbnailItemSelectedState(_ item: NSCollectionViewItem) throws -> Bool {
        try XCTUnwrap(Mirror(reflecting: item.view).descendant("isSelectedForPreview") as? Bool)
    }
}
