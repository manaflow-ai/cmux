import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxTopSnapshotScopeTests: XCTestCase {
    func testKernProcArgsWorkspaceID() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let bytes = kernProcArgs(environment: [
            "CMUX_WORKSPACE_ID=\(workspaceID.uuidString)"
        ])

        let scope = CmuxTopProcessSnapshot.cmuxScope(fromKernProcArgs: bytes)

        XCTAssertEqual(scope?.workspaceID, workspaceID)
        XCTAssertNil(scope?.surfaceID)
    }

    func testKernProcArgsTabIDFallback() {
        let tabID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let bytes = kernProcArgs(environment: [
            "CMUX_TAB_ID=\(tabID.uuidString)"
        ])

        let scope = CmuxTopProcessSnapshot.cmuxScope(fromKernProcArgs: bytes)

        XCTAssertEqual(scope?.workspaceID, tabID)
        XCTAssertNil(scope?.surfaceID)
    }

    func testKernProcArgsSurfaceID() {
        let surfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let bytes = kernProcArgs(environment: [
            "CMUX_SURFACE_ID=\(surfaceID.uuidString)"
        ])

        let scope = CmuxTopProcessSnapshot.cmuxScope(fromKernProcArgs: bytes)

        XCTAssertNil(scope?.workspaceID)
        XCTAssertEqual(scope?.surfaceID, surfaceID)
    }

    func testKernProcArgsPanelIDFallback() {
        let panelID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let bytes = kernProcArgs(environment: [
            "CMUX_PANEL_ID=\(panelID.uuidString)"
        ])

        let scope = CmuxTopProcessSnapshot.cmuxScope(fromKernProcArgs: bytes)

        XCTAssertNil(scope?.workspaceID)
        XCTAssertEqual(scope?.surfaceID, panelID)
    }

    private func kernProcArgs(
        arguments: [String] = ["zsh"],
        environment: [String]
    ) -> [UInt8] {
        var argc = Int32(arguments.count).littleEndian
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        appendCString("/bin/zsh", to: &bytes)
        bytes.append(0)
        for argument in arguments {
            appendCString(argument, to: &bytes)
        }
        bytes.append(0)
        for entry in environment {
            appendCString(entry, to: &bytes)
        }
        bytes.append(0)
        return bytes
    }

    private func appendCString(_ string: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: string.utf8)
        bytes.append(0)
    }
}
