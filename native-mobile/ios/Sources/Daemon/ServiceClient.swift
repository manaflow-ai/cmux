import CmuxNativeLink
import Foundation

/// The `svc` channel: host services the daemon doesn't offer (files, git,
/// uploads, references). `{"id","method","params"}` →
/// `{"id","ok","result"|"error":{code,message}}`.
actor ServiceClient {
    private var channel: any LinkChannel
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var reader: Task<Void, Never>?
    /// Which channel the reader serves; an old reader ending after a rebind
    /// must not close the new one.
    private var generation = 0
    /// True once the channel ended (the link reconnected or the host went away)
    /// until `rebind` gives it a fresh `svc` channel.
    private(set) var isClosed = false

    init(channel: any LinkChannel) { self.channel = channel }

    func start() {
        guard reader == nil else { return }
        let incoming = channel.incoming
        let generation = generation
        reader = Task { [weak self] in
            for await line in incoming { await self?.handle(line) }
            await self?.finish(generation: generation)
        }
    }

    /// After a reconnect: the same client (screens keep their reference)
    /// continues on a new channel. Calls in flight on the old one fail.
    func rebind(_ newChannel: any LinkChannel) {
        finish(generation: generation)
        channel.close()
        generation += 1
        channel = newChannel
        reader = nil
        isClosed = false
        start()
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        if isClosed { throw DaemonClient.Failure(message: "The connection to your Mac closed.") }
        let id = nextID
        nextID += 1
        var line = try JSONEncoder().encode(JSONValue.object(["id": .number(Double(id)), "method": .string(method), "params": .object(params)]))
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let channel = channel
            Task {
                do { try await channel.send(line) } catch { self.fail(id, error) }
            }
        }
    }

    private func fail(_ id: Int, _ error: any Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }

    private func finish(generation: Int) {
        guard generation == self.generation else { return }
        isClosed = true
        for continuation in pending.values { continuation.resume(throwing: DaemonClient.Failure(message: "The connection to your Mac closed.")) }
        pending.removeAll()
    }

    private func handle(_ data: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let id = value["id"]?.int, let continuation = pending.removeValue(forKey: id) else { return }
        if value["ok"]?.bool == true {
            continuation.resume(returning: value["result"] ?? .null)
        } else {
            continuation.resume(throwing: DaemonClient.Failure(
                message: value["error"]?["message"]?.string ?? "The Mac could not do that.",
                code: value["error"]?["code"]?.string
            ))
        }
    }
}

struct HostFileEntry: Decodable, Sendable, Hashable, Identifiable {
    var name: String
    var path: String
    var kind: String
    var size: Int?
    var modified: Double?
    var mime: String?

    var id: String { path }
    var isDirectory: Bool { kind == "dir" || kind == "directory" }
}

struct HostFileRef: Decodable, Sendable, Hashable, Identifiable {
    var path: String
    var kind: String
    var exists: Bool?
    var size: Int?

    var id: String { path }
    var isURL: Bool { kind == "url" }
    var isDirectory: Bool { kind == "dir" }
}

extension ServiceClient {
    func list(path: String) async throws -> [HostFileEntry] {
        struct Listing: Decodable { var entries: [HostFileEntry] }
        return try await call("fs.list", ["path": .string(path)]).decode(Listing.self).entries
    }

    /// Reads a whole file in 512 KiB chunks.
    func read(path: String, limit: Int = 64 << 20, progress: (@Sendable (Double) -> Void)? = nil) async throws -> (data: Data, mime: String?) {
        var result = Data()
        var offset = 0
        var mime: String?
        let chunk = 512 << 10
        while true {
            // Leaving the preview cancels the rest of a large download.
            try Task.checkCancellation()
            let reply = try await call("fs.read", ["path": .string(path), "offset": .number(Double(offset)), "length": .number(Double(chunk))])
            mime = mime ?? reply["mime"]?.string
            let piece = Data(base64Encoded: reply["data"]?.string ?? "") ?? Data()
            result.append(piece)
            offset += piece.count
            let size = reply["size"]?.int ?? offset
            progress?(size > 0 ? Double(offset) / Double(size) : 1)
            if piece.isEmpty || offset >= size || offset >= limit { break }
        }
        return (result, mime)
    }

    func gitDiff(cwd: String, staged: Bool = false, base: String? = nil) async throws -> String {
        var params: [String: JSONValue] = ["cwd": .string(cwd), "staged": .bool(staged)]
        if let base { params["base"] = .string(base) }
        let reply = try await call("git.diff", params)
        return reply["diff"]?.string ?? reply["text"]?.string ?? reply.string ?? ""
    }

    func gitStatus(cwd: String) async throws -> JSONValue { try await call("git.status", ["cwd": .string(cwd)]) }

    /// Uploads an attachment and returns its path on the Mac.
    /// `progress` gets the bytes sent so far; cancelling the task stops
    /// between chunks.
    func upload(name: String, data: Data, progress: (@Sendable (Int) -> Void)? = nil) async throws -> String {
        let chunk = 384 << 10
        if data.count <= chunk {
            let reply = try await call("upload.put", ["name": .string(name), "data_b64": .string(data.base64EncodedString())])
            progress?(data.count)
            return try Self.uploadedPath(reply)
        }
        let begin = try await call("upload.begin", ["name": .string(name), "size": .number(Double(data.count))])
        let uploadID = begin["upload_id"]?.string ?? begin["id"]?.string ?? ""
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + chunk, data.count)
            _ = try await call("upload.chunk", ["upload_id": .string(uploadID), "offset": .number(Double(offset)), "data_b64": .string(data[offset..<end].base64EncodedString())])
            offset = end
            progress?(offset)
        }
        return try Self.uploadedPath(try await call("upload.end", ["upload_id": .string(uploadID)]))
    }

    private static func uploadedPath(_ reply: JSONValue) throws -> String {
        guard let path = reply["path"]?.string, !path.isEmpty else {
            throw DaemonClient.Failure(message: "Your Mac didn't say where it saved the file.")
        }
        return path
    }

    func refs(cwd: String?, text: String) async throws -> [HostFileRef] {
        struct Refs: Decodable { var refs: [HostFileRef] }
        var params: [String: JSONValue] = ["text": .string(text)]
        if let cwd { params["cwd"] = .string(cwd) }
        return try await call("session.refs", params).decode(Refs.self).refs
    }
}
