public import Foundation

/// Typed wrappers around the `cmux browser …` family.
///
/// The macOS app exposes a Playwright-shaped browser automation API
/// (`docs/agent-browser-port-spec.md`). We mirror just the surfaces the iOS
/// UI uses today; the rest is reachable via `client.rawBrowser(args:)` for
/// scripting needs.
extension CMUXClient {

    @discardableResult
    public func browserGoto(_ url: URL, surfaceID: SurfaceID) async throws -> CmuxExecResult {
        try await runBrowserCommand([
                cmuxBinaryPath, "browser", "goto",
                "--surface", surfaceID.raw,
                url.absoluteString
        ])
    }

    @discardableResult
    public func browserBack(surfaceID: SurfaceID) async throws -> CmuxExecResult {
        try await runBrowserCommand([cmuxBinaryPath, "browser", "back", "--surface", surfaceID.raw])
    }

    @discardableResult
    public func browserForward(surfaceID: SurfaceID) async throws -> CmuxExecResult {
        try await runBrowserCommand([cmuxBinaryPath, "browser", "forward", "--surface", surfaceID.raw])
    }

    @discardableResult
    public func browserReload(surfaceID: SurfaceID) async throws -> CmuxExecResult {
        try await runBrowserCommand([cmuxBinaryPath, "browser", "reload", "--surface", surfaceID.raw])
    }

    public func browserURL(surfaceID: SurfaceID) async throws -> URL? {
        let result = try await runBrowserCommand([cmuxBinaryPath, "browser", "url", "--surface", surfaceID.raw])
        let trimmed = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)
    }

    @discardableResult
    public func browserScreenshot(surfaceID: SurfaceID) async throws -> Data {
        let result = try await transport.runOneShot(
            command: ShellEscape.command([
                cmuxBinaryPath, "browser", "screenshot",
                "--surface", surfaceID.raw,
                "--json"
            ]),
            stdin: nil
        )
        guard result.exitCode == 0 else {
            throw CmuxError.command(exitCode: result.exitCode, stderr: result.stderrString)
        }
        guard
            let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        else {
            throw CmuxError.decoding("expected browser screenshot JSON", underlying: nil)
        }
        if let b64 = object["png_base64"] as? String,
           let data = Data(base64Encoded: b64) {
            return data
        }
        let path = (object["path"] as? String)
            ?? (object["url"] as? String).flatMap { URL(string: $0)?.path }
        guard let path, !path.isEmpty else {
            throw CmuxError.decoding("browser screenshot JSON did not include image data or a path", underlying: nil)
        }
        let cat = try await transport.runOneShot(
            command: ShellEscape.command(["cat", path]),
            stdin: nil
        )
        guard cat.exitCode == 0 else {
            throw CmuxError.command(exitCode: cat.exitCode, stderr: cat.stderrString)
        }
        return cat.stdout
    }

    /// Pass-through escape hatch for the full `cmux browser` surface.
    public func rawBrowser(args: [String]) async throws -> CmuxExecResult {
        var parts = [cmuxBinaryPath, "browser"]
        parts.append(contentsOf: args)
        return try await runBrowserCommand(parts)
    }

    private func runBrowserCommand(_ parts: [String]) async throws -> CmuxExecResult {
        let result = try await transport.runOneShot(
            command: ShellEscape.command(parts),
            stdin: nil
        )
        guard result.exitCode == 0 else {
            throw CmuxError.command(
                exitCode: result.exitCode,
                stderr: result.stderrString.isEmpty ? result.stdoutString : result.stderrString
            )
        }
        return result
    }
}
