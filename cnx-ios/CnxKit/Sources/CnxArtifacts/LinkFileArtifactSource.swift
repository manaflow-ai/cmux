import CnxTransport
import Foundation

/// Reads artifacts from the Mac over the link's `file` service (PROTOCOL.md):
/// one channel per file, opened with `{"path": <absolute path>}`, data frames
/// until the Mac closes it with `eof`. The Mac confines reads to workspace
/// roots and refuses folders, so folders and paths outside a root explain why.
public struct LinkFileArtifactSource: ArtifactSource {
    /// The connected Mac's link, or nil while offline.
    let link: @Sendable () async -> (any MacLink)?
    /// Resolves relative references (the session's working directory).
    let baseDirectory: String?
    let macName: String
    /// Largest file the preview reads (the rest is never requested).
    public static let maxBytes = 24 << 20

    public init(macName: String, baseDirectory: String?, link: @escaping @Sendable () async -> (any MacLink)?) {
        self.link = link
        self.baseDirectory = baseDirectory
        self.macName = macName
    }

    public func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
        switch artifact.kind {
        case .link:
            guard let url = URL(string: artifact.reference) else { throw ArtifactNotFound(reference: artifact.reference) }
            return .web(url)
        case .directory:
            throw ArtifactUnavailable("Folder listings aren't available from \(macName) yet. Open a file inside it instead.")
        default:
            break
        }
        guard let path = Self.absolutePath(artifact.reference, base: baseDirectory) else {
            throw ArtifactUnavailable("\(artifact.reference) isn't inside a known folder on \(macName).")
        }
        guard let link = await link() else {
            throw ArtifactUnavailable("Connect to \(macName) to open \(artifact.name).")
        }
        let data = try await Self.read(path: path, over: link, macName: macName)
        return try Self.content(for: artifact, data: data)
    }

    /// Absolute path for a reference: absolute stays, `./x` and `x/y` join the base; `~` can't be resolved here.
    public static func absolutePath(_ reference: String, base: String?) -> String? {
        if reference.hasPrefix("/") { return (reference as NSString).standardizingPath }
        guard let base, base.hasPrefix("/"), !reference.hasPrefix("~") else { return nil }
        let relative = reference.hasPrefix("./") ? String(reference.dropFirst(2)) : reference
        return ((base as NSString).appendingPathComponent(relative) as NSString).standardizingPath
    }

    static func read(path: String, over link: any MacLink, macName: String) async throws -> Data {
        let channel: any LinkChannel
        do {
            channel = try await link.openChannel(service: "file", args: ["path": path])
        } catch let error as LinkError {
            throw Self.unavailable(error, path: path, macName: macName)
        }
        var data = Data()
        do {
            while let chunk = try await channel.receive() {
                data.append(chunk)
                if data.count > maxBytes {
                    await channel.close(code: "cancelled", reason: "preview limit")
                    throw ArtifactUnavailable("This file is larger than \(maxBytes >> 20) MB, too large to preview on the phone.")
                }
            }
        } catch let error as LinkError {
            throw Self.unavailable(error, path: path, macName: macName)
        }
        // The Mac refuses by closing the channel (outside the shared
        // folders, missing, a folder): without this the refusal read as an
        // empty file and the preview stayed blank.
        if let closed = channel.closedBy, !closed.code.isEmpty, closed.code != "eof" {
            throw Self.unavailable(closed, path: path, macName: macName)
        }
        return data
    }

    static func unavailable(_ error: LinkError, path: String, macName: String) -> ArtifactUnavailable {
        let name = (path as NSString).lastPathComponent
        return switch error.code {
        case "not_found": ArtifactUnavailable("\(name) isn't on \(macName) anymore.")
        case "forbidden" where error.message.contains("no workspace roots"):
            // cnx-hostd shares no folder at all (CNX_FILE_ROOTS empty).
            ArtifactUnavailable("\(macName) isn't sharing any folders with this phone yet, so \(name) can't be opened here.")
        case "forbidden": ArtifactUnavailable("\(name) is outside the folders \(macName) shares with this phone.")
        case "bad_request": ArtifactUnavailable("\(name) isn't a regular file.")
        case "unknown_service": ArtifactUnavailable("\(macName) doesn't serve files yet. Update cmux on the Mac.")
        default: ArtifactUnavailable(error.message.isEmpty ? "Couldn't read \(name) from \(macName)." : error.message)
        }
    }

    /// Decodes bytes into the preview the kind wants.
    public static func content(for artifact: TerminalArtifact, data: Data) throws -> ArtifactContent {
        switch artifact.kind {
        case .image:
            return .image(data)
        case .pdf:
            return .pdf(data)
        case .video:
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cnx-artifact-\(abs(artifact.reference.hashValue))")
                .appendingPathExtension(artifact.fileExtension.isEmpty ? "mp4" : artifact.fileExtension)
            try data.write(to: url, options: .atomic)
            return .file(url)
        case .binary:
            return .binary(description: "\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))\n\(artifact.reference)")
        default:
            if data.isEmpty {
                return .binary(description: "Empty file\n\(artifact.reference)")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .binary(description: "Binary file, \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))\n\(artifact.reference)")
            }
            return .text(text)
        }
    }
}

/// Serves some references from data the session already holds (attachments,
/// images in tool output) and the rest from `fallback`.
public struct InlineArtifactSource: ArtifactSource {
    let inline: [String: ArtifactContent]
    let fallback: any ArtifactSource

    public init(inline: [String: ArtifactContent], fallback: any ArtifactSource) {
        self.inline = inline
        self.fallback = fallback
    }

    public func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
        if let content = inline[artifact.reference] { return content }
        return try await fallback.load(artifact)
    }
}
