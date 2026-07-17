import CmuxLiteCore
import Foundation

/// Resolves the user's Ghostty font and theme preferences for the native renderer.
@MainActor
final class CmuxGhosttyConfigurationResolver {
    private let environment: [String: String]
    private let homeDirectory: String
    private let fileManager: FileManager
    private var activeProcess: Process?
    private var outputPipe: Pipe?
    private var commandContinuation: CheckedContinuation<Data?, Never>?
    private var commandFinished = false

    init(
        environment: [String: String],
        homeDirectory: String,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func resolve(configPath: String) async -> CmuxGhosttyViewConfiguration {
        for executable in ghosttyExecutables() {
            guard let output = await showConfigOutput(from: executable),
                  let configuration = CmuxGhosttyViewConfiguration.parseResolvedOutput(output)
            else { continue }
            return configuration
        }

        let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        return CmuxGhosttyViewConfiguration.parseFallback(text) { [weak self] name in
            self?.themeContents(named: name)
        }
    }

    private func ghosttyExecutables() -> [String] {
        var candidates: [String] = []
        if let configured = environment["GHOSTTY_BIN"], !configured.isEmpty {
            candidates.append(configured)
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("ghostty", isDirectory: false)
                    .path
            })
        }
        candidates += [
            "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            "/Applications/cmux.app/Contents/Resources/bin/ghostty",
        ]

        var seen: Set<String> = []
        return candidates.filter { path in
            seen.insert(path).inserted && fileManager.isExecutableFile(atPath: path)
        }
    }

    private func showConfigOutput(from executable: String) async -> String? {
        let data: Data? = await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["+show-config"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishCommand(timedOut: false)
                }
            }

            activeProcess = process
            outputPipe = pipe
            commandContinuation = continuation
            commandFinished = false
            do {
                try process.run()
            } catch {
                finishCommand(timedOut: true)
                return
            }

            Task { @MainActor [weak self] in
                // This is a bounded subprocess deadline, not a synchronization delay.
                try? await ContinuousClock().sleep(for: .seconds(2))
                self?.finishCommand(timedOut: true)
            }
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private func finishCommand(timedOut: Bool) {
        guard !commandFinished, let continuation = commandContinuation else { return }
        commandFinished = true
        commandContinuation = nil

        let process = activeProcess
        let data = timedOut ? nil : outputPipe?.fileHandleForReading.readDataToEndOfFile()
        activeProcess = nil
        outputPipe = nil
        if timedOut, process?.isRunning == true {
            process?.terminate()
        }
        continuation.resume(returning: data)
    }

    private func themeContents(named name: String) -> String? {
        let path: String?
        if name.hasPrefix("/") {
            path = name
        } else if !name.contains("/") {
            path = themeDirectories()
                .map { directory in
                    URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(name, isDirectory: false)
                        .path
                }
                .first(where: fileManager.isReadableFile(atPath:))
        } else {
            path = nil
        }
        guard let path, fileManager.isReadableFile(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func themeDirectories() -> [String] {
        let configHome = environment["XDG_CONFIG_HOME"] ?? homeDirectory + "/.config"
        var directories = [configHome + "/ghostty/themes"]
        if let resources = environment["GHOSTTY_RESOURCES_DIR"], !resources.isEmpty {
            directories.append(resources + "/themes")
        }
        directories += [
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
            "/Applications/cmux.app/Contents/Resources/ghostty/themes",
        ]
        return directories
    }
}
