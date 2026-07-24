import Darwin
import Foundation
import Testing

@Suite("Codex resume trust", .serialized)
struct CodexResumeTrustTests {
  private typealias H = CodexResumeTestHarness

  @Test
  func testCodexResumeTrustReadsCodexEffectiveConfig() throws {
    let cliPath = try H.bundledCLIPath()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cmux-codex-profile-trust-\(UUID().uuidString)", isDirectory: true)
    let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let modelsCache = codexHome.appendingPathComponent(
      "models_cache.json",
      isDirectory: false
    )
    try Data("{}".utf8).write(to: modelsCache)

    let codexArgumentsLog = root.appendingPathComponent("codex-arguments.log", isDirectory: false)
    let fakeCodex = root.appendingPathComponent("codex", isDirectory: false)
    let canonicalRoot = root.resolvingSymlinksInPath().path
    let response = try codexRequire(
      String(
        data: JSONSerialization.data(withJSONObject: [
          "id": 2,
          "result": [
            "config": [
              "projects": [
                canonicalRoot: ["trust_level": "trusted"]
              ]
            ],
            "origins": [
              "projects.\(canonicalRoot).trust_level": [
                "name": [
                  "type": "system",
                  "file": "/etc/codex/config.toml",
                ],
                "version": "test",
              ]
            ],
            "layers": NSNull(),
          ],
        ]),
        encoding: .utf8
      )
    )
    let emptyProjectsResponse = try codexRequire(
      String(
        data: JSONSerialization.data(withJSONObject: [
          "id": 2,
          "result": [
            "config": [
              "projects": [:]
            ],
            "origins": [:],
            "layers": NSNull(),
          ],
        ]),
        encoding: .utf8
      )
    )
    try """
    #!/bin/sh
    printf '%s\n' BEGIN "$@" >> "\(codexArgumentsLog.path)"
    static_catalog=false
    for argument in "$@"; do
      if [ "$argument" = 'model_catalog_json=\(modelsCache.path)' ]; then
        static_catalog=true
      fi
    done
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{"userAgent":"test","codexHome":"\(codexHome.path)","platformFamily":"unix","platformOs":"macos"}}'
          ;;
        *'"method":"config'*'read"'*)
          if [ "$static_catalog" = true ] && [ "${CMUX_TEST_REJECT_STATIC_CATALOG:-0}" = 1 ]; then
            printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"managed catalog rejects override"}}'
          elif [ "${CMUX_TEST_EMPTY_PROJECTS:-0}" = 1 ]; then
            printf '%s\n' '\(emptyProjectsResponse)'
          else
            printf '%s\n' '\(response)'
          fi
          ;;
      esac
    done
    """.write(to: fakeCodex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fakeCodex.path
    )

    var environment = ProcessInfo.processInfo.environment
    environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
    environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
    environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = H.base64NULSeparated([
      fakeCodex.path,
      "resume",
      "session-name",
      "--profile",
      "dogfood",
    ])
    environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = fakeCodex.path
    environment["CODEX_HOME"] = codexHome.path
    environment["CMUX_AGENT_HOOK_STATE_DIR"] =
      root
      .appendingPathComponent("initial-state", isDirectory: true)
      .path

    let result = H.runProcess(
      executablePath: cliPath,
      arguments: ["hooks", "codex", "inject-resume-args"],
      environment: environment,
      timeout: 2
    )

    codexExpectFalse(result.timedOut, result.stderr)
    codexExpectEqual(result.status, 0, result.stderr)
    codexExpectTrue(result.stdout.isEmpty, result.stdout)
    codexExpectEqual(
      try String(contentsOf: codexArgumentsLog, encoding: .utf8),
      """
      BEGIN
      --profile
      dogfood
      -c
      model_catalog_json=\(modelsCache.path)
      app-server
      --stdio

      """
    )

    try Data().write(to: codexArgumentsLog)
    environment["CMUX_TEST_REJECT_STATIC_CATALOG"] = "1"
    environment["CMUX_AGENT_HOOK_STATE_DIR"] =
      root
      .appendingPathComponent("fallback-state", isDirectory: true)
      .path
    let fallbackResult = H.runProcess(
      executablePath: cliPath,
      arguments: ["hooks", "codex", "inject-resume-args"],
      environment: environment,
      timeout: 2
    )

    codexExpectFalse(fallbackResult.timedOut, fallbackResult.stderr)
    codexExpectEqual(fallbackResult.status, 0, fallbackResult.stderr)
    codexExpectTrue(fallbackResult.stdout.isEmpty, fallbackResult.stdout)
    codexExpectEqual(
      try String(contentsOf: codexArgumentsLog, encoding: .utf8),
      """
      BEGIN
      --profile
      dogfood
      -c
      model_catalog_json=\(modelsCache.path)
      app-server
      --stdio
      BEGIN
      --profile
      dogfood
      app-server
      --stdio

      """
    )

    var gitEnvironment = ProcessInfo.processInfo.environment
    gitEnvironment.removeValue(forKey: "GIT_DIR")
    gitEnvironment.removeValue(forKey: "GIT_WORK_TREE")
    let separateGitDirectory = root.appendingPathComponent(
      "separate-git-metadata",
      isDirectory: true
    )
    let gitInit = H.runProcess(
      executablePath: "/usr/bin/git",
      arguments: [
        "init",
        "--separate-git-dir",
        separateGitDirectory.path,
        root.path,
      ],
      environment: gitEnvironment,
      timeout: 2
    )
    codexExpectFalse(gitInit.timedOut, gitInit.stderr)
    codexExpectEqual(gitInit.status, 0, gitInit.stderr)

    environment.removeValue(forKey: "CMUX_TEST_REJECT_STATIC_CATALOG")
    environment["CMUX_TEST_EMPTY_PROJECTS"] = "1"
    environment["CMUX_AGENT_HOOK_STATE_DIR"] =
      root
      .appendingPathComponent("separate-git-state", isDirectory: true)
      .path
    let separateGitProbe = H.runProcess(
      executablePath: cliPath,
      arguments: ["hooks", "codex", "inject-resume-args"],
      environment: environment,
      timeout: 2
    )

    codexExpectFalse(separateGitProbe.timedOut, separateGitProbe.stderr)
    codexExpectEqual(separateGitProbe.status, 0, separateGitProbe.stderr)
    codexExpectTrue(
      separateGitProbe.stdout.contains(
        #"projects={"\#(canonicalRoot)"={trust_level="untrusted"}}"#
      ),
      "A valid separate Git metadata directory must not suppress the unattended resume override: \(separateGitProbe.stdout)"
    )

    try FileManager.default.removeItem(
      at: root.appendingPathComponent(".git", isDirectory: false)
    )
    try FileManager.default.removeItem(at: separateGitDirectory)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: false
    )
    environment["CMUX_AGENT_HOOK_STATE_DIR"] =
      root
      .appendingPathComponent("repository-state", isDirectory: true)
      .path
    let failedRepositoryProbe = H.runProcess(
      executablePath: cliPath,
      arguments: ["hooks", "codex", "inject-resume-args"],
      environment: environment,
      timeout: 2
    )

