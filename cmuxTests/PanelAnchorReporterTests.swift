import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class PanelAnchorReporterTests: XCTestCase {
    func testCurrentAnchorMountPolicyKeepsPortalAnchorsOnlyForVisiblePortalPanels() {
        XCTAssertTrue(
            PanelLifecycleCurrentAnchorMountPolicy.shouldMountLiveAnchor(
                panelType: .terminal,
                isVisibleInUI: true
            )
        )
        XCTAssertFalse(
            PanelLifecycleCurrentAnchorMountPolicy.shouldMountLiveAnchor(
                panelType: .terminal,
                isVisibleInUI: false
            )
        )
        XCTAssertTrue(
            PanelLifecycleCurrentAnchorMountPolicy.shouldMountLiveAnchor(
                panelType: .browser,
                isVisibleInUI: true
            )
        )
        XCTAssertFalse(
            PanelLifecycleCurrentAnchorMountPolicy.shouldMountLiveAnchor(
                panelType: .browser,
                isVisibleInUI: false
            )
        )
    }

    func testCurrentAnchorMountPolicyDoesNotMountLiveAnchorForMarkdown() {
        XCTAssertFalse(
            PanelLifecycleCurrentAnchorMountPolicy.shouldMountLiveAnchor(
                panelType: .markdown,
                isVisibleInUI: true
            )
        )
        XCTAssertFalse(
            PanelLifecycleCurrentAnchorMountPolicy.shouldMountLiveAnchor(
                panelType: .markdown,
                isVisibleInUI: false
            )
        )
    }

    func testAnchorIdIsStableAcrossGeometryChanges() {
        let host = PanelLifecycleAnchorHostView(frame: .zero)
        let anchorId = host.panelLifecycleAnchorId

        XCTAssertEqual(host.geometryRevision, 0)

        host.setFrameSize(NSSize(width: 100, height: 80))
        XCTAssertEqual(host.panelLifecycleAnchorId, anchorId)
        XCTAssertEqual(host.geometryRevision, 1)

        host.setFrameSize(NSSize(width: 100, height: 80))
        XCTAssertEqual(host.panelLifecycleAnchorId, anchorId)
        XCTAssertEqual(host.geometryRevision, 1)

        host.setFrameOrigin(NSPoint(x: 5, y: 9))
        XCTAssertEqual(host.panelLifecycleAnchorId, anchorId)
        XCTAssertEqual(host.geometryRevision, 2)
    }

    func testDistinctHostsHaveDistinctAnchorIds() {
        let first = PanelLifecycleAnchorHostView(frame: .zero)
        let second = PanelLifecycleAnchorHostView(frame: .zero)

        XCTAssertNotEqual(first.panelLifecycleAnchorId, second.panelLifecycleAnchorId)
    }

    func testGeometryCallbackOnlyFiresOnDistinctGeometryStates() {
        let host = PanelLifecycleAnchorHostView(frame: .zero)
        var callbackCount = 0
        host.onGeometryChanged = { callbackCount += 1 }

        host.setFrameSize(NSSize(width: 40, height: 40))
        host.setFrameSize(NSSize(width: 40, height: 40))
        host.setFrameOrigin(NSPoint(x: 1, y: 2))

        XCTAssertEqual(callbackCount, 2)
        XCTAssertEqual(host.geometryRevision, 2)
    }
}
