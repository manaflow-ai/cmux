import Foundation
import Observation
import UIKit

/// Downloads a host file into a temp file and prepares the best preview.
@MainActor
@Observable
final class FilePreviewModel {
    enum Content: Sendable {
        case image(UIImage)
        case media(URL, isAudio: Bool)
        case pdf(URL)
        /// Rendered HTML (HTML/Markdown) or an SVG file, plus its source.
        case web(WebPreview.Source, source: CodeDocument)
        case code(CodeDocument)
        case quickLook(URL)
    }

    enum Phase {
        case checking
        case confirmLarge(Int)
        case downloading
        case failed(String)
        case ready(Content)
    }

    /// Files above this size ask before downloading.
    static let confirmBytes = 50 << 20

    let path: String
    private let services: ServiceClient
    private(set) var phase: Phase = .checking
    private(set) var progress: Double = 0
    private(set) var fileURL: URL?
    private(set) var kind: FilePreviewKind
    private var directory: URL?

    init(path: String, services: ServiceClient) {
        self.path = path
        self.services = services
        self.kind = FilePreviewKind.detect(path: path)
    }

    var fileName: String { (path as NSString).lastPathComponent }

    func start() async {
        guard case .checking = phase else { return }
        let size = await stat()
        if let size, size > Self.confirmBytes {
            phase = .confirmLarge(size)
            return
        }
        await download(expectedSize: size)
    }

    func retry() async {
        phase = .checking
        await start()
    }

    func confirmDownload() async {
        guard case .confirmLarge(let size) = phase else { return }
        await download(expectedSize: size)
    }

    private func stat() async -> Int? {
        guard let reply = try? await services.call("fs.stat", ["path": .string(path)]) else { return nil }
        return reply["size"]?.int ?? reply["entry"]?["size"]?.int
    }

    private func download(expectedSize: Int?) async {
        phase = .downloading
        progress = 0
        do {
            let limit = max((expectedSize ?? 0) + 1, 64 << 20)
            let (downloaded, mime) = try await services.read(path: path, limit: limit) { [weak self] value in
                Task { @MainActor in self?.progress = min(1, value) }
            }
            kind = FilePreviewKind.detect(path: path, mime: mime)
            var data = downloaded
            if kind == .markdown || kind == .html {
                data = await inlineRelativeImages(in: data)
            }
            let url = try writeTemp(data)
            fileURL = url
            let kind = kind
            let path = path
            phase = .ready(await Task.detached(priority: .userInitiated) {
                Self.prepare(data: data, url: url, kind: kind, path: path)
            }.value)
        } catch is CancellationError {
            phase = .checking
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Relative images (`img/logo.svg`) live on the Mac: fetch each one
    /// and embed it as a data URI so the sandboxed preview can show it.
    private func inlineRelativeImages(in data: Data) async -> Data {
        var text = String(decoding: data, as: UTF8.self)
        let folder = (path as NSString).deletingLastPathComponent
        let pattern = #"(src(?:set)?=["']|!\[[^\]]*\]\()([^"')\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return data }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var replacements: [String: String] = [:]
        for match in matches.prefix(40) {
            guard let range = Range(match.range(at: 2), in: text) else { continue }
            let reference = String(text[range])
            guard replacements[reference] == nil, !reference.contains("://"), !reference.hasPrefix("data:"),
                  !reference.hasPrefix("#"), replacements.count < 20 else { continue }
            let target = reference.hasPrefix("/") ? reference : (folder as NSString).appendingPathComponent(reference)
            guard let (bytes, mime) = try? await services.read(path: (target as NSString).standardizingPath, limit: 4 << 20),
                  !bytes.isEmpty else { continue }
            let type = mime ?? (reference.hasSuffix(".svg") ? "image/svg+xml" : "image/png")
            replacements[reference] = "data:\(type);base64,\(bytes.base64EncodedString())"
        }
        for (reference, uri) in replacements {
            text = text.replacingOccurrences(of: "\"\(reference)\"", with: "\"\(uri)\"")
                .replacingOccurrences(of: "'\(reference)'", with: "'\(uri)'")
                .replacingOccurrences(of: "](\(reference))", with: "](\(uri))")
        }
        return Data(text.utf8)
    }

    private func writeTemp(_ data: Data) throws -> URL {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-preview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
        let name = fileName.isEmpty ? "file" : fileName
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Picks the preview. Pure apart from decoding; runs off the main actor.
    nonisolated static func prepare(data: Data, url: URL, kind: FilePreviewKind, path: String) -> Content {
        switch kind {
        case .image:
            if let image = UIImage(data: data) { return .image(image) }
            return .quickLook(url)
        case .video: return .media(url, isAudio: false)
        case .audio: return .media(url, isAudio: true)
        case .pdf: return .pdf(url)
        case .svg:
            let text = String(decoding: data, as: UTF8.self)
            return .web(.file(url), source: CodeDocument.make(text: text, path: path, language: .plain))
        case .html:
            let text = String(decoding: data, as: UTF8.self)
            return .web(.file(url), source: CodeDocument.make(text: text, path: path, language: .plain))
        case .markdown:
            let text = String(decoding: data, as: UTF8.self)
            let base = url.deletingLastPathComponent()
            return .web(.html(FilePreviewMarkdown.page(markdown: text), baseURL: base), source: CodeDocument.make(text: text, path: path))
        case .json:
            return .code(CodeDocument.make(text: prettyJSON(data) ?? String(decoding: data, as: UTF8.self), path: "x.json"))
        case .text:
            return .code(CodeDocument.make(text: String(decoding: data, as: UTF8.self), path: path))
        case .other:
            if looksLikeText(data) { return .code(CodeDocument.make(text: String(decoding: data, as: UTF8.self), path: path)) }
            return .quickLook(url)
        }
    }

    nonisolated static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    /// No NUL bytes and valid UTF-8 in the first 8 KiB.
    nonisolated static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        guard !sample.isEmpty, !sample.contains(0) else { return sample.isEmpty }
        return String(data: sample, encoding: .utf8) != nil || String(data: sample.dropLast(3), encoding: .utf8) != nil
    }

    func cleanUp() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
