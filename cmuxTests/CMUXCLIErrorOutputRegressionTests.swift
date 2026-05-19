import Darwin
import XCTest

final class CMUXCLIErrorOutputRegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }

    func testCLIErrorPathDoesNotCrashWhenStderrIsClosed() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) definitely-not-a-command 2>&-",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Usage:"), result.stdout)
    }

    func testUseCommandRejectsNoRunWithCommandOverrideBeforeRepositoryResolution() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use not-a-github-repo --command \"./start.sh\" --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("cannot be used with --no-run"), result.stdout)
    }

    func testBundledCLIInTaggedDebugAppPrefersItsOwnSocketWithoutEnvironmentOverride() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-socket-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let stableSocketURL = try stableSocketURL()

        if FileManager.default.fileExists(atPath: stableSocketURL.path) {
            throw XCTSkip("Stable cmux socket already exists at \(stableSocketURL.path)")
        }

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "TAGGED",
            result.stdout
        )
    }

    func testUseCommandHidesRawGitErrorOutput() throws {
        let cliPath = try bundledCLIPath()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeBinURL = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        let fakeGitURL = fakeBinURL.appendingPathComponent("git", isDirectory: false)
        try """
        #!/bin/sh
        echo "fatal: internal-host.example token secret --ff-only remote get-url origin" >&2
        exit 42
        """.write(to: fakeGitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeGitURL.path)

        let homeURL = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let result = runShell(
            "HOME=\(shellSingleQuote(homeURL.path)) PATH=\(shellSingleQuote(fakeBinURL.path)):/usr/bin:/bin CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use owner/repo --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Failed to download extension repository (exit 42)"), result.stdout)
        XCTAssertFalse(result.stdout.contains("fatal:"), result.stdout)
        XCTAssertFalse(result.stdout.contains("internal-host.example"), result.stdout)
        XCTAssertFalse(result.stdout.contains("token secret"), result.stdout)
        XCTAssertFalse(result.stdout.contains("--ff-only"), result.stdout)
        XCTAssertFalse(result.stdout.contains("remote get-url"), result.stdout)
    }

    func testBundledCLISkipsIdentifierlessNestedAppWhenResolvingTaggedSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-nested-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let stableSocketURL = try stableSocketURL()

        if FileManager.default.fileExists(atPath: stableSocketURL.path) {
            throw XCTSkip("Stable cmux socket already exists at \(stableSocketURL.path)")
        }

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug,
            nestedIdentifierlessApp: true
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "TAGGED",
            result.stdout
        )
    }

    func testUseCommandRejectsOptionLikeCommandValueBeforeCheckout() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use owner/repo --command --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("--command requires a command, not another flag"), result.stdout)
    }

    func testUseCommandInvalidRepositoryDoesNotEchoRawInput() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use \(shellSingleQuote("https://credential-secret@github.com/bad*/repo")) --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Invalid GitHub repository"), result.stdout)
        XCTAssertFalse(result.stdout.contains("credential-secret"), result.stdout)
        XCTAssertFalse(result.stdout.contains("bad*/repo"), result.stdout)
    }

    func testUseCommandRejectsSymlinkedSensitiveInstallPath() throws {
        let cliPath = try bundledCLIPath()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let homeURL = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL.appendingPathComponent(".ssh", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: homeURL.appendingPathComponent("safe-link", isDirectory: true).path,
            withDestinationPath: ".ssh"
        )

        let fakeBinURL = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        let fakeGitURL = fakeBinURL.appendingPathComponent("git", isDirectory: false)
        try """
        #!/bin/sh
        if [ "$1" = "clone" ]; then
          mkdir -p "$3/.git"
          cat > "$3/cmux.extension.json" <<'JSON'
        {"id":"owner.repo","name":"Repo","publisher":"owner","version":"0.0.1","install":{"path":"~/safe-link"}}
        JSON
          exit 0
        fi
        exit 1
        """.write(to: fakeGitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeGitURL.path)

        let result = runShell(
            "HOME=\(shellSingleQuote(homeURL.path)) PATH=\(shellSingleQuote(fakeBinURL.path)):/usr/bin:/bin CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use owner/repo --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("install.path must not target sensitive home directory ~/.ssh"), result.stdout)
        XCTAssertFalse(result.stdout.contains("OK "), result.stdout)
    }

    func testUseCommandGeneratedManifestFallsBackFromUnsafePackageVersion() throws {
        let cliPath = try bundledCLIPath()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeBinURL = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        let fakeGitURL = fakeBinURL.appendingPathComponent("git", isDirectory: false)
        try """
        #!/bin/sh
        if [ "$1" = "clone" ]; then
          mkdir -p "$3/.git"
          cat > "$3/package.json" <<'JSON'
        {"name":"Repo","version":"../../sensitive"}
        JSON
          exit 0
        fi
        exit 1
        """.write(to: fakeGitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeGitURL.path)

        let homeURL = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let result = runShell(
            "HOME=\(shellSingleQuote(homeURL.path)) PATH=\(shellSingleQuote(fakeBinURL.path)):/usr/bin:/bin CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) --socket cmux-test.sock use owner/repo --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Failed to connect to cmux socket at cmux-test.sock"), result.stdout)

        let generatedManifestURL = homeURL
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("extension-metadata", isDirectory: true)
            .appendingPathComponent("github.com", isDirectory: true)
            .appendingPathComponent("owner", isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
            .appendingPathComponent("cmux.extension.generated.json", isDirectory: false)
        let data = try Data(contentsOf: generatedManifestURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? String, "0.0.0-generated")
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CMUXCLIErrorOutputRegressionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stableSocketURL() throws -> URL {
        let appSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let directory = appSupport.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cmux.sock", isDirectory: false)
    }

    private func fakeTaggedBundledCLIPath(
        sourceCLIPath: String,
        tagSlug: String,
        nestedIdentifierlessApp: Bool = false
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-socket-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("cmux DEV \(tagSlug).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let binURL: URL
        if nestedIdentifierlessApp {
            let nestedContentsURL = contentsURL
                .appendingPathComponent("Resources/NestedTool.app/Contents", isDirectory: true)
            binURL = nestedContentsURL.appendingPathComponent("Resources/bin", isDirectory: true)
            let nestedInfoData = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleName": "NestedTool",
                    "CFBundlePackageType": "APPL"
                ],
                format: .xml,
                options: 0
            )
            try FileManager.default.createDirectory(
                at: nestedContentsURL,
                withIntermediateDirectories: true
            )
            try nestedInfoData.write(to: nestedContentsURL.appendingPathComponent("Info.plist", isDirectory: false))
        } else {
            binURL = contentsURL.appendingPathComponent("Resources/bin", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.cmuxterm.app.debug.\(tagSlug.replacingOccurrences(of: "-", with: "."))",
            "CFBundleName": "cmux DEV \(tagSlug)",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

        let fakeCLIURL = binURL.appendingPathComponent("cmux", isDirectory: false)
        try FileManager.default.copyItem(atPath: sourceCLIPath, toPath: fakeCLIURL.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCLIURL.path
        )
        return fakeCLIURL.path
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func runShell(_ command: String, timeout: TimeInterval) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}

private final class UnixSocketResponder {
    let path: String
    private let response: String
    private let queue = DispatchQueue(label: "com.cmux.tests.unix-socket-responder")
    private let lock = NSLock()
    private var stopped = false
    private var listenerFD: Int32 = -1

    init(path: String, response: String) throws {
        self.path = path
        self.response = response

        unlink(path)
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw Self.posixError("socket")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)"]
            )
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let buffer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, pointer, maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(listenerFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = Self.posixError("bind")
            close(listenerFD)
            listenerFD = -1
            throw error
        }
        guard listen(listenerFD, 8) == 0 else {
            let error = Self.posixError("listen")
            close(listenerFD)
            listenerFD = -1
            throw error
        }

        let fd = listenerFD
        queue.async { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
    }

    deinit {
        stop()
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()

        if fd >= 0 {
            close(fd)
        }
        unlink(path)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(listenerFD: Int32) {
        while !isStopped {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if isStopped {
                    return
                }
                continue
            }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var request = Data()
        while true {
            var byte: UInt8 = 0
            let count = read(clientFD, &byte, 1)
            if count <= 0 {
                return
            }
            request.append(byte)
            if byte == 0x0A {
                break
            }
        }
        guard !request.isEmpty else {
            return
        }
        let payload = response + "\n"
        payload.withCString { pointer in
            _ = write(clientFD, pointer, strlen(pointer))
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
