import Testing

/// Assertion adapter for mechanically migrated Swift Testing suites.
///
/// Keeping the adapter value-scoped lets large behavior suites migrate without
/// retaining an XCTest dependency or obscuring failures behind source rewrites.
struct SwiftTestingAssertions {
    func equal<T: Equatable>(
        _ expression1: @autoclosure () throws -> T,
        _ expression2: @autoclosure () throws -> T,
        _ message: @autoclosure () -> String = "",
        file _: StaticString = #filePath,
        line _: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let value1 = try expression1()
            let value2 = try expression2()
            #expect(
                value1 == value2,
                comment(message()),
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }
    }

    func notEqual<T: Equatable>(
        _ expression1: @autoclosure () throws -> T,
        _ expression2: @autoclosure () throws -> T,
        _ message: @autoclosure () -> String = "",
        file _: StaticString = #filePath,
        line _: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let value1 = try expression1()
            let value2 = try expression2()
            #expect(
                value1 != value2,
                comment(message()),
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }
    }

    func isTrue(
        _ expression: @autoclosure () throws -> Bool,
        _ message: @autoclosure () -> String = "",
        file _: StaticString = #filePath,
        line _: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            #expect(
                try expression(),
                comment(message()),
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }
    }

    func isFalse(
        _ expression: @autoclosure () throws -> Bool,
        _ message: @autoclosure () -> String = "",
        file _: StaticString = #filePath,
        line _: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            #expect(
                try !expression(),
                comment(message()),
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }
    }

    func isNil<T>(
        _ expression: @autoclosure () throws -> T?,
        _ message: @autoclosure () -> String = "",
        file _: StaticString = #filePath,
        line _: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            #expect(
                try expression() == nil,
                comment(message()),
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }
    }

    func isNotNil<T>(
        _ expression: @autoclosure () throws -> T?,
        _ message: @autoclosure () -> String = "",
        file _: StaticString = #filePath,
        line _: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            #expect(
                try expression() != nil,
                comment(message()),
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }
    }

    func require<T>(
        _ expression: @autoclosure () throws -> T?,
        _ message: @autoclosure () -> String = "",
        file _: StaticString = #filePath,
        line _: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> T {
        let value = try expression()
        return try #require(
            value,
            comment(message()),
            sourceLocation: sourceLocation
        )
    }

    private func comment(_ message: String) -> Comment? {
        message.isEmpty ? nil : Comment(rawValue: message)
    }
}
