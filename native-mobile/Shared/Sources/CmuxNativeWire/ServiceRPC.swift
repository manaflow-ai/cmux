import Foundation

// Host services on the `svc` channel: newline JSON.
//   request  {"id":N,"method":"fs.list","params":{...}}
//   response {"id":N,"ok":true,"result":{...}} | {"id":N,"ok":false,"error":{"code","message"}}
//   event    {"event":"feed.item","payload":{...}}

public struct ServiceRequest: Codable, Equatable, Sendable {
    public var id: Int
    public var method: String
    public var params: JSONValue?

    public init(id: Int, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct ServiceError: Codable, Equatable, Sendable, Error, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }

    public static func badRequest(_ message: String) -> ServiceError { .init(code: "bad_request", message: message) }
    public static func notFound(_ message: String) -> ServiceError { .init(code: "not_found", message: message) }
    public static func forbidden(_ message: String) -> ServiceError { .init(code: "forbidden", message: message) }
    public static func unknownMethod(_ method: String) -> ServiceError {
        .init(code: "unknown_method", message: "unknown method \(method)")
    }
    public static func failed(_ message: String) -> ServiceError { .init(code: "failed", message: message) }
}

public struct ServiceResponse: Codable, Equatable, Sendable {
    public var id: Int?
    public var ok: Bool
    public var result: JSONValue?
    public var error: ServiceError?

    public init(id: Int?, result: JSONValue) {
        self.id = id
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(id: Int?, error: ServiceError) {
        self.id = id
        self.ok = false
        self.result = nil
        self.error = error
    }
}

public struct ServiceEvent: Codable, Equatable, Sendable {
    public var event: String
    public var payload: JSONValue?

    public init(event: String, payload: JSONValue? = nil) {
        self.event = event
        self.payload = payload
    }
}

/// Any line on the `svc` channel.
public enum ServiceMessage: Equatable, Sendable {
    case request(ServiceRequest)
    case response(ServiceResponse)
    case event(ServiceEvent)

    private struct Probe: Decodable {
        var method: String?
        var ok: Bool?
        var event: String?
    }

    public init(line: Data) throws {
        let decoder = JSONDecoder()
        let probe = try decoder.decode(Probe.self, from: line)
        if probe.method != nil {
            self = .request(try decoder.decode(ServiceRequest.self, from: line))
        } else if probe.event != nil {
            self = .event(try decoder.decode(ServiceEvent.self, from: line))
        } else if probe.ok != nil {
            self = .response(try decoder.decode(ServiceResponse.self, from: line))
        } else {
            throw ServiceError.badRequest("not a svc message")
        }
    }

    /// One JSON line without a trailing newline.
    public func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch self {
        case .request(let r): return try encoder.encode(r)
        case .response(let r): return try encoder.encode(r)
        case .event(let e): return try encoder.encode(e)
        }
    }
}

/// Method names on the `svc` channel.
public struct ServiceMethod: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let hostInfo: ServiceMethod = "host.info"
    public static let fsList: ServiceMethod = "fs.list"
    public static let fsStat: ServiceMethod = "fs.stat"
    public static let fsRead: ServiceMethod = "fs.read"
    public static let gitStatus: ServiceMethod = "git.status"
    public static let gitDiff: ServiceMethod = "git.diff"
    public static let gitLog: ServiceMethod = "git.log"
    public static let uploadPut: ServiceMethod = "upload.put"
    public static let uploadBegin: ServiceMethod = "upload.begin"
    public static let uploadChunk: ServiceMethod = "upload.chunk"
    public static let uploadEnd: ServiceMethod = "upload.end"
    public static let sessionRefs: ServiceMethod = "session.refs"
    public static let feedList: ServiceMethod = "feed.list"
    public static let feedSubscribe: ServiceMethod = "feed.subscribe"
    public static let feedReply: ServiceMethod = "feed.reply"
    public static let feedAnswer: ServiceMethod = "feed.answer"
}

// MARK: - Typed params and results (snake_case on the wire)

public struct HostInfo: Codable, Equatable, Sendable {
    public var hostname: String
    public var user: String
    public var home: String
    public var os: String
    public var arch: String
    public var daemonSocket: String?
    public var version: String

