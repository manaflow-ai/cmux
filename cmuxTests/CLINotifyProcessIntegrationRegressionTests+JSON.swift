import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    // A CLI that printed nothing or non-JSON is an ordinary assertion failure.
    // Letting `JSONSerialization` throw here made XCTest record a thrown error,
    // which the CI classifier counts as "unexpected" and treats like an
    // app-host crash, so one slow CLI turned a whole tolerant shard red.
    func notificationRows(from stdout: String) throws -> [[String: Any]] {
        let data = Data(stdout.utf8)
        return try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: data, options: [])) as? [[String: Any]],
            "Expected notification JSON array, got: \(stdout)"
        )
    }
    func jsonPayload(from stdout: String) throws -> [String: Any] {
        let data = Data(stdout.utf8)
        return try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
            "Expected JSON object, got: \(stdout)"
        )
    }
}
