import Foundation
import CmuxNativeWire

/// `upload.put` and chunked `upload.begin/chunk/end`. Files land in
/// `~/Library/Caches/cmux-native-host/uploads/<yyyy-MM-dd>/<name>` unless the
/// phone names an allowed `dir`.
public actor UploadService {
    public static let maximumUploadBytes: Int64 = 2 << 30
    public static let maximumOpenUploads = 8

    struct Pending {
        var handle: FileHandle
        var partialPath: String
        var finalPath: String
        var written: Int64
        var expected: Int64?
    }

    public let uploadsRoot: String
    let guardrail: PathGuard
    private var pending: [String: Pending] = [:]

    public init(guardrail: PathGuard, uploadsRoot: String? = nil) {
        self.guardrail = guardrail
        self.uploadsRoot = uploadsRoot ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/cmux-native-host/uploads")
    }

    public func put(_ params: UploadPutParams) throws -> UploadResult {
        guard let data = Data(base64Encoded: params.dataB64) else { throw ServiceError.badRequest("data_b64 is not base64") }
        let path = try destination(name: params.name, dir: params.dir)
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ServiceError.failed("cannot write \(path)")
        }
        return UploadResult(path: path, size: Int64(data.count))
    }

    public func begin(_ params: UploadBeginParams) throws -> UploadBeginResult {
        if let size = params.size, size > Self.maximumUploadBytes { throw ServiceError.badRequest("upload exceeds 2 GiB") }
        guard pending.count < Self.maximumOpenUploads else { throw ServiceError(code: "busy", message: "too many open uploads") }
        let finalPath = try destination(name: params.name, dir: params.dir)
        let partial = finalPath + ".partial"
        guard FileManager.default.createFile(atPath: partial, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: partial) else {
            throw ServiceError.failed("cannot write \(partial)")
        }
        let id = UUID().uuidString.lowercased()
        pending[id] = Pending(handle: handle, partialPath: partial, finalPath: finalPath, written: 0, expected: params.size)
        return UploadBeginResult(uploadID: id)
    }

    public func chunk(_ params: UploadChunkParams) throws -> JSONValue {
        guard var upload = pending[params.uploadID] else { throw ServiceError.notFound("unknown upload_id") }
        guard let data = Data(base64Encoded: params.dataB64) else { throw ServiceError.badRequest("data_b64 is not base64") }
        if let offset = params.offset, offset != upload.written {
            throw ServiceError(code: "bad_offset", message: "expected offset \(upload.written), got \(offset)")
        }
        guard upload.written + Int64(data.count) <= (upload.expected ?? Self.maximumUploadBytes) else {
            abort(params.uploadID)
            throw ServiceError.badRequest("upload exceeds its declared size")
        }
        try upload.handle.write(contentsOf: data)
        upload.written += Int64(data.count)
        pending[params.uploadID] = upload
        return ["written": .number(Double(upload.written))]
    }

    public func end(_ params: UploadEndParams) throws -> UploadResult {
        guard let upload = pending.removeValue(forKey: params.uploadID) else { throw ServiceError.notFound("unknown upload_id") }
        try? upload.handle.close()
        if params.abort == true {
            try? FileManager.default.removeItem(atPath: upload.partialPath)
            return UploadResult(path: upload.finalPath, size: 0)
        }
        if let expected = upload.expected, expected != upload.written {
            try? FileManager.default.removeItem(atPath: upload.partialPath)
            throw ServiceError.badRequest("received \(upload.written) of \(expected) bytes")
        }
        let final = FileManager.default.fileExists(atPath: upload.finalPath) ? Self.unique(upload.finalPath) : upload.finalPath
        do { try FileManager.default.moveItem(atPath: upload.partialPath, toPath: final) } catch {
            throw ServiceError.failed("cannot finish upload: \(error.localizedDescription)")
        }
        return UploadResult(path: final, size: upload.written)
    }

    /// Discards every unfinished upload (channel closed).
    public func abortAll() {
        for id in Array(pending.keys) { abort(id) }
    }

    private func abort(_ id: String) {
        guard let upload = pending.removeValue(forKey: id) else { return }
        try? upload.handle.close()
        try? FileManager.default.removeItem(atPath: upload.partialPath)
    }

    private func destination(name: String, dir: String?) throws -> String {
        let directory: String
        if let dir, !dir.isEmpty {
            directory = try guardrail.resolve(dir)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
                throw ServiceError.notFound("\(dir) is not a directory")
            }
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            directory = (uploadsRoot as NSString).appendingPathComponent(formatter.string(from: Date()))
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        return Self.unique((directory as NSString).appendingPathComponent(Self.sanitize(name)))
    }

    static func sanitize(_ name: String) -> String {
        var base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "upload" }
        return String(base.prefix(200))
    }

    /// `name.ext`, then `name 2.ext`, `name 3.ext` ...
    static func unique(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) || fm.fileExists(atPath: path + ".partial") else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        let stem = (file as NSString).deletingPathExtension
        for n in 2... {
            let candidate = (dir as NSString).appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate), !fm.fileExists(atPath: candidate + ".partial") { return candidate }
        }
        return path
    }
}
