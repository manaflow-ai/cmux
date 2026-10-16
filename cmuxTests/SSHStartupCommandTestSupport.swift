import Foundation

/// Locates the encoded script in current and historical CLI startup wrappers.
enum SSHStartupCommandTestSupport {
    static func decodedScript(in command: String) -> String? {
        decodedPayload(in: command)?.script
    }

    static func replacingPinnedSSH(
        in command: String,
        with executablePath: String,
        additionalReplacements: [String: String] = [:]
    ) -> String? {
        guard let payload = decodedPayload(in: command),
              payload.script.contains("/usr/bin/ssh") else { return nil }
        var rewritten = payload.script.replacingOccurrences(of: "/usr/bin/ssh", with: executablePath)
        for (original, replacement) in additionalReplacements {
            rewritten = rewritten.replacingOccurrences(of: original, with: replacement)
        }
        // Replace both copies in legacy wrappers, including the decoder fallback.
        return command.replacingOccurrences(
            of: String(command[payload.range]), with: Data(rewritten.utf8).base64EncodedString()
        )
    }

    private static func decodedPayload(in command: String) -> (range: Range<String.Index>, script: String)? {
        guard let range = payloadRange(in: command),
              let data = Data(base64Encoded: String(command[range])),
              let script = String(data: data, encoding: .utf8) else { return nil }
        return (range, script)
    }

    static func startProcess(_ process: Process) throws {
        do {
            try process.run()
        } catch {
            let failure = error as NSError
            let arguments = [process.executableURL?.path ?? ""] + (process.arguments ?? [])
            let environment = process.environment ?? ProcessInfo.processInfo.environment
            var details = failure.userInfo
            details["argvBytes"] = arguments.reduce(0) { $0 + $1.utf8.count + 1 }
            details["largestArgumentBytes"] = arguments.map { $0.utf8.count }.max() ?? 0
            details["environmentBytes"] = environment.reduce(0) {
                $0 + $1.key.utf8.count + $1.value.utf8.count + 2
            }
            throw NSError(domain: failure.domain, code: failure.code, userInfo: details)
        }
    }

    private static func payloadRange(in command: String) -> Range<String.Index>? {
        if let assignment = command.range(of: "cmux_payload=") {
            let end = command[assignment.upperBound...].firstIndex(of: "\n") ?? command.endIndex
            return unquoted(assignment.upperBound..<end, in: command)
        }
        guard let prefix = command.range(of: "(printf %s "),
              let suffix = command.range(of: " | base64", range: prefix.upperBound..<command.endIndex) else {
            return nil
        }
        return unquoted(prefix.upperBound..<suffix.lowerBound, in: command)
    }

    private static func unquoted(_ range: Range<String.Index>, in command: String) -> Range<String.Index> {
        guard !range.isEmpty else { return range }
        let last = command.index(before: range.upperBound)
        let first = command[range.lowerBound]
        if range.lowerBound != last, (first == "'" || first == "\""), command[last] == first {
            return command.index(after: range.lowerBound)..<last
        }
        return range
    }
}
