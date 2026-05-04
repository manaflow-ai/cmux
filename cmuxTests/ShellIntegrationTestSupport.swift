import Darwin
import XCTest

func runInteractiveZsh(cmuxLoadGhosttyIntegration: Bool) throws -> String {
    try runInteractiveZsh(
        cmuxLoadGhosttyIntegration: cmuxLoadGhosttyIntegration,
        cmuxLoadShellIntegration: false,
        command: "(( $+functions[_ghostty_deferred_init] )) && _ghostty_deferred_init >/dev/null 2>&1; " +
            "print -r -- \"PRECMD=${+functions[_ghostty_precmd]} " +
            "PREEXEC=${+functions[_ghostty_preexec]} PRECMDS=${(j:,:)precmd_functions}\""
    )
}

func runInteractiveZsh(
    cmuxLoadGhosttyIntegration: Bool,
    cmuxLoadShellIntegration: Bool,
    command: String,
    extraEnvironment: [String: String] = [:],
    userZshEnvContents: String? = nil,
    userZshRCContents: String? = nil
) throws -> String {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("cmux-zsh-shell-integration-\(UUID().uuidString)")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let userZdotdir = root.appendingPathComponent("zdotdir")
    try fileManager.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
    var userZshEnvFileContents = "\n"
    if let path = extraEnvironment["PATH"] {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        userZshEnvFileContents = "export PATH=\"\(escaped)\"\n"
    }
    if let userZshEnvContents {
        if !userZshEnvFileContents.hasSuffix("\n") {
            userZshEnvFileContents.append("\n")
        }
        userZshEnvFileContents.append(userZshEnvContents)
        if !userZshEnvFileContents.hasSuffix("\n") {
            userZshEnvFileContents.append("\n")
        }
    }
    try userZshEnvFileContents.write(
        to: userZdotdir.appendingPathComponent(".zshenv"),
        atomically: true,
        encoding: .utf8
    )
    if let userZshRCContents {
        try userZshRCContents.write(
            to: userZdotdir.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )
    }

    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let cmuxZdotdir = repoRoot.appendingPathComponent("Resources/shell-integration")
    let ghosttyResources = repoRoot.appendingPathComponent("ghostty/src")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-i", "-c", command]
    process.environment = [
        "HOME": root.path,
        "TERM": "xterm-256color",
        "SHELL": "/bin/zsh",
        "USER": NSUserName(),
        "ZDOTDIR": cmuxZdotdir.path,
        "CMUX_ZSH_ZDOTDIR": userZdotdir.path,
        "CMUX_SHELL_INTEGRATION": "0",
        "GHOSTTY_RESOURCES_DIR": ghosttyResources.path,
    ]
    if cmuxLoadGhosttyIntegration {
        process.environment?["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
    }
    if cmuxLoadShellIntegration {
        process.environment?["CMUX_SHELL_INTEGRATION"] = "1"
        process.environment?["CMUX_SHELL_INTEGRATION_DIR"] = cmuxZdotdir.path
        process.environment?["CMUX_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
        process.environment?["CMUX_TAB_ID"] = "tab-test"
        process.environment?["CMUX_PANEL_ID"] = "panel-test"
    }
    for (key, value) in extraEnvironment {
        process.environment?[key] = value
    }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        XCTFail("Timed out waiting for zsh to exit")
    }

    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    XCTAssertEqual(process.terminationStatus, 0, error)
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func runPromptInteractiveZsh(
    cmuxLoadGhosttyIntegration: Bool,
    cmuxLoadShellIntegration: Bool,
    command: String,
    extraEnvironment: [String: String] = [:],
    userZshEnvContents: String? = nil,
    userZshRCContents: String? = nil
) throws -> String {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("cmux-zsh-prompt-integration-\(UUID().uuidString)")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let userZdotdir = root.appendingPathComponent("zdotdir")
    try fileManager.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
    var userZshEnvFileContents = "\n"
    if let path = extraEnvironment["PATH"] {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        userZshEnvFileContents = "export PATH=\"\(escaped)\"\n"
    }
    if let userZshEnvContents {
        if !userZshEnvFileContents.hasSuffix("\n") {
            userZshEnvFileContents.append("\n")
        }
        userZshEnvFileContents.append(userZshEnvContents)
        if !userZshEnvFileContents.hasSuffix("\n") {
            userZshEnvFileContents.append("\n")
        }
    }
    try userZshEnvFileContents.write(
        to: userZdotdir.appendingPathComponent(".zshenv"),
        atomically: true,
        encoding: .utf8
    )
    if let userZshRCContents {
        try userZshRCContents.write(
            to: userZdotdir.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )
    }

    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let cmuxZdotdir = repoRoot.appendingPathComponent("Resources/shell-integration")
    let ghosttyResources = repoRoot.appendingPathComponent("ghostty/src")
    let readyPath = root.appendingPathComponent("ready", isDirectory: false)
    let outputPath = root.appendingPathComponent("output.log", isDirectory: false)

    var masterFD: Int32 = -1
    var slaveFD: Int32 = -1
    guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
        let message = "openpty failed: \(String(cString: strerror(errno)))"
        XCTFail(message)
        throw NSError(
            domain: "ZshShellIntegrationHandoffTests",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-i"]
    process.environment = [
        "HOME": root.path,
        "TERM": "xterm-256color",
        "SHELL": "/bin/zsh",
        "USER": NSUserName(),
        "ZDOTDIR": cmuxZdotdir.path,
        "CMUX_ZSH_ZDOTDIR": userZdotdir.path,
        "CMUX_SHELL_INTEGRATION": "0",
        "GHOSTTY_RESOURCES_DIR": ghosttyResources.path,
        "CMUX_TEST_READY": readyPath.path,
        "CMUX_TEST_OUTPUT": outputPath.path,
    ]
    if cmuxLoadGhosttyIntegration {
        process.environment?["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
    }
    if cmuxLoadShellIntegration {
        process.environment?["CMUX_SHELL_INTEGRATION"] = "1"
        process.environment?["CMUX_SHELL_INTEGRATION_DIR"] = cmuxZdotdir.path
        process.environment?["CMUX_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
        process.environment?["CMUX_TAB_ID"] = "tab-test"
        process.environment?["CMUX_PANEL_ID"] = "panel-test"
    }
    for (key, value) in extraEnvironment {
        process.environment?[key] = value
    }

    let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
    process.standardInput = slaveHandle
    process.standardOutput = slaveHandle
    process.standardError = slaveHandle

    let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
    let terminalOutputLock = NSLock()
    var terminalOutputData = Data()
    masterHandle.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }
        terminalOutputLock.lock()
        terminalOutputData.append(data)
        terminalOutputLock.unlock()
    }
    defer { masterHandle.readabilityHandler = nil }

    func terminalOutputSnapshot() -> String {
        terminalOutputLock.lock()
        defer { terminalOutputLock.unlock() }
        return String(data: terminalOutputData, encoding: .utf8) ?? ""
    }

    try process.run()
    slaveHandle.closeFile()

    let readyDeadline = Date().addingTimeInterval(5)
    while !fileManager.fileExists(atPath: readyPath.path) && Date() < readyDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if !fileManager.fileExists(atPath: readyPath.path) {
        process.terminate()
        process.waitUntilExit()
        let terminalOutput = terminalOutputSnapshot()
        let message = "Timed out waiting for interactive zsh prompt: \(terminalOutput)"
        XCTFail(message)
        throw NSError(
            domain: "ZshShellIntegrationHandoffTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    masterHandle.write(Data((command + "\nexit\n").utf8))

    let exitDeadline = Date().addingTimeInterval(5)
    while process.isRunning && Date() < exitDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        let terminalOutput = terminalOutputSnapshot()
        let message = "Timed out waiting for interactive zsh to exit: \(terminalOutput)"
        XCTFail(message)
        throw NSError(
            domain: "ZshShellIntegrationHandoffTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    let terminalOutput = terminalOutputSnapshot()
    XCTAssertEqual(process.terminationStatus, 0, terminalOutput)
    return (try? String(contentsOf: outputPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
