import XCTest
import CmuxExtensionKit
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CmuxPluginProcessIdentityTests: XCTestCase {
    func testRevokedProcessGroupStaysDeniedAfterMarkerIsUnheld() throws {
        let containment = try CmuxPluginProcessContainment()
        defer { containment.cleanup() }

        let processGroupID = getpgrp()
        guard processGroupID > 1 else {
            throw XCTSkip("The test process has no usable process group")
        }

        let runtime = CmuxPluginRuntime()
        let identity = try XCTUnwrap(
            runtime.registerProcess(
                processGroupID,
                for: "dev.example.marker-closed",
                processGroupID: processGroupID,
                containmentMarkerURL: containment.markerURL
            )
        )
        runtime.revokeProcess(processGroupID, identity: identity)
        runtime.processDidExit(
            processGroupID,
            generation: identity.generation,
            containmentMarkerURL: containment.markerURL
        )

        XCTAssertEqual(
            runtime.socketPeerPolicy(
                forProcess: getpid(),
                isEventStreamRequest: true
            ),
            .denied
        )
        XCTAssertEqual(
            runtime.socketPeerPolicy(
                forProcess: getpid(),
                isEventStreamRequest: false
            ),
            .denied
        )
    }
}
