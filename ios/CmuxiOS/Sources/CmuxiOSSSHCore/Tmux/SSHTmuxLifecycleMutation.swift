import CmuxMobileWire
import Foundation

/// The tmux server identity a lifecycle operation was authored against.
///
/// An owner must check this epoch immediately before applying an operation. A
/// PID alone is not sufficient because tmux can reuse it after a server exits.
public struct SSHTmuxServerEpoch: Hashable, Sendable {
    public let serverPID: UInt32
    public let serverStart: UInt64

    public init?(serverPID: UInt32, serverStart: UInt64) {
        guard serverPID > 0, serverStart > 0, serverStart <= UInt64(Int64.max) else { return nil }
        self.serverPID = serverPID
        self.serverStart = serverStart
    }
}

/// A bounded lifecycle operation against a modern, control-mode tmux server.
///
/// These values deliberately carry host-issued ids and an epoch instead of a
/// session name or a free-form tmux target. The owner adapter is responsible
/// for checking the epoch and recording the idempotency key durably before it
/// reports an applied result. This client-side seam does not execute SSH
/// commands, so an interrupted raw command can never be mistaken for success.
public enum SSHTmuxLifecycleMutation: Hashable, Sendable {
    case createWindow(server: SSHTmuxServerEpoch, sessionID: String, name: String?)
    case renameWindow(server: SSHTmuxServerEpoch, windowID: String, name: String)
    case killWindow(server: SSHTmuxServerEpoch, windowID: String)
    /// GNU screen lifecycle uses the discovery-issued `<pid>.<name>` session
    /// identity. There is no server epoch in screen's listing, so the command
    /// executor must re-read the exact session immediately before mutating it.
    case createScreen(name: String)
    case renameScreen(session: String, name: String)
    case killScreen(session: String)
    /// cmux-tui lifecycle is routed to an already discovered Unix socket. The
    /// socket path and workspace id are retained verbatim in the owner
    /// fingerprint so a reconnect cannot accidentally target another owner.
    case createCmuxTUI(socket: String, name: String?)
    case renameCmuxTUI(socket: String, workspaceID: String, name: String)
    case killCmuxTUI(socket: String, workspaceID: String)

    public static let maximumNameBytes = 200
    /// The mobile owner wire accepts printable idempotency keys up to 128
    /// bytes. Keep the host-side seam at that boundary so a mutation cannot
    /// pass this layer and then be refused by cmux.mobile/1.
    public static let maximumKeyBytes = 128

