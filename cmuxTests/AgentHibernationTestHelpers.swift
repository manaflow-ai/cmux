import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentHibernationTests {
    func expectEqual<T: Equatable>(
        _ lhs: @autoclosure () -> T,
        _ rhs: @autoclosure () -> T
    ) {
        #expect(lhs() == rhs())
    }

    func expectNotEqual<T: Equatable>(
        _ lhs: @autoclosure () -> T,
        _ rhs: @autoclosure () -> T
    ) {
        #expect(lhs() != rhs())
    }

    func expectTrue(_ condition: @autoclosure () -> Bool) {
        #expect(condition())
    }

    func expectFalse(_ condition: @autoclosure () -> Bool) {
        #expect(condition() == false)
    }

    func expectNil<T>(_ value: @autoclosure () -> T?) {
        #expect(value() == nil)
    }

    func expectNotNil<T>(
        _ value: @autoclosure () -> T?,
        _ _: String = ""
    ) {
        #expect(value() != nil)
    }

    func launch(
        _ launcher: String,
        _ executablePath: String,
        arguments: [String] = [],
        cwd: String
    ) -> AgentLaunchCommandSnapshot {
        AgentLaunchCommandSnapshot(
            launcher: launcher,
            executablePath: executablePath,
            arguments: arguments.isEmpty ? [executablePath] : arguments,
            workingDirectory: cwd,
            environment: nil,
            capturedAt: nil,
            source: nil
        )
    }
}
