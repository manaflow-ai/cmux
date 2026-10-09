import CmuxMobileSSH
import CmuxMobileWire
import Foundation

/// Executes the validated tmux lifecycle mutations over a non-interactive SSH
/// command runner.  The server epoch is checked in the same remote shell
/// immediately before the tmux command.  A mismatch exits without mutating
/// the server, which makes a stale discovery fail closed.
public struct SSHTmuxLifecycleCommandExecutor: SSHTmuxLifecycleExecutor {
    public enum Error: Swift.Error, Equatable, Sendable {
        case malformedResult
        case staleServer
        case unsupported
    }

    private let runner: any SSHCommandRunning
    private let binary: SSHRemoteBinary

    public init(runner: any SSHCommandRunning, binary: SSHRemoteBinary = .tmux) {
        self.runner = runner
        self.binary = binary
    }

    public func execute(_ mutation: SSHTmuxLifecycleMutation) async throws -> SSHTmuxLifecycleExecution {
        guard mutation.isValid else { throw Error.malformedResult }
        let output = try await runner.run("/bin/sh -s", input: try script(for: mutation))
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let revision: String
        switch mutation {
        case .createWindow(let epoch, _, _):
            guard let line = lines.last,
                  line.hasPrefix("CMUX_WINDOW\t") else { throw Error.malformedResult }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3,
                  SSHTmuxWindow.isValidID(fields[1], prefix: "@"),
                  SSHTmuxWindow.isValidID(fields[2], prefix: "$" ) else {
                throw Error.malformedResult
            }
            let value: JSONValue = .object(["window_id": .string(fields[1]), "session_id": .string(fields[2])])
            revision = Self.revision(epoch: epoch, id: fields[1])
            return try Self.execution(value: value, revision: revision)
        case .renameWindow(let epoch, let windowID, _), .killWindow(let epoch, let windowID):
            guard lines.last == "CMUX_OK" else { throw Error.malformedResult }
            revision = Self.revision(epoch: epoch, id: windowID)
            return try Self.execution(value: .null, revision: revision)
        case .createScreen, .renameScreen, .killScreen,
             .createCmuxTUI, .renameCmuxTUI, .killCmuxTUI:
            throw Error.unsupported
        }
    }

    private func script(for mutation: SSHTmuxLifecycleMutation) throws -> String {
        let binary = binary.path.posixShellSingleQuoted
        let epoch: SSHTmuxServerEpoch
        let command: String
        switch mutation {
        case .createWindow(let server, let sessionID, let name):
            epoch = server
            let title = name.map { " -n " + $0.posixShellSingleQuoted } ?? ""
            command = "printf 'CMUX_WINDOW\\t%s\\n' \"$($binary new-window -d -P -F '#{window_id}\\t#{session_id}' -t \(sessionID.posixShellSingleQuoted)\(title))\""
        case .renameWindow(let server, let windowID, let name):
            epoch = server
            command = "${binary} rename-window -t \(windowID.posixShellSingleQuoted) \(name.posixShellSingleQuoted); printf 'CMUX_OK\\n'"
        case .killWindow(let server, let windowID):
            epoch = server
            command = "${binary} kill-window -t \(windowID.posixShellSingleQuoted); printf 'CMUX_OK\\n'"
        case .createScreen, .renameScreen, .killScreen,
             .createCmuxTUI, .renameCmuxTUI, .killCmuxTUI:
            throw Error.unsupported
        }
        // `$binary` is assigned once and is never formed from user text.  The
        // command itself is quoted as individual shell arguments above.
        return """
        set -eu
        binary=\(binary)
        expected_pid='\(epoch.serverPID)'
        expected_start='\(epoch.serverStart)'
        set -- $("$binary" list-sessions -F '#{pid}\\t#{start_time}' 2>/dev/null | sed -n '1p')
        [ "${1-}" = "$expected_pid" ] && [ "${2-}" = "$expected_start" ] || exit 42
        \(command.replacingOccurrences(of: "${binary}", with: "\"$binary\""))
        """
    }

    private static func revision(epoch: SSHTmuxServerEpoch, id: String) -> String {
        "tmux:\(epoch.serverPID):\(epoch.serverStart):\(id)"
    }

    private static func execution(value: JSONValue, revision: String) throws -> SSHTmuxLifecycleExecution {
        guard let execution = SSHTmuxLifecycleExecution(value: value, revision: revision) else {
            throw Error.malformedResult
        }
        return execution
    }
}
