import Darwin
import Foundation
import XCTest


// MARK: - Diff viewer harness
extension CMUXOpenCommandTests {
    func runDiffCLIAndReadHTML(
        cliPath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        readPatchSidecar: Bool = true,
        socketResponse: (@Sendable (String) -> String?)? = nil
    ) throws -> (html: String, patch: String, params: [String: Any], stdout: String) {
        let socketPath = makeSocketPath("diff-src")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let response = socketResponse?(line) {
                return response
            }
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  method == "browser.open_split",
                  let params = payload["params"] as? [String: Any],
                  let rawURL = params["url"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "url": rawURL]
            )
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            currentDirectoryURL: currentDirectoryURL
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let commandPayload = try XCTUnwrap(
            state.commands.compactMap { Self.v2Payload(from: $0) }.first { payload in
                payload["method"] as? String == "browser.open_split"
            }
        )
        let params = try XCTUnwrap(commandPayload["params"] as? [String: Any])
        let rawURL = try XCTUnwrap(params["url"] as? String)
        XCTAssertEqual(params["bypass_remote_proxy"] as? Bool, true)
        let viewerURL = try XCTUnwrap(URL(string: rawURL))
        XCTAssertEqual(viewerURL.scheme, "http")
        XCTAssertEqual(viewerURL.host, "127.0.0.1")
        XCTAssertEqual(viewerURL.fragment, "cmux-diff-viewer")
        XCTAssertNil(params["diff_viewer_token"])
        XCTAssertNil(params["diff_viewer_files"])
        let openedFileURL = try diffViewerHTMLFileURL(for: rawURL, from: params)
        let viewerFileURL = try resolvedDiffViewerHTMLFileURL(openedFileURL, from: params)
        if openedFileURL != viewerFileURL {
            defer { try? FileManager.default.removeItem(at: openedFileURL) }
        }
        defer { try? FileManager.default.removeItem(at: viewerFileURL) }
        let html = try String(contentsOf: viewerFileURL, encoding: .utf8)
        let patchURL = viewerFileURL.deletingPathExtension().appendingPathExtension("patch")
        let patch: String
        if readPatchSidecar {
            defer { try? FileManager.default.removeItem(at: patchURL) }
            patch = try String(contentsOf: patchURL, encoding: .utf8)
        } else {
            patch = ""
        }
        return (html, patch, params, result.stdout)
    }

    func resolvedDiffViewerHTMLFileURL(_ fileURL: URL, from params: [String: Any]) throws -> URL {
        var current = fileURL
        for _ in 0..<4 {
            let html = try String(contentsOf: current, encoding: .utf8)
            guard let redirectURL = Self.diffViewerRedirectURL(from: html) else {
                return current
            }
            current = try diffViewerHTMLFileURL(for: redirectURL, from: params)
        }
        return current
    }

    private static func diffViewerRedirectURL(from html: String) -> String? {
        let marker = "data-cmux-diff-redirect=\""
        guard let start = html.range(of: marker)?.upperBound else { return nil }
        let tail = html[start...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    func diffViewerHTMLFileURL(from params: [String: Any]) throws -> URL {
        let rawURL = try XCTUnwrap(params["url"] as? String)
        return try diffViewerHTMLFileURL(for: rawURL, from: params)
    }

    static func diffViewerHTMLFileURLFromHTTPManifest(for rawURL: String) -> URL? {
        guard let viewerURL = URL(string: rawURL),
              viewerURL.scheme == "http",
              viewerURL.host == "127.0.0.1" else {
            return nil
        }
        let requestPath = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? viewerURL.path
        let pathParts = requestPath.split(separator: "/", omittingEmptySubsequences: true)
        guard let token = pathParts.first.map(String.init),
              !token.isEmpty else {
            return nil
        }
        let manifestRequestPath = "/" + pathParts.dropFirst().joined(separator: "/")
        let manifestURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = manifest["files"] as? [[String: Any]],
              let entry = files.first(where: { file in
                  file["request_path"] as? String == manifestRequestPath &&
                      file["mime_type"] as? String == "text/html"
              }),
              let filePath = entry["file_path"] as? String else {
            return nil
        }
        return URL(fileURLWithPath: filePath, isDirectory: false)
    }

    func diffViewerHTMLFileURL(for rawURL: String, from params: [String: Any]) throws -> URL {
        let viewerURL = try XCTUnwrap(URL(string: rawURL))
        if viewerURL.scheme == "http" {
            XCTAssertEqual(viewerURL.host, "127.0.0.1")
            let files = try diffViewerAllowedFiles(for: rawURL, from: params)
            let manifestRequestPath = try diffViewerManifestRequestPath(for: viewerURL)
            let entry = try XCTUnwrap(files.first { file in
                file["request_path"] as? String == manifestRequestPath &&
                    file["mime_type"] as? String == "text/html"
            })
            let filePath = try XCTUnwrap(entry["file_path"] as? String)
            return URL(fileURLWithPath: filePath, isDirectory: false)
        }

        let files = try XCTUnwrap(params["diff_viewer_files"] as? [[String: Any]])
        let rawRequestPath = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? viewerURL.path
        let requestPath = rawRequestPath.isEmpty ? "/" : rawRequestPath
        let entry = try XCTUnwrap(files.first { file in
            file["request_path"] as? String == requestPath &&
            file["mime_type"] as? String == "text/html"
        })
        let filePath = try XCTUnwrap(entry["file_path"] as? String)
        return URL(fileURLWithPath: filePath, isDirectory: false)
    }

    func diffViewerAllowedFiles(for rawURL: String, from params: [String: Any]) throws -> [[String: Any]] {
        let viewerURL = try XCTUnwrap(URL(string: rawURL))
        if viewerURL.scheme == "http" {
            let token = try diffViewerHTTPToken(for: viewerURL)
            let manifestURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
                .appendingPathComponent(".manifest-\(token).json", isDirectory: false)
            let manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            )
            return try XCTUnwrap(manifest["files"] as? [[String: Any]])
        }
        return try XCTUnwrap(params["diff_viewer_files"] as? [[String: Any]])
    }

    private func diffViewerHTTPToken(for url: URL) throws -> String {
        let requestPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let pathParts = requestPath.split(separator: "/", omittingEmptySubsequences: true)
        return try XCTUnwrap(pathParts.first.map(String.init))
    }

    private func diffViewerManifestRequestPath(for url: URL) throws -> String {
        let requestPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let pathParts = requestPath.split(separator: "/", omittingEmptySubsequences: true)
        _ = try XCTUnwrap(pathParts.first)
        return "/" + pathParts.dropFirst().joined(separator: "/")
    }

    func diffViewerConfig(from html: String) throws -> [String: Any] {
        let marker = "<script id=\"cmux-diff-viewer-config\" type=\"application/json\">"
        let start = try XCTUnwrap(html.range(of: marker)?.upperBound)
        let tail = html[start...]
        let end = try XCTUnwrap(tail.range(of: "</script>")?.lowerBound)
        let json = String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    func diffViewerAssets(from config: [String: Any]) throws -> [String: String] {
        let assets = try XCTUnwrap(config["assets"] as? [String: Any])
        var result: [String: String] = [:]
        for (key, value) in assets {
            result[key] = try XCTUnwrap(value as? String)
        }
        return result
    }

    func diffViewerOptionURL(value: String, in options: [[String: Any]]) throws -> String {
        let option = try XCTUnwrap(options.first { option in
            option["value"] as? String == value
        })
        XCTAssertEqual(option["disabled"] as? Bool, false)
        return try XCTUnwrap(option["url"] as? String)
    }

}
