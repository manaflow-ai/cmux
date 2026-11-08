import Foundation
import Testing

/// How long a spawned CLI may run before the suite calls it a hang.
///
/// Most of these tests check what the CLI printed and which socket it talked to, never
/// how fast it got there, so a tight per-test budget can only invent failures on a busy
/// machine. This budget is the default for those runs: long enough that only a stuck
/// process reaches it, and short enough that a stuck process still fails the test
/// instead of stalling the suite forever. A test that genuinely measures how long the
/// CLI waits passes its own, tighter budget instead.
enum CMUXCLITestHangGuard {
    static let seconds: TimeInterval = 60
}

extension CMUXCLIErrorOutputRegressionTests {
    func XCTAssertFalse(
        _ expression: @autoclosure () throws -> Bool,
        _ message: @autoclosure () -> String = ""
    ) {
        do {
            #expect(try !expression(), Comment(rawValue: message()))
        } catch {
            Issue.record(error)
        }
    }

    func XCTAssertTrue(
        _ expression: @autoclosure () throws -> Bool,
        _ message: @autoclosure () -> String = ""
    ) {
        do {
            #expect(try expression(), Comment(rawValue: message()))
        } catch {
            Issue.record(error)
        }
    }

    func XCTAssertEqual<T: Equatable>(
        _ lhs: @autoclosure () throws -> T,
        _ rhs: @autoclosure () throws -> T,
        _ message: @autoclosure () -> String = ""
    ) {
        do {
            #expect(try lhs() == rhs(), Comment(rawValue: message()))
        } catch {
            Issue.record(error)
        }
    }

    func XCTAssertNotEqual<T: Equatable>(
        _ lhs: @autoclosure () throws -> T,
        _ rhs: @autoclosure () throws -> T,
        _ message: @autoclosure () -> String = ""
    ) {
        do {
            #expect(try lhs() != rhs(), Comment(rawValue: message()))
        } catch {
            Issue.record(error)
        }
    }

    func XCTUnwrap<T>(
        _ expression: @autoclosure () throws -> T?,
        _ message: @autoclosure () -> String = ""
    ) throws -> T {
        try #require(try expression(), Comment(rawValue: message()))
    }

    final class CMUXTestExpectation {
        let description: String
        var expectedFulfillmentCount = 1

        private let semaphore = DispatchSemaphore(value: 0)

        init(description: String) {
            self.description = description
        }

        func fulfill() {
            semaphore.signal()
        }

        func wait(timeout: TimeInterval) -> Bool {
            for _ in 0..<expectedFulfillmentCount {
                if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                    return false
                }
            }
            return true
        }
    }

    func expectation(description: String) -> CMUXTestExpectation {
        CMUXTestExpectation(description: description)
    }

    func wait(for expectations: [CMUXTestExpectation], timeout: TimeInterval) {
        for expectation in expectations {
            #expect(
                expectation.wait(timeout: timeout),
                Comment(rawValue: "Timed out waiting for \(expectation.description)")
            )
        }
    }
}
