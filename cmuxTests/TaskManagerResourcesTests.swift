import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TaskManagerResourcesTests: XCTestCase {
    func testParsesTypedIntPIDArrayFromSummaryPayload() {
        let payload: [String: Any] = [
            "cpu_percent": 3.5,
            "resident_bytes": 4096,
            "process_count": 2,
            "pids": [101, 202],
        ]

        let resources = CmuxTaskManagerResources(payload)

        XCTAssertEqual(resources.processIds, [101, 202])
    }

    func testParsesAnyPIDArrayFromPayload() {
        let payload: [String: Any] = [
            "cpu_percent": 3.5,
            "resident_bytes": 4096,
            "process_count": 2,
            "pids": [101 as Any, "202" as Any],
        ]

        let resources = CmuxTaskManagerResources(payload)

        XCTAssertEqual(resources.processIds, [101, 202])
    }
}