    public init(hostname: String, user: String, home: String, os: String, arch: String, daemonSocket: String?, version: String) {
        self.hostname = hostname
        self.user = user
        self.home = home
        self.os = os
        self.arch = arch
        self.daemonSocket = daemonSocket
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case hostname, user, home, os, arch, version
        case daemonSocket = "daemon_socket"
    }
}

public struct PathParams: Codable, Equatable, Sendable {
    public var path: String
    public var showHidden: Bool?
    public init(path: String, showHidden: Bool? = nil) {
        self.path = path
        self.showHidden = showHidden
    }
    enum CodingKeys: String, CodingKey {
        case path
        case showHidden = "show_hidden"
    }
}

public struct FileEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, dir, symlink }
    public var name: String
    public var path: String
    public var kind: Kind
    public var size: Int64
    /// Unix seconds.
    public var modified: Double
    public var mime: String?
    public var hidden: Bool

    public init(name: String, path: String, kind: Kind, size: Int64, modified: Double, mime: String?, hidden: Bool) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.mime = mime
        self.hidden = hidden
    }
}

public struct FSListResult: Codable, Equatable, Sendable {
    public var path: String
    public var entries: [FileEntry]
    public var truncated: Bool
    public init(path: String, entries: [FileEntry], truncated: Bool) {
        self.path = path
        self.entries = entries
        self.truncated = truncated
    }
}

public struct FSReadParams: Codable, Equatable, Sendable {
    public var path: String
    public var offset: Int64?
    public var length: Int?
    public init(path: String, offset: Int64? = nil, length: Int? = nil) {
        self.path = path
        self.offset = offset
        self.length = length
    }
}

public struct FSReadResult: Codable, Equatable, Sendable {
    public var path: String
    public var offset: Int64
    public var length: Int
    public var size: Int64
    public var eof: Bool
    public var mime: String
    /// Base64 of the bytes read.
    public var data: String

    public init(path: String, offset: Int64, length: Int, size: Int64, eof: Bool, mime: String, data: String) {
        self.path = path
        self.offset = offset
        self.length = length
        self.size = size
        self.eof = eof
        self.mime = mime
        self.data = data
    }
}

public struct GitCwdParams: Codable, Equatable, Sendable {
    public var cwd: String
    public init(cwd: String) { self.cwd = cwd }
}

public struct GitStatusFile: Codable, Equatable, Sendable {
    public var path: String
    public var oldPath: String?
    /// Porcelain v1 index (X) and worktree (Y) codes, `?` for untracked.
    public var index: String
    public var worktree: String
    public var status: GitFileStatus
    public var staged: Bool
    public var unstaged: Bool

    public init(path: String, oldPath: String?, index: String, worktree: String, status: GitFileStatus, staged: Bool, unstaged: Bool) {
        self.path = path
        self.oldPath = oldPath
        self.index = index
        self.worktree = worktree
        self.status = status
        self.staged = staged
        self.unstaged = unstaged
    }

    enum CodingKeys: String, CodingKey {
        case path, index, worktree, status, staged, unstaged
        case oldPath = "old_path"
    }
}

public enum GitFileStatus: String, Codable, Sendable {
    case added, modified, deleted, renamed, copied, untracked, typechange, unmerged, unknown
}

public struct GitStatusResult: Codable, Equatable, Sendable {
    public var root: String
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var files: [GitStatusFile]

    public init(root: String, branch: String?, upstream: String?, ahead: Int, behind: Int, files: [GitStatusFile]) {
        self.root = root
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
    }
}

public struct GitDiffParams: Codable, Equatable, Sendable {
    public var cwd: String
    public var path: String?
    public var staged: Bool?
    public var base: String?
    /// Include untracked files as new-file diffs (default true when not staged).
    public var untracked: Bool?

    public init(cwd: String, path: String? = nil, staged: Bool? = nil, base: String? = nil, untracked: Bool? = nil) {
        self.cwd = cwd
        self.path = path
        self.staged = staged
        self.base = base
        self.untracked = untracked
    }
}

public struct GitDiffFile: Codable, Equatable, Sendable {
    public var path: String
    public var oldPath: String?
    public var status: GitFileStatus
    public var additions: Int
    public var deletions: Int
    public var binary: Bool

