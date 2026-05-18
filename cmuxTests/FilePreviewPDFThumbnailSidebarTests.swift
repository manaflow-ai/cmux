import XCTest
import AppKit
import PDFKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FilePreviewPDFThumbnailSidebarTests: XCTestCase {
    func testPrimaryClickSelectsItemWithoutScrollingSidebar() throws {
        let sidebar = FilePreviewPDFThumbnailSidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 420))
        let document = try makePDFDocument(pageCount: 8)
        var selectedPageIndex: Int?
        sidebar.onSelectPage = { page in
            selectedPageIndex = document.index(for: page)
        }
        sidebar.setDocument(document)
        sidebar.layoutSubtreeIfNeeded()

        let mirror = Mirror(reflecting: sidebar)
        let scrollView = try XCTUnwrap(mirror.descendant("scrollView") as? NSScrollView)
        let collectionView = try XCTUnwrap(mirror.descendant("collectionView") as? NSCollectionView)
        collectionView.layoutSubtreeIfNeeded()

        let targetIndexPath = IndexPath(item: 1, section: 0)
        let attributes = try XCTUnwrap(collectionView.layoutAttributesForItem(at: targetIndexPath))
        let pointInCollection = NSPoint(x: attributes.frame.midX, y: attributes.frame.midY)
        let pointInWindow = collectionView.convert(pointInCollection, to: nil)
        let originalScrollOrigin = scrollView.contentView.bounds.origin

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        collectionView.mouseDown(with: event)

        XCTAssertEqual(selectedPageIndex, targetIndexPath.item)
        XCTAssertEqual(Mirror(reflecting: sidebar).descendant("selectedPageIndex") as? Int, targetIndexPath.item)
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, originalScrollOrigin.x, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, originalScrollOrigin.y, accuracy: 0.001)
    }

    func testVisiblePageResolverUsesProgrammaticPageJumpTarget() throws {
        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true

        let document = try makePDFDocument(pageCount: 8)
        pdfView.document = document
        pdfView.layoutDocumentView()
        pdfView.layoutSubtreeIfNeeded()

        let targetPageIndex = 4
        let targetPage = try XCTUnwrap(document.page(at: targetPageIndex))
        pdfView.go(to: targetPage)
        pdfView.layoutDocumentView()
        pdfView.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(findScrollView(in: pdfView))
        let resolvedPage = try XCTUnwrap(
            FilePreviewPDFVisiblePageResolver.topVisiblePage(in: pdfView, scrollView: scrollView)
        )
        XCTAssertEqual(document.index(for: resolvedPage), targetPageIndex)
    }

    func testVisiblePageResolverSelectsLastPageAtDocumentBottom() {
        let pageIndex = FilePreviewPDFVisiblePageResolver.verticalDocumentEdgePageIndex(
            pageCount: 8,
            clipBounds: CGRect(x: 0, y: 1500, width: 500, height: 500),
            documentBounds: CGRect(x: 0, y: 0, width: 500, height: 2000),
            isFlipped: true
        )

        XCTAssertEqual(pageIndex, 7)
    }

    func testVisiblePageResolverSelectsLastPageAtNonFlippedDocumentBottom() {
        let pageIndex = FilePreviewPDFVisiblePageResolver.verticalDocumentEdgePageIndex(
            pageCount: 8,
            clipBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            documentBounds: CGRect(x: 0, y: 0, width: 500, height: 2000),
            isFlipped: false
        )

        XCTAssertEqual(pageIndex, 7)
    }

    private func makePDFDocument(pageCount: Int) throws -> PDFDocument {
        let document = PDFDocument()
        for pageIndex in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 80, height: 80))
            image.lockFocus()
            NSColor(
                calibratedHue: CGFloat(pageIndex) / CGFloat(max(pageCount, 1)),
                saturation: 0.5,
                brightness: 0.8,
                alpha: 1
            ).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            document.insert(page, at: pageIndex)
        }
        return document
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}