    /// Parses the wire operation used by a future workspace owner adapter.
    /// Unknown fields and malformed host-issued ids are refused.
    public init?(op: String, params: JSONValue) {
        guard let object = params.objectValue else { return nil }
        let keys = Set(object.keys)
        switch op {
        case "ssh.tmux.window.create":
            guard let epoch = Self.epoch(from: object) else { return nil }
            guard keys.isSubset(of: ["server_pid", "server_start", "session_id", "name"]),
                  let sessionID = object["session_id"]?.stringValue,
                  Self.validSessionID(sessionID) else { return nil }
            let name: String?
            if let value = object["name"] {
                guard case .null = value else {
                    guard let string = value.stringValue, Self.validName(string) else { return nil }
                    name = string
                    self = .createWindow(server: epoch, sessionID: sessionID, name: name)
                    return
                }
                name = nil
            } else {
                name = nil
            }
            self = .createWindow(server: epoch, sessionID: sessionID, name: name)
            return
        case "ssh.tmux.window.rename":
            guard let epoch = Self.epoch(from: object) else { return nil }
            guard keys == Set(["server_pid", "server_start", "window_id", "name"]),
                  let windowID = object["window_id"]?.stringValue,
                  let name = object["name"]?.stringValue,
                  Self.validWindowID(windowID), Self.validName(name) else { return nil }
            self = .renameWindow(server: epoch, windowID: windowID, name: name)
            return
        case "ssh.tmux.window.kill":
            guard let epoch = Self.epoch(from: object) else { return nil }
            guard keys == Set(["server_pid", "server_start", "window_id"]),
                  let windowID = object["window_id"]?.stringValue,
                  Self.validWindowID(windowID) else { return nil }
            self = .killWindow(server: epoch, windowID: windowID)
            return
        case "ssh.screen.session.create":
            guard keys == Set(["name"]), let name = object["name"]?.stringValue,
                  Self.validName(name) else { return nil }
            self = .createScreen(name: name)
            return
        case "ssh.screen.session.rename":
            guard keys == Set(["session", "name"]), let session = object["session"]?.stringValue,
                  let name = object["name"]?.stringValue, Self.validSessionName(session), Self.validName(name) else { return nil }
            self = .renameScreen(session: session, name: name)
            return
        case "ssh.screen.session.kill":
            guard keys == Set(["session"]), let session = object["session"]?.stringValue,
                  Self.validSessionName(session) else { return nil }
            self = .killScreen(session: session)
            return
        case "ssh.cmux_tui.workspace.create":
            guard keys.contains("socket"), keys.subtracting(["socket", "name"]).isEmpty,
                  let socket = object["socket"]?.stringValue, Self.validSocket(socket) else { return nil }
            let name: String?
            if let value = object["name"] {
                guard case .null = value else {
                    guard let string = value.stringValue, Self.validName(string) else { return nil }
                    name = string
                    self = .createCmuxTUI(socket: socket, name: name)
                    return
                }
                name = nil
            } else { name = nil }
            self = .createCmuxTUI(socket: socket, name: name)
            return
        case "ssh.cmux_tui.workspace.rename":
            guard keys == Set(["socket", "workspace", "name"]),
                  let socket = object["socket"]?.stringValue, Self.validSocket(socket),
                  let workspaceID = object["workspace"]?.stringValue, Self.validWorkspaceID(workspaceID),
                  let name = object["name"]?.stringValue, Self.validName(name) else { return nil }
            self = .renameCmuxTUI(socket: socket, workspaceID: workspaceID, name: name)
            return
        case "ssh.cmux_tui.workspace.kill":
            guard keys == Set(["socket", "workspace"]),
                  let socket = object["socket"]?.stringValue, Self.validSocket(socket),
                  let workspaceID = object["workspace"]?.stringValue, Self.validWorkspaceID(workspaceID) else { return nil }
            self = .killCmuxTUI(socket: socket, workspaceID: workspaceID)
            return
        default:
            return nil
        }
    }

    /// The operation name used in an `OpFrame`.
    public var op: String {
        switch self {
        case .createWindow: "ssh.tmux.window.create"
        case .renameWindow: "ssh.tmux.window.rename"
        case .killWindow: "ssh.tmux.window.kill"
        case .createScreen: "ssh.screen.session.create"
        case .renameScreen: "ssh.screen.session.rename"
        case .killScreen: "ssh.screen.session.kill"
        case .createCmuxTUI: "ssh.cmux_tui.workspace.create"
        case .renameCmuxTUI: "ssh.cmux_tui.workspace.rename"
        case .killCmuxTUI: "ssh.cmux_tui.workspace.kill"
        }
    }

    /// Canonical wire parameters. The owner can use the same value when
    /// hashing a durable idempotency record.
    public var params: JSONValue {
        let server: SSHTmuxServerEpoch
        var object: [String: JSONValue]
        switch self {
        case .createWindow(let epoch, let sessionID, let name):
            server = epoch
            object = ["session_id": .string(sessionID)]
            if let name { object["name"] = .string(name) }
        case .renameWindow(let epoch, let windowID, let name):
            server = epoch
            object = ["window_id": .string(windowID), "name": .string(name)]
        case .killWindow(let epoch, let windowID):
            server = epoch
            object = ["window_id": .string(windowID)]
        case .createScreen(let name):
            return .object(["name": .string(name)])
        case .renameScreen(let session, let name):
            return .object(["session": .string(session), "name": .string(name)])
        case .killScreen(let session):
            return .object(["session": .string(session)])
        case .createCmuxTUI(let socket, let name):
            var params: [String: JSONValue] = ["socket": .string(socket)]
            if let name { params["name"] = .string(name) }
            return .object(params)
        case .renameCmuxTUI(let socket, let workspaceID, let name):
            return .object(["socket": .string(socket), "workspace": .string(workspaceID), "name": .string(name)])
        case .killCmuxTUI(let socket, let workspaceID):
            return .object(["socket": .string(socket), "workspace": .string(workspaceID)])
        }
        object["server_pid"] = .int(Int64(server.serverPID))
        object["server_start"] = .int(Int64(clamping: server.serverStart))
        return .object(object)
    }

