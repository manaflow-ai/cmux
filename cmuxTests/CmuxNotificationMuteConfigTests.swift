import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxNotificationMuteConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(CmuxConfigFile.self, from: data)
    }

    func testDecodeNotificationMuteDurations() throws {
        let json = """
        {
          "notifications": {
            "muteDurations": [
              { "label": "30 Minutes", "minutes": 30 },
              { "label": "2.5 Hours", "hours": 2, "minutes": 30 }
            ]
          }
        }
        """
        let config = try decode(json)
        let durations = try XCTUnwrap(config.notifications?.muteDurations)
        XCTAssertEqual(durations.map(\.label), ["30 Minutes", "2.5 Hours"])
        XCTAssertEqual(durations.map(\.interval), [30 * 60, (2 * 60 * 60) + (30 * 60)])
    }

    func testDecodeNotificationMuteDurationsRejectBlankLabel() {
        let json = """
        {
          "notifications": {
            "muteDurations": [
              { "label": "   ", "minutes": 30 }
            ]
          }
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeNotificationMuteDurationsRejectZeroDuration() {
        let json = """
        {
          "notifications": {
            "muteDurations": [
              { "label": "Zero", "minutes": 0 }
            ]
          }
        }
        """
        XCTAssertThrowsError(try decode(json))
    }
}