    public init(path: String, oldPath: String?, status: GitFileStatus, additions: Int, deletions: Int, binary: Bool) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.binary = binary
    }

    enum CodingKeys: String, CodingKey {
        case path, status, additions, deletions, binary
        case oldPath = "old_path"
    }
}

public struct GitDiffResult: Codable, Equatable, Sendable {
    public var diff: String
    public var files: [GitDiffFile]
    public var truncated: Bool

    public init(diff: String, files: [GitDiffFile], truncated: Bool) {
        self.diff = diff
        self.files = files
        self.truncated = truncated
    }
}

public struct GitLogParams: Codable, Equatable, Sendable {
    public var cwd: String
    public var limit: Int?
    public init(cwd: String, limit: Int? = nil) {
        self.cwd = cwd
        self.limit = limit
    }
}

public struct GitCommit: Codable, Equatable, Sendable {
    public var sha: String
    public var shortSha: String
    public var author: String
    public var email: String
    /// Unix seconds.
    public var time: Double
    public var subject: String

    public init(sha: String, shortSha: String, author: String, email: String, time: Double, subject: String) {
        self.sha = sha
        self.shortSha = shortSha
        self.author = author
        self.email = email
        self.time = time
        self.subject = subject
    }

    enum CodingKeys: String, CodingKey {
        case sha, author, email, time, subject
        case shortSha = "short_sha"
    }
}

public struct GitLogResult: Codable, Equatable, Sendable {
    public var commits: [GitCommit]
    public init(commits: [GitCommit]) { self.commits = commits }
}

public struct UploadPutParams: Codable, Equatable, Sendable {
    public var name: String
    public var dataB64: String
    public var dir: String?
    public init(name: String, dataB64: String, dir: String? = nil) {
        self.name = name
        self.dataB64 = dataB64
        self.dir = dir
    }
    enum CodingKeys: String, CodingKey {
        case name, dir
        case dataB64 = "data_b64"
    }
}

public struct UploadBeginParams: Codable, Equatable, Sendable {
    public var name: String
    public var dir: String?
    public var size: Int64?
    public init(name: String, dir: String? = nil, size: Int64? = nil) {
        self.name = name
        self.dir = dir
        self.size = size
    }
}

public struct UploadBeginResult: Codable, Equatable, Sendable {
    public var uploadID: String
    public init(uploadID: String) { self.uploadID = uploadID }
    enum CodingKeys: String, CodingKey { case uploadID = "upload_id" }
}

public struct UploadChunkParams: Codable, Equatable, Sendable {
    public var uploadID: String
    /// Byte offset of this chunk; must equal the bytes written so far when present.
    public var offset: Int64?
    public var dataB64: String
    public init(uploadID: String, offset: Int64? = nil, dataB64: String) {
        self.uploadID = uploadID
        self.offset = offset
        self.dataB64 = dataB64
    }
    enum CodingKeys: String, CodingKey {
        case offset
        case uploadID = "upload_id"
        case dataB64 = "data_b64"
    }
}

public struct UploadEndParams: Codable, Equatable, Sendable {
    public var uploadID: String
    /// Discard the partial file instead of finishing it.
    public var abort: Bool?
    public init(uploadID: String, abort: Bool? = nil) {
        self.uploadID = uploadID
        self.abort = abort
    }
    enum CodingKeys: String, CodingKey {
        case abort
        case uploadID = "upload_id"
    }
}

public struct UploadResult: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64
    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

public struct SessionRefsParams: Codable, Equatable, Sendable {
    /// Directory relative paths resolve against; defaults to the user's home.
    public var cwd: String?
    public var text: String
    public init(cwd: String? = nil, text: String) {
        self.cwd = cwd
        self.text = text
    }
}

public struct SessionRef: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, dir, url }
    /// Absolute path for files and dirs, the URL for urls.
    public var path: String
    /// The text as it appeared.
    public var match: String
    public var kind: Kind
    public var exists: Bool
    public var size: Int64?

    public init(path: String, match: String, kind: Kind, exists: Bool, size: Int64?) {
        self.path = path
        self.match = match
        self.kind = kind
        self.exists = exists
        self.size = size
    }
}

public struct SessionRefsResult: Codable, Equatable, Sendable {
    public var refs: [SessionRef]
    public init(refs: [SessionRef]) { self.refs = refs }
}
