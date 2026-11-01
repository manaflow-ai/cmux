#if os(macOS)
import Foundation

/// Where the host keeps state, and the user's login-shell environment (a
/// launchd agent starts with a bare PATH, so harnesses would not be found).
public final class HostEnvironment: @unchecked Sendable {
    public let supportDirectory: URL
    public let shellEnvironment: [String: String]
    public let homeDirectory: String

    public init(supportDirectory: URL? = nil) {
        // Writing to a pipe whose reader died (an exited agent) must not kill
        // the host and every terminal with it.
        signal(SIGPIPE, SIG_IGN)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        homeDirectory = home
        let directory = supportDirectory ?? URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/cmux-next-mobile-host", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.supportDirectory = directory
        shellEnvironment = Self.captureLoginEnvironment()
    }

    private static func captureLoginEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "env -0"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for entry in data.split(separator: 0) {
                let text = String(decoding: entry, as: UTF8.self)
                guard let equals = text.firstIndex(of: "=") else { continue }
                let key = String(text[..<equals])
                if ["PWD", "OLDPWD", "SHLVL", "_", "TERM_SESSION_ID"].contains(key) { continue }
                environment[key] = String(text[text.index(after: equals)...])
            }
        } catch {}
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"]
        var path = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in extras where !path.contains(extra) { path.append(extra) }
        environment["PATH"] = path.joined(separator: ":")
        environment.removeValue(forKey: "CLAUDECODE")
        return environment
    }

    public func which(_ command: String) -> String? {
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        for directory in (shellEnvironment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
#endif