    /// Idempotency keys are bounded before crossing into an owner adapter.
    public static func validIdempotencyKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return (1...maximumKeyBytes).contains(bytes.count)
            && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    /// A value constructed through an enum case can still be checked by an
    /// owner adapter before execution.
    public var isValid: Bool {
        switch self {
        case .createWindow(let epoch, let sessionID, let name):
            epoch.serverPID > 0 && epoch.serverStart > 0 && Self.validSessionID(sessionID)
                && name.map(Self.validName) ?? true
        case .renameWindow(let epoch, let windowID, let name):
            epoch.serverPID > 0 && epoch.serverStart > 0 && Self.validWindowID(windowID) && Self.validName(name)
        case .killWindow(let epoch, let windowID):
            epoch.serverPID > 0 && epoch.serverStart > 0 && Self.validWindowID(windowID)
        case .createScreen(let name): Self.validName(name)
        case .renameScreen(let session, let name): Self.validSessionName(session) && Self.validName(name)
        case .killScreen(let session): Self.validSessionName(session)
        case .createCmuxTUI(let socket, let name): Self.validSocket(socket) && (name.map(Self.validName) ?? true)
        case .renameCmuxTUI(let socket, let workspaceID, let name):
            Self.validSocket(socket) && Self.validWorkspaceID(workspaceID) && Self.validName(name)
        case .killCmuxTUI(let socket, let workspaceID): Self.validSocket(socket) && Self.validWorkspaceID(workspaceID)
        }
    }

    private static func epoch(from object: [String: JSONValue]) -> SSHTmuxServerEpoch? {
        guard case .int(let pid)? = object["server_pid"],
              case .int(let start)? = object["server_start"],
              pid > 0, pid <= Int64(UInt32.max), start > 0,
              let serverPID = UInt32(exactly: pid), let serverStart = UInt64(exactly: start) else { return nil }
        return SSHTmuxServerEpoch(serverPID: serverPID, serverStart: serverStart)
    }

    private static func validSessionID(_ value: String) -> Bool {
        SSHTmuxWindow.isValidID(value, prefix: "$" )
    }

    private static func validWindowID(_ value: String) -> Bool {
        SSHTmuxWindow.isValidID(value, prefix: "@" )
    }

    private static func validName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maximumNameBytes).contains(bytes.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && $0 != "\u{2028}" && $0 != "\u{2029}"
        }
    }

    private static func validSessionName(_ value: String) -> Bool {
        SSHSessionName(validating: value) != nil
    }

    private static func validWorkspaceID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count) && bytes.first != UInt8(ascii: "-")
            && bytes.allSatisfy { SSHSessionName.isAllowed($0) }
    }

    private static func validSocket(_ value: String) -> Bool {
        SSHCmuxTUISocket(validatingPath: value) != nil
    }
}

/// The durable decision returned by a host owner for one lifecycle operation.
public struct SSHTmuxLifecycleReceipt: Hashable, Sendable {
    public let idempotencyKey: String
    public let mutation: SSHTmuxLifecycleMutation
    public let value: JSONValue
    public let revision: String
    public let replayed: Bool

    public init(idempotencyKey: String, mutation: SSHTmuxLifecycleMutation, value: JSONValue,
                revision: String, replayed: Bool) {
        self.idempotencyKey = idempotencyKey
        self.mutation = mutation
        self.value = value
        self.revision = revision
        self.replayed = replayed
    }
}

/// Owner-side seam for lifecycle mutations. Implementations must persist the
/// key and operation fingerprint with the mutation before returning `.applied`;
/// an uncertain SSH command must throw and may not be replayed automatically.
public protocol SSHTmuxLifecycleMutating: Sendable {
    func submit(_ mutation: SSHTmuxLifecycleMutation, idempotencyKey: String) async throws -> SSHTmuxLifecycleReceipt
}
