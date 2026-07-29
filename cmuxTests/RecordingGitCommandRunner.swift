import CmuxFoundation
import Foundation

actor RecordingGitCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private var arguments: [[String]] = []
    private var timeouts: [TimeInterval?] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        self.arguments.append(arguments)
        timeouts.append(timeout)
        guard !results.isEmpty else {
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: "missing stub result"
            )
        }
        return results.removeFirst()
    }

    func recordedArguments() -> [[String]] {
        arguments
    }

    func recordedTimeouts() -> [TimeInterval?] {
        timeouts
    }
}
