import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TaskManagerResourcesTests: XCTestCase {
    func testAttributedPayloadProratesSharedResourceMeasurements() {
        let summary = resourceSummary()

        let payload = summary.attributedPayload(sharedAcross: 2)

        XCTAssertEqual(double(payload["cpu_percent"]), 21)
        XCTAssertEqual(int64(payload["resident_bytes"]), 500)
        XCTAssertEqual(int64(payload["virtual_bytes"]), 1000)
        XCTAssertEqual(int(payload["process_count"]), 1)
        XCTAssertEqual(intArray(payload["pids"]), [101])
        XCTAssertEqual(intArray(payload["missing_pids"]), [202])
    }

    func testAttributedPayloadReturnsUnmodifiedPayloadForSingleOccurrence() {
        let payload = resourceSummary().attributedPayload(sharedAcross: 1)

        assertUnmodifiedAttributedPayload(payload)
    }

    func testAttributedPayloadReturnsUnmodifiedPayloadForZeroOccurrences() {
        let payload = resourceSummary().attributedPayload(sharedAcross: 0)

        assertUnmodifiedAttributedPayload(payload)
    }

    func testAttributedPayloadReturnsUnmodifiedPayloadForNegativeOccurrences() {
        let payload = resourceSummary().attributedPayload(sharedAcross: -1)

        assertUnmodifiedAttributedPayload(payload)
    }

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

    private func resourceSummary() -> CmuxTopResourceSummary {
        var summary = CmuxTopResourceSummary()
        summary.cpuPercent = 42
        summary.residentBytes = 1001
        summary.virtualBytes = 2001
        summary.processCount = 1
        summary.pids = [101]
        summary.missingPIDs = [202]
        return summary
    }

    private func assertUnmodifiedAttributedPayload(
        _ payload: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(double(payload["cpu_percent"]), 42, file: file, line: line)
        XCTAssertEqual(int64(payload["resident_bytes"]), 1001, file: file, line: line)
        XCTAssertEqual(int64(payload["virtual_bytes"]), 2001, file: file, line: line)
        XCTAssertEqual(int(payload["process_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["pids"]), [101], file: file, line: line)
        XCTAssertEqual(intArray(payload["missing_pids"]), [202], file: file, line: line)
    }

    private func double(_ raw: Any?) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        return 0
    }

    private func int64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        return 0
    }

    private func int(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return 0
    }

    private func intArray(_ raw: Any?) -> [Int] {
        if let values = raw as? [Int] { return values }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { raw in
            if let value = raw as? Int { return value }
            if let value = raw as? NSNumber { return value.intValue }
            if let value = raw as? String { return Int(value) }
            return nil
        }
    }
}
