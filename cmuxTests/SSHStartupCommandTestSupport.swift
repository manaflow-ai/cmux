import Foundation

/// Rewrites generated SSH startup fixtures to use a test-owned executable.
struct SSHStartupCommandTestSupport: Sendable {
    let sshExecutablePath: String

    func rewriting(_ startupCommand: String) throws -> String {
        if let scriptURL = referencedScriptURL(from: startupCommand) {
            let script = try String(contentsOf: scriptURL, encoding: .utf8)
            guard script.contains(Self.systemSSHPath) else {
                throw failure("Generated startup script did not pin \(Self.systemSSHPath)")
            }
            try script.replacingOccurrences(
                of: Self.systemSSHPath,
                with: sshExecutablePath
            ).write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            return startupCommand
        }

        var rewrittenCommand = startupCommand.replacingOccurrences(
            of: Self.systemSSHPath,
            with: sshExecutablePath
        )
        let directlyRewritten = rewrittenCommand != startupCommand
        let marker = "printf %s "
        guard let markerRange = rewrittenCommand.range(of: marker) else {
            guard directlyRewritten else {
                throw failure("Generated startup command did not pin \(Self.systemSSHPath)")
            }
            return rewrittenCommand
        }

        let encodedStart = markerRange.upperBound
        let encodedEnd = rewrittenCommand[encodedStart...]
            .firstIndex(where: \.isWhitespace) ?? rewrittenCommand.endIndex
        let encodedRange = encodedStart..<encodedEnd
        let encodedScript = String(rewrittenCommand[encodedRange])
        guard let scriptData = Data(base64Encoded: encodedScript),
              let script = String(data: scriptData, encoding: .utf8) else {
            throw failure("Generated startup command did not contain a UTF-8 base64 script")
        }
        guard script.contains(Self.systemSSHPath) else {
            guard directlyRewritten else {
                throw failure("Generated startup command did not pin \(Self.systemSSHPath)")
            }
            return rewrittenCommand
        }

        let rewrittenScript = script.replacingOccurrences(
            of: Self.systemSSHPath,
            with: sshExecutablePath
        )
        rewrittenCommand.replaceSubrange(
            encodedRange,
            with: Data(rewrittenScript.utf8).base64EncodedString()
        )
        return rewrittenCommand
    }

    private func referencedScriptURL(from startupCommand: String) -> URL? {
        let trimmedCommand = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmedCommand.trimmingCharacters(
            in: CharacterSet(charactersIn: "'")
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "SSHStartupCommandTestSupport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static let systemSSHPath = "/usr/bin/ssh"
}
