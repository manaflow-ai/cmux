import Darwin
import Foundation

private final class CodexResumeBundleToken: NSObject {}

enum CodexResumeTestHarness {
  struct ProcessRunResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
  }

  final class MockSocketState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommands: [String] = []

    var commands: [String] {
      snapshot()
    }

    func append(_ command: String) {
      lock.lock()
      storedCommands.append(command)
      lock.unlock()
    }

    func snapshot() -> [String] {
      lock.lock()
      let value = storedCommands
      lock.unlock()
      return value
    }
  }

  struct Context: Sendable {
    let cliPath: String
    let socketPath: String
    let listenerFD: Int32
    let state: MockSocketState
    let root: URL
    let workspaceId: String
    let surfaceId: String

    func cleanup() {
      Darwin.close(listenerFD)
      unlink(socketPath)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func replace(with value: Data) {
      lock.lock()
      data = value
      lock.unlock()
    }

    func snapshot() -> Data {
      lock.lock()
      let value = data
      lock.unlock()
      return value
    }
  }

  static func bundledCLIPath() throws -> String {
    let fileManager = FileManager.default
    let appBundleURL = Bundle(for: CodexResumeBundleToken.self)
      .bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let expectedCLIURL =
      appBundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent("cmux", isDirectory: false)

    if fileManager.isExecutableFile(atPath: expectedCLIURL.path) {
      return expectedCLIURL.path
    }

    let enumerator = fileManager.enumerator(
      at: appBundleURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    while let item = enumerator?.nextObject() as? URL {
      guard item.lastPathComponent == "cmux",
        item.path.contains(".app/Contents/Resources/bin/cmux"),
        fileManager.isExecutableFile(atPath: item.path)
      else {
        continue
      }
      return item.path
    }

    throw NSError(
      domain: "cmux.tests",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Bundled cmux CLI not found at \(expectedCLIURL.path)"
      ]
    )
  }

  static func makeContext(name: String) throws -> Context {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
    let socketPath = makeSocketPath(String(name.prefix(6)))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Context(
      cliPath: try bundledCLIPath(),
      socketPath: socketPath,
      listenerFD: try bindUnixSocket(at: socketPath),
      state: MockSocketState(),
      root: root,
      workspaceId: "11111111-1111-1111-1111-111111111111",
      surfaceId: "22222222-2222-2222-2222-222222222222"
    )
  }

  static func launchEnvironment(context: Context, sessionId: String) -> [String: String] {
    _ = sessionId
    return agentLaunchEnvironment(
      context: context,
      kind: "codex",
      executable: "/usr/local/bin/codex",
      arguments: ["/usr/local/bin/codex", "--model", "gpt-5.4"]
    )
  }

  static func runHook(
    context: Context,
    subcommand: String,
    standardInput: String,
    extraEnvironment: [String: String] = [:]
  ) -> ProcessRunResult {
    var environment = [
      "HOME": context.root.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "PWD": context.root.path,
      "CMUX_SOCKET_PATH": context.socketPath,
      "CMUX_WORKSPACE_ID": context.workspaceId,
      "CMUX_SURFACE_ID": context.surfaceId,
      "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
      "CMUX_CLI_SENTRY_DISABLED": "1",
    ]
    environment.merge(extraEnvironment, uniquingKeysWith: { _, new in new })

    return runProcess(
      executablePath: context.cliPath,
      arguments: ["hooks", "codex", subcommand],
      environment: environment,
      standardInput: standardInput,
      timeout: 5
    )
  }

  static func startMockServer(context: Context, connectionLimit: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
      var accepted = 0
      while accepted < connectionLimit {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.accept(context.listenerFD, socketAddress, &clientAddrLen)
          }
        }
        if clientFD < 0 {
          if errno == EINTR {
            continue
          }
          return
        }
        accepted += 1

        DispatchQueue.global(qos: .userInitiated).async {
          defer { Darwin.close(clientFD) }
          var pending = Data()
          var buffer = [UInt8](repeating: 0, count: 4096)
          while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
              if errno == EINTR {
                continue
              }
              return
            }
            if count == 0 {
              return
            }
            pending.append(buffer, count: count)
            while let newlineRange = pending.firstRange(of: Data([0x0A])) {
              let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
              pending.removeSubrange(0...newlineRange.lowerBound)
              guard let line = String(data: lineData, encoding: .utf8) else {
                continue
              }
              context.state.append(line)
              let response = mockResponse(line: line, context: context) + "\n"
              _ = response.withCString { pointer in
                Darwin.write(clientFD, pointer, strlen(pointer))
              }
            }
          }
        }
      }
    }
  }

  static func readSession(_ sessionId: String, context: Context) throws -> [String: Any] {
    let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
    let state = try codexRequire(
      JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
    )
    let sessions = try codexRequire(state["sessions"] as? [String: Any])
    return try codexRequire(sessions[sessionId] as? [String: Any])
  }

  static func writeRebindState(
    context: Context,
    sessionId: String,
    pid: Int?
  ) throws {
    let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
    let now = Date().timeIntervalSince1970
    var record: [String: Any] = [
      "sessionId": sessionId,
      "workspaceId": context.workspaceId,
      "surfaceId": context.surfaceId,
      "cwd": context.root.path,
      "runtimeStatus": "running",
      "activePromptDepth": 1,
      "activePromptTurnId": "interrupted-turn",
      "activePromptTurnIds": ["interrupted-turn"],
      "lastPromptTurnId": "interrupted-turn",
      "startedAt": now,
      "updatedAt": now,
    ]
    if let pid {
      record["pid"] = pid
    }
    let state: [String: Any] = [
      "version": 1,
      "sessions": [sessionId: record],
    ]
    try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
      .write(to: stateURL, options: .atomic)
  }

  static func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func base64NULSeparated(_ values: [String]) -> String {
    var data = Data()
    for value in values {
      data.append(contentsOf: value.utf8)
      data.append(0)
    }
    return data.base64EncodedString()
  }

  static func runProcess(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    standardInput: String? = nil,
    timeout: TimeInterval
  ) -> ProcessRunResult {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinPipe = standardInput == nil ? nil : Pipe()
    let stdoutCapture = CapturedOutput()
    let stderrCapture = CapturedOutput()
    let outputGroup = DispatchGroup()
    let exitSignal = DispatchSemaphore(value: 0)

    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = environment
    process.standardInput = stdinPipe ?? FileHandle.nullDevice
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.terminationHandler = { _ in exitSignal.signal() }

    do {
      try process.run()
    } catch {
      return ProcessRunResult(
        status: -1,
        stdout: "",
        stderr: String(describing: error),
        timedOut: false
      )
    }

    if let standardInput, let stdinPipe {
      stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
      try? stdinPipe.fileHandleForWriting.close()
    }

    outputGroup.enter()
    DispatchQueue.global(qos: .utility).async {
      stdoutCapture.replace(with: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
      outputGroup.leave()
    }

    outputGroup.enter()
    DispatchQueue.global(qos: .utility).async {
      stderrCapture.replace(with: stderrPipe.fileHandleForReading.readDataToEndOfFile())
      outputGroup.leave()
    }

    let timedOut = exitSignal.wait(timeout: .now() + processTimeout(timeout)) == .timedOut
    if timedOut {
      process.terminate()
      if exitSignal.wait(timeout: .now() + 1) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = exitSignal.wait(timeout: .now() + 1)
      }
    }
    _ = outputGroup.wait(timeout: .now() + 2)

    return ProcessRunResult(
      status: process.isRunning ? SIGKILL : process.terminationStatus,
      stdout: String(data: stdoutCapture.snapshot(), encoding: .utf8) ?? "",
      stderr: String(data: stderrCapture.snapshot(), encoding: .utf8) ?? "",
      timedOut: timedOut
    )
  }

  private static func agentLaunchEnvironment(
    context: Context,
    kind: String,
    executable: String,
    arguments: [String]
  ) -> [String: String] {
    [
      "CMUX_AGENT_LAUNCH_KIND": kind,
      "CMUX_AGENT_LAUNCH_EXECUTABLE": executable,
      "CMUX_AGENT_LAUNCH_CWD": context.root.path,
      "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(arguments),
    ]
  }

  private static func makeSocketPath(_ name: String) -> String {
    let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    return "/tmp/cli-\(name.prefix(3))-\(shortID).sock"
  }

  private static func bindUnixSocket(at path: String) throws -> Int32 {
    unlink(path)
    let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
      throw posixError("failed to create Unix socket")
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
    let utf8 = Array(path.utf8)
    guard utf8.count < maximumPathLength else {
      Darwin.close(fileDescriptor)
      throw NSError(
        domain: "cmux.tests",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)"]
      )
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: maximumPathLength) { buffer in
        for index in utf8.indices {
          buffer[index] = CChar(bitPattern: utf8[index])
        }
        buffer[utf8.count] = 0
      }
    }

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.bind(
          fileDescriptor,
          socketAddress,
          socklen_t(MemoryLayout<sockaddr_un>.size)
        )
      }
    }
    guard bindResult == 0 else {
      let error = posixError("failed to bind Unix socket")
      Darwin.close(fileDescriptor)
      throw error
    }
    guard Darwin.listen(fileDescriptor, 1) == 0 else {
      let error = posixError("failed to listen on Unix socket")
      Darwin.close(fileDescriptor)
      throw error
    }
    return fileDescriptor
  }

  private static func mockResponse(line: String, context: Context) -> String {
    guard let payload = jsonObject(line) else {
      return "OK"
    }
    guard let id = payload["id"] as? String,
      let method = payload["method"] as? String
    else {
      return malformedRequestResponse(id: payload["id"] as? String, raw: line)
    }
    switch method {
    case "surface.list":
      return v2Response(
        id: id,
        ok: true,
        result: [
          "surfaces": [
            [
              "id": context.surfaceId,
              "ref": "surface:1",
              "index": 1,
              "focused": true,
            ]
          ]
        ]
      )
    case "feed.push":
      return v2Response(id: id, ok: true, result: [:])
    case "surface.resume.set":
      return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
    case "surface.resume.clear":
      return v2Response(id: id, ok: true, result: ["cleared": true])
    default:
      return v2Response(
        id: id,
        ok: false,
        error: [
          "code": "unrecognized_method",
          "message": "unexpected method: \(method)",
        ]
      )
    }
  }

  private static func malformedRequestResponse(id: String?, raw: String) -> String {
    v2Response(
      id: id ?? "unknown",
      ok: false,
      error: [
        "code": "malformed_request",
        "message": "invalid or non-JSON payload",
        "raw": raw,
      ]
    )
  }

  private static func v2Response(
    id: String,
    ok: Bool,
    result: [String: Any]? = nil,
    error: [String: Any]? = nil
  ) -> String {
    var payload: [String: Any] = ["id": id, "ok": ok]
    if let result {
      payload["result"] = result
    }
    if let error {
      payload["error"] = error
    }
    let data = try? JSONSerialization.data(withJSONObject: payload)
    return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
  }

  private static func processTimeout(_ requested: TimeInterval) -> TimeInterval {
    let environment = ProcessInfo.processInfo.environment
    guard environment["GITHUB_ACTIONS"] == "true" || environment["CI"] == "true" else {
      return requested
    }
    return max(requested, 20)
  }

  private static func posixError(_ description: String) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(errno),
      userInfo: [NSLocalizedDescriptionKey: description]
    )
  }
}
