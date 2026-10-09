public import CmuxiOSSSHCore
import CmuxMobileSSH
import CmuxMobileWire
import Foundation

/// Runs screen and cmux-tui lifecycle operations through the same bounded SSH
/// command runner as discovery.  Target identifiers come from the catalog and
/// are validated by ``SSHTmuxLifecycleMutation`` before reaching this type.
public struct SSHWorkspaceLifecycleCommandExecutor: SSHTmuxLifecycleExecutor {
    private let runner: any SSHCommandRunning

    public init(runner: any SSHCommandRunning) { self.runner = runner }

    public func execute(_ mutation: SSHTmuxLifecycleMutation) async throws -> SSHTmuxLifecycleExecution {
        guard mutation.isValid else { throw SSHTmuxLifecycleCommandExecutorError.invalidRequest }
        switch mutation {
        case .createWindow, .renameWindow, .killWindow:
            return try await SSHTmuxLifecycleCommandExecutor(runner: runner).execute(mutation)
        case .createScreen(let name):
            let output = try await runner.run("/bin/sh -s", input: Self.screenScript("create", session: nil, name: name))
            guard Self.succeeded(output) else {
                throw SSHTmuxLifecycleCommandExecutorError.malformedResult
            }
            return Self.execution(value: .object(["name": .string(name)]), revision: "screen:create:\(name)")
        case .renameScreen(let session, let name):
            let output = try await runner.run("/bin/sh -s", input: Self.screenScript("rename", session: session, name: name))
            guard Self.succeeded(output) else {
                throw SSHTmuxLifecycleCommandExecutorError.malformedResult
            }
            return Self.execution(value: .null, revision: "screen:rename:\(session)")
        case .killScreen(let session):
            let output = try await runner.run("/bin/sh -s", input: Self.screenScript("kill", session: session, name: nil))
            guard Self.succeeded(output) else {
                throw SSHTmuxLifecycleCommandExecutorError.malformedResult
            }
            return Self.execution(value: .null, revision: "screen:kill:\(session)")
        case .createCmuxTUI(let socket, let name):
            let output = try await runner.run("/bin/sh -s", input: Self.cmuxScript(socket: socket, workspace: nil, action: "create", name: name))
            guard Self.succeeded(output) else {
                throw SSHTmuxLifecycleCommandExecutorError.malformedResult
            }
            return Self.execution(value: .null, revision: "cmux:create:\(socket)")
        case .renameCmuxTUI(let socket, let workspaceID, let name):
            let output = try await runner.run("/bin/sh -s", input: Self.cmuxScript(socket: socket, workspace: workspaceID, action: "rename", name: name))
            guard Self.succeeded(output) else {
                throw SSHTmuxLifecycleCommandExecutorError.malformedResult
            }
            return Self.execution(value: .null, revision: "cmux:rename:\(workspaceID)")
        case .killCmuxTUI(let socket, let workspaceID):
            let output = try await runner.run("/bin/sh -s", input: Self.cmuxScript(socket: socket, workspace: workspaceID, action: "kill", name: nil))
            guard Self.succeeded(output) else {
                throw SSHTmuxLifecycleCommandExecutorError.malformedResult
            }
            return Self.execution(value: .null, revision: "cmux:kill:\(workspaceID)")
        }
    }

    private static func screenScript(_ action: String, session: String?, name: String?) -> String {
        let target = session?.posixShellSingleQuoted ?? ""
        let title = name?.posixShellSingleQuoted ?? ""
        let command: String
        switch action {
        case "create": command = "screen -dmS \(title); printf 'CMUX_OK\\n'"
        case "rename": command = "screen -S \(target) -X sessionname \(title); printf 'CMUX_OK\\n'"
        default: command = "screen -S \(target) -X quit; printf 'CMUX_OK\\n'"
        }
        let check = session.map { "screen -ls 2>/dev/null | awk -v target=\($0.posixShellSingleQuoted) '$1 == target { found=1 } END { exit(found ? 0 : 1) }'" } ?? ":"
        return """
        set -eu
        \(check)
        \(command)
        """
    }

    private static func cmuxScript(socket: String, workspace: String?, action: String, name: String?) -> String {
        let socket = socket.posixShellSingleQuoted
        let binary = "cmux-tui"
        let command: String
        switch action {
        case "create":
            command = "\(binary) --socket \(socket) --json workspace create\(name.map { " --name " + $0.posixShellSingleQuoted } ?? "")"
        case "rename":
            command = "\(binary) --socket \(socket) --json workspace \(workspace!.posixShellSingleQuoted) rename --name \(name!.posixShellSingleQuoted)"
        default:
            command = "\(binary) --socket \(socket) --json workspace \(workspace!.posixShellSingleQuoted) close"
        }
        return """
        set -eu
        test -S \(socket)
        \(command) >/dev/null
        printf 'CMUX_OK\\n'
        """
    }

    private static func execution(value: JSONValue, revision: String) -> SSHTmuxLifecycleExecution {
        // All revisions are assembled from validated identifiers and therefore
        // satisfy the owner receipt's printable bound.
        SSHTmuxLifecycleExecution(value: value, revision: revision)!
    }

    private static func succeeded(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).last.map(String.init) == "CMUX_OK"
    }
}

public enum SSHTmuxLifecycleCommandExecutorError: Error, Equatable, Sendable {
    case invalidRequest
    case malformedResult
    case unsupported
}
