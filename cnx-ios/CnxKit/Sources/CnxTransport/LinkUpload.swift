import Foundation

/// Sends a file to the Mac over the link's `upload` service (PROTOCOL.md):
/// one channel per file, opened with `{name, size, cwd?}`, the bytes as data
/// frames, then the Mac's one reply `{"path","size"}` or `{"error","message"}`.
/// The Mac writes a new file (never replacing one) in
/// `<cwd>/.cmux/attachments/phone-<session>/` when `cwd` is a folder of one
/// of its tabs, else in its own uploads folder, and answers its real path.
public enum LinkUpload {
    /// The Mac's default cap (`CNX_UPLOAD_MAX_BYTES`); checked here first so a
    /// large file is refused before any byte is sent.
    public static let maxBytes = 100 << 20
    /// Bytes per channel write: the link splits larger writes anyway.
    static let chunkBytes = 192 << 10

    public struct Failure: Error, Equatable, Sendable, LocalizedError {
        public var code: String
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    /// Uploads `data` as `name` and returns the file's absolute path on the Mac.
    public static func upload(_ data: Data, name: String, cwd: String?, over link: any MacLink) async throws -> String {
        guard data.count <= maxBytes else {
            throw Failure(code: "too_large", message: "\(name) is larger than \(maxBytes >> 20) MB.")
        }
        var args = ["name": name, "size": String(data.count)]
        if let cwd, cwd.hasPrefix("/") { args["cwd"] = cwd }
        let channel: any LinkChannel
        do {
            channel = try await link.openChannel(service: "upload", args: args)
        } catch let error as LinkError {
            throw Failure(code: error.code, message: error.message)
        }
        // The Mac may refuse before reading (a folder it won't write to): a
        // failed send is not the answer, the reply is.
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            do { try await channel.send(data.subdata(in: offset..<end)) } catch { break }
            offset = end
        }
        var reply = Data()
        while let chunk = try await channel.receive() {
            reply.append(chunk)
        }
        return try path(fromReply: reply)
    }

    /// The path in the Mac's reply, or its refusal.
    public static func path(fromReply reply: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            throw Failure(code: "closed", message: "The Mac closed the upload without an answer.")
        }
        if let path = object["path"] as? String, path.hasPrefix("/") { return path }
        throw Failure(code: object["error"] as? String ?? "failed", message: object["message"] as? String ?? "The upload failed.")
    }

    /// `<cwd>` with a trailing slash removed, or nil.
    public static func folder(_ cwd: String?) -> String? {
        guard var cwd, cwd.hasPrefix("/") else { return nil }
        while cwd.count > 1, cwd.hasSuffix("/") { cwd.removeLast() }
        return cwd
    }
}