    codexExpectFalse(failedRepositoryProbe.timedOut, failedRepositoryProbe.stderr)
    codexExpectEqual(failedRepositoryProbe.status, 0, failedRepositoryProbe.stderr)
    codexExpectTrue(
      failedRepositoryProbe.stdout.isEmpty,
      "A broken repository marker must fail closed instead of overriding project trust."
    )
  }

  @Test
  func testCodexResumeTrustCoalescesOnlyConcurrentEffectiveConfigProbes() throws {
    let cliPath = try H.bundledCLIPath()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "cmux-codex-trust-probe-cache-\(UUID().uuidString)", isDirectory: true)
    let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
    let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let modelsCache = codexHome.appendingPathComponent("models_cache.json", isDirectory: false)
    try Data("{}".utf8).write(to: modelsCache)
    let invocationLog = root.appendingPathComponent("codex-invocations.log", isDirectory: false)
    let fakeCodex = root.appendingPathComponent("codex", isDirectory: false)
    let emptyProjectsResponse = try codexRequire(
      String(
        data: JSONSerialization.data(withJSONObject: [
          "id": 2,
          "result": [
            "config": ["projects": [:]],
            "origins": [:],
            "layers": NSNull(),
          ],
        ]),
        encoding: .utf8
      )
    )
    try """
    #!/bin/sh
    printf '%s\n' BEGIN >> "\(invocationLog.path)"
    static_catalog=false
    for argument in "$@"; do
      if [ "$argument" = 'model_catalog_json=\(modelsCache.path)' ]; then
        static_catalog=true
      fi
    done
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{"userAgent":"test","codexHome":"\(codexHome.path)","platformFamily":"unix","platformOs":"macos"}}'
          ;;
        *'"method":"config'*'read"'*)
          sleep 0.2
          if [ "$static_catalog" = true ]; then
            printf '%s\n' '{"id":2,"error":{"code":-32602,"message":"managed catalog rejects override"}}'
          else
            printf '%s\n' '\(emptyProjectsResponse)'
          fi
          ;;
      esac
    done
    """.write(to: fakeCodex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fakeCodex.path
    )

    var environment = ProcessInfo.processInfo.environment
    environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
    environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
    environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = H.base64NULSeparated([
      fakeCodex.path,
      "resume",
      "session-name",
    ])
    environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = fakeCodex.path
    environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDirectory.path
    environment["CODEX_HOME"] = codexHome.path

    let processCount = 8
    var running: [(process: Process, stdout: Pipe, stderr: Pipe)] = []
    for _ in 0..<processCount {
      let process = Process()
      let stdout = Pipe()
      let stderr = Pipe()
      process.executableURL = URL(fileURLWithPath: cliPath)
      process.arguments = ["hooks", "codex", "inject-resume-args"]
      process.environment = environment
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = stdout
      process.standardError = stderr
      try process.run()
      running.append((process, stdout, stderr))
    }

    let deadline = Date().addingTimeInterval(5)
    while running.contains(where: { $0.process.isRunning }), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    for item in running where item.process.isRunning {
      item.process.terminate()
    }
    for item in running {
      item.process.waitUntilExit()
      let stdout =
        String(
          data: item.stdout.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) ?? ""
      let stderr =
        String(
          data: item.stderr.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) ?? ""
      codexExpectEqual(item.process.terminationStatus, 0, stderr)
      codexExpectTrue(
        stdout.contains("trust_level=\"untrusted\""),
        "Every coalesced caller must receive the cached trust decision."
      )
    }

    let laterResult = H.runProcess(
      executablePath: cliPath,
      arguments: ["hooks", "codex", "inject-resume-args"],
      environment: environment,
      timeout: 2
    )
    codexExpectFalse(laterResult.timedOut, laterResult.stderr)
    codexExpectEqual(laterResult.status, 0, laterResult.stderr)
    codexExpectTrue(laterResult.stdout.contains("trust_level=\"untrusted\""))

    let invocationCount = try String(contentsOf: invocationLog, encoding: .utf8)
      .split(separator: "\n")
      .filter { $0 == "BEGIN" }
      .count
    codexExpectEqual(
      invocationCount,
      4,
      "Concurrent restores should share two app-server attempts, while a later restore must probe again for config changes."
    )
  }
}
