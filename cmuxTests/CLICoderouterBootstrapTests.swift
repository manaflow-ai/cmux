import Darwin
import Foundation
import Testing

/// `cmux cr` on a machine that has no CodeRouter CLI
/// (https://github.com/manaflow-ai/cmux/issues/12139).
///
/// Every test isolates HOME and PATH so the developer's own CodeRouter install,
/// `~/.coderouter`, and `~/.cmux` never take part, and none of them reaches the
/// network: the interactive bootstrap runs a local stand-in for install.sh
/// through the Debug-only `CMUX_CODEROUTER_INSTALLER_SCRIPT` seam. The stand-in
/// honors the real installer's contract (a `coderouter` executable in
/// `$HOME/.coderouter/bin`) so the re-resolve and exec after installing are the
/// production code path.
@Suite("CodeRouter CLI bootstrap")
struct CLICoderouterBootstrapTests {
    static let installCommand = "curl -fsSL https://cmux.com/coderouter/install.sh | sh"
    static let confirmPrompt = "Install CodeRouter now? [y/N]"

    enum InstallRoot: CustomStringConvertible {
        case installerDefault
        case explicitCoderouterInstall

        var description: String {
            switch self {
            case .installerDefault: return "~/.coderouter"
            case .explicitCoderouterInstall: return "$CODEROUTER_INSTALL"
            }
        }
    }

    @Test("non-interactive: prints the exact install command, exits 127, touches nothing")
    func nonInteractiveMissingBinaryPrintsInstallCommand() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let result = fixture.runCLI(
            arguments: ["cr", "--version"],
            extraEnvironment: [
                "CMUX_SOCKET_CAPABILITY": "missing-capability",
                "CMUX_SOCKET_PASSWORD": "missing-password",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 127, Comment(rawValue: result.stderr))
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains(Self.installCommand), Comment(rawValue: result.stderr))
        // No terminal to answer on, so no question is asked.
        #expect(!result.stderr.contains("[y/N]"), Comment(rawValue: result.stderr))
        #expect(!result.stderr.contains(fixture.root.path))
        #expect(!result.stderr.contains(fixture.socketPath))
        #expect(!result.stderr.contains("missing-capability"))
        #expect(!result.stderr.contains("missing-password"))
        #expect(!fixture.fileManager.fileExists(atPath: fixture.installerDefaultRoot.path))
    }

    @Test(
        "an install the shell PATH does not know yet is still exec'd, with no prompt",
        arguments: [InstallRoot.installerDefault, InstallRoot.explicitCoderouterInstall]
    )
    func installerLocationIsResolvedWithoutPATH(installRoot: InstallRoot) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let root: URL
        var extraEnvironment: [String: String] = [:]
        switch installRoot {
        case .installerDefault:
            root = fixture.installerDefaultRoot
        case .explicitCoderouterInstall:
            root = fixture.root.appendingPathComponent("custom-install-root", isDirectory: true)
            extraEnvironment["CODEROUTER_INSTALL"] = root.path
        }
        try fixture.writeExecutable(
            """
            #!/bin/sh
            printf '<%s>\\n' "$@" > "$HOME/coderouter-args"
            printf 'installed coderouter\\n'
            exit 41
            """,
            at: root.appendingPathComponent("bin/coderouter", isDirectory: false)
        )

        let result = fixture.runCLI(arguments: ["cr", "login", "--device-auth"], extraEnvironment: extraEnvironment)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 41, Comment(rawValue: result.stderr))
        #expect(result.stdout == "installed coderouter\n")
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
        #expect(try fixture.readHomeFile("coderouter-args") == "<login>\n<--device-auth>\n")
    }

#if DEBUG
    @Test("terminal: offers the documented installer once, runs it after y, then execs the install")
    func terminalOfferInstallsAndExecs() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let installerScript = try fixture.writeFakeInstaller()

        let result = try fixture.runCLIUnderPTY(
            arguments: ["cr", "--version"],
            input: "y\n",
            extraEnvironment: ["CMUX_CODEROUTER_INSTALLER_SCRIPT": installerScript.path]
        )

        #expect(!result.timedOut, Comment(rawValue: result.transcript))
        #expect(result.transcript.contains(Self.installCommand), Comment(rawValue: result.transcript))
        #expect(result.transcript.contains(Self.confirmPrompt), Comment(rawValue: result.transcript))
        #expect(fixture.installerRan, Comment(rawValue: result.transcript))
        #expect(result.transcript.contains("fake installer done"), Comment(rawValue: result.transcript))
        // The installed binary receives the original arguments and its exit status is ours.
        #expect(try fixture.readHomeFile("coderouter-args") == "<--version>\n")
        #expect(result.transcript.contains("installed coderouter ran"), Comment(rawValue: result.transcript))
        #expect(result.status == 41, Comment(rawValue: result.transcript))
    }
