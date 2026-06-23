import Foundation
import Testing

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