#endif

    @Test("terminal: declining installs nothing, prints the install command, exits 127")
    func terminalDeclineKeepsMachineUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let installerScript = try fixture.writeFakeInstaller()

        let result = try fixture.runCLIUnderPTY(
            arguments: ["cr", "--version"],
            input: "n\n",
            extraEnvironment: ["CMUX_CODEROUTER_INSTALLER_SCRIPT": installerScript.path]
        )

        #expect(!result.timedOut, Comment(rawValue: result.transcript))
        #expect(result.status == 127, Comment(rawValue: result.transcript))
        #expect(result.transcript.contains(Self.confirmPrompt), Comment(rawValue: result.transcript))
        #expect(result.transcript.contains(Self.installCommand), Comment(rawValue: result.transcript))
        #expect(!fixture.installerRan, Comment(rawValue: result.transcript))
        #expect(!fixture.fileManager.fileExists(atPath: fixture.installerDefaultRoot.path))
    }

    @Test("an existing install is exec'd unchanged and the installer never runs")
    func existingInstallNeverRunsTheInstaller() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let installerScript = try fixture.writeFakeInstaller()
        let pathDirectory = fixture.root.appendingPathComponent("path-bin", isDirectory: true)
        try fixture.writeExecutable(
            """
            #!/bin/sh
            printf '<%s>\\n' "$@" > "$HOME/coderouter-args"
            printf 'path coderouter\\n'
            exit 41
            """,
            at: pathDirectory.appendingPathComponent("coderouter", isDirectory: false)
        )

        // A terminal with `y` already typed: were cmux to ask, it would install.
        let result = try fixture.runCLIUnderPTY(
            arguments: ["cr", "--version"],
            input: "y\n",
            extraEnvironment: [
                "PATH": pathDirectory.path,
                "CMUX_CODEROUTER_INSTALLER_SCRIPT": installerScript.path,
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.transcript))
        #expect(result.status == 41, Comment(rawValue: result.transcript))
        #expect(result.transcript.contains("path coderouter"), Comment(rawValue: result.transcript))
        #expect(!result.transcript.contains(Self.confirmPrompt), Comment(rawValue: result.transcript))
        #expect(try fixture.readHomeFile("coderouter-args") == "<--version>\n")
        #expect(!fixture.installerRan, Comment(rawValue: result.transcript))
        #expect(!fixture.fileManager.fileExists(atPath: fixture.installerDefaultRoot.path))
    }

    // MARK: - Fixture

    struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    struct PTYResult {
        let status: Int32
        let transcript: String
        let timedOut: Bool
    }

    private final class TranscriptBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ bytes: [UInt8], count: Int) {
            lock.lock()
            data.append(contentsOf: bytes[0..<count])
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    struct Fixture {
        let fileManager = FileManager.default
        let cliPath: String
        /// Holds an isolated HOME, an empty PATH directory, and every marker file.
        let root: URL
        let home: URL
        let emptyPathDirectory: URL
        let socketPath: String

        init() throws {
            cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
            root = fileManager.temporaryDirectory
                .appendingPathComponent("cmux-coderouter-bootstrap-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            emptyPathDirectory = root.appendingPathComponent("empty-path", isDirectory: true)
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: emptyPathDirectory, withIntermediateDirectories: true)
            let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
            socketPath = "/tmp/cli-crb-\(shortID).sock"
        }

        /// Where install.sh puts the binary when `CODEROUTER_INSTALL` is unset.
        var installerDefaultRoot: URL {
            home.appendingPathComponent(".coderouter", isDirectory: true)
        }

        var installerRan: Bool {
            fileManager.fileExists(atPath: home.appendingPathComponent("installer-ran", isDirectory: false).path)
        }

        func cleanUp() {
            try? fileManager.removeItem(at: root)
        }

        func readHomeFile(_ name: String) throws -> String {
            try String(contentsOf: home.appendingPathComponent(name, isDirectory: false), encoding: .utf8)
        }

        /// The CLI's environment: the test host's, minus every cmux control value,
        /// with HOME and PATH pointed at this fixture and the socket at a path that
        /// does not exist, so nothing here can reach a running cmux.
        func environment(merging extra: [String: String]) -> [String: String] {
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys where key.hasPrefix("CMUX_") || key.hasPrefix("CMUXD_") {
                environment.removeValue(forKey: key)
            }
            environment.removeValue(forKey: "CODEROUTER_INSTALL")
            environment["HOME"] = home.path
            environment["CFFIXED_USER_HOME"] = home.path
            environment["PATH"] = emptyPathDirectory.path
            environment["AppleLanguages"] = "(en)"
            environment["AppleLocale"] = "en_US"
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            environment.merge(extra) { _, newValue in newValue }
            return environment
        }

        func writeExecutable(_ contents: String, at url: URL) throws {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        /// A stand-in for install.sh that records that it ran and installs a fake
        /// `coderouter` where the real installer puts it. PATH is empty, so every
        /// tool is addressed absolutely.
        func writeFakeInstaller() throws -> URL {
            let url = root.appendingPathComponent("fake-install.sh", isDirectory: false)
            try writeExecutable(
                """
                #!/bin/sh
                set -eu
                /usr/bin/touch "$HOME/installer-ran"
                /bin/mkdir -p "$HOME/.coderouter/bin"
                /bin/cat > "$HOME/.coderouter/bin/coderouter" <<'CODEROUTER'
                #!/bin/sh
                printf '<%s>\\n' "$@" > "$HOME/coderouter-args"
                printf 'installed coderouter ran\\n'
                exit 41
                CODEROUTER
                /bin/chmod 755 "$HOME/.coderouter/bin/coderouter"
                printf 'fake installer done\\n'
                """,
                at: url
            )
            return url
        }

        /// Runs the CLI with piped stdio and stdin at /dev/null: the non-interactive case.
        func runCLI(arguments: [String], extraEnvironment: [String: String] = [:]) -> ProcessResult {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = arguments
            process.environment = environment(merging: extraEnvironment)
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                return ProcessResult(status: 127, stdout: "", stderr: error.localizedDescription, timedOut: false)
            }
            let timedOut = Self.waitOrKill(process, finished: finished, timeout: 10)
            let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return ProcessResult(
                status: timedOut ? 124 : process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                timedOut: timedOut
            )
        }

        /// Runs the CLI with all three stdio fds on a pseudo-terminal, the way a
        /// person at a terminal would, and answers the prompt with `input`.
        func runCLIUnderPTY(
            arguments: [String],
            input: String,
            extraEnvironment: [String: String] = [:]
        ) throws -> PTYResult {
            var masterFD: Int32 = -1
            var slaveFD: Int32 = -1
            guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            func slaveHandle() throws -> FileHandle {
                let fd = dup(slaveFD)
                guard fd >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            }
            let stdinHandle: FileHandle
            let stdoutHandle: FileHandle
            let stderrHandle: FileHandle
            do {
                stdinHandle = try slaveHandle()
                stdoutHandle = try slaveHandle()
                stderrHandle = try slaveHandle()
            } catch {
                Darwin.close(slaveFD)
                Darwin.close(masterFD)
                throw error
            }
            Darwin.close(slaveFD)
            let master = masterFD

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = arguments
            process.environment = environment(merging: extraEnvironment)
            process.standardInput = stdinHandle
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                Darwin.close(master)
                throw error
            }
            // Only the CLI holds the slave now; when it (or what it exec'd) exits,
            // the master read below reports end of file.
            stdinHandle.closeFile()
            stdoutHandle.closeFile()
            stderrHandle.closeFile()

            // The line discipline queues the answer until the CLI reads stdin, so
            // it can be written before the prompt appears.
            let inputBytes = Array(input.utf8)
            var written = 0
            while written < inputBytes.count {
                let count = inputBytes[written...].withUnsafeBufferPointer { buffer in
                    Darwin.write(master, buffer.baseAddress, buffer.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                written += count
            }

            let transcript = TranscriptBuffer()
            let drained = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(master, &buffer, buffer.count)
                    if count > 0 {
                        transcript.append(buffer, count: count)
                        continue
                    }
                    if count < 0, errno == EINTR {
                        continue
                    }
                    break
                }
                drained.signal()
            }

            let timedOut = Self.waitOrKill(process, finished: finished, timeout: 10)
            _ = drained.wait(timeout: .now() + 2)
            Darwin.close(master)
            return PTYResult(
                status: timedOut ? 124 : process.terminationStatus,
                transcript: transcript.text,
                timedOut: timedOut
            )
        }

        private static func waitOrKill(_ process: Process, finished: DispatchSemaphore, timeout: TimeInterval) -> Bool {
            if finished.wait(timeout: .now() + timeout) == .success {
                return false
            }
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 2)
            return true
        }
    }
}
