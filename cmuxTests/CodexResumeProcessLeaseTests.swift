import Darwin
import Foundation
import Testing

@Suite("Codex resume process leases", .serialized)
struct CodexResumeProcessLeaseTests {
  private typealias H = CodexResumeTestHarness

  @Test
  func testCodexWrapperResumeSessionStartRebindsInterruptedActivePrompt() throws {
    let context = try H.makeContext(name: "codex-wrapper-resume-rebind")
    defer { context.cleanup() }

    let sessionId = "interrupted-active-session"
    let resumedPID = Int(Darwin.getpid())
    let oldPID = resumedPID
    let now = Date().timeIntervalSince1970
    let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
    let store: [String: Any] = [
      "version": 1,
      "sessions": [
        sessionId: [
          "sessionId": sessionId,
          "workspaceId": context.workspaceId,
          "surfaceId": context.surfaceId,
          "cwd": context.root.path,
          "pid": oldPID,
          "pidStartSeconds": 1,
          "pidStartMicroseconds": 0,
          "runtimeStatus": "running",
          "activePromptDepth": 1,
          "activePromptTurnId": "interrupted-turn",
          "activePromptTurnIds": ["interrupted-turn"],
          "lastPromptTurnId": "interrupted-turn",
          "startedAt": now,
          "updatedAt": now,
        ]
      ],
    ]
    try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
      .write(to: stateURL, options: .atomic)

    H.startMockServer(context: context, connectionLimit: 24)
    let result = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: H.launchEnvironment(context: context, sessionId: sessionId).merging(
        [
          "CMUX_CODEX_PID": String(resumedPID)
        ], uniquingKeysWith: { _, new in new })
    )

    codexExpectFalse(result.timedOut, result.stderr)
    codexExpectEqual(result.status, 0, result.stderr)
    let record = try H.readSession(sessionId, context: context)
    codexExpectEqual(
      record["pid"] as? Int,
      resumedPID,
      "A wrapper-confirmed resume must replace the dead pre-crash PID."
    )
    codexExpectNil(
      record["activePromptDepth"],
      "The interrupted pre-crash turn must not make the resumed process look nested."
    )
    codexExpectTrue(
      context.state.commands.contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "The resumed process must republish its binding for another crash cycle."
    )
  }

  @Test
  func testCodexTurnFromNewerProcessWinsDelayedResumeRebindAndOlderHooks() throws {
    let context = try H.makeContext(name: "codex-newer-turn-before-rebind")
    defer { context.cleanup() }

    let sessionId = "newer-turn-before-rebind-session"
    let oldPID = Int(Darwin.getpid())
    let resumedProcess = Process()
    let resumedProcessInput = Pipe()
    resumedProcess.executableURL = URL(fileURLWithPath: "/bin/cat")
    resumedProcess.standardInput = resumedProcessInput
    try resumedProcess.run()
    defer {
      try? resumedProcessInput.fileHandleForWriting.close()
      if resumedProcess.isRunning {
        resumedProcess.terminate()
      }
      resumedProcess.waitUntilExit()
    }
    let resumedPID = Int(resumedProcess.processIdentifier)
    let launchEnvironment = H.launchEnvironment(
      context: context,
      sessionId: sessionId
    )
    H.startMockServer(context: context, connectionLimit: 96)

    let initialStart = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
      extraEnvironment: launchEnvironment.merging(
        [
          "CMUX_CODEX_PID": String(oldPID)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectEqual(initialStart.status, 0, initialStart.stderr)

    let interruptedPrompt = H.runHook(
      context: context,
      subcommand: "prompt-submit",
      standardInput:
        #"{"session_id":"\#(sessionId)","turn_id":"interrupted-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"before crash"}"#,
      extraEnvironment: launchEnvironment.merging(
        [
          "CMUX_CODEX_PID": String(oldPID)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectEqual(interruptedPrompt.status, 0, interruptedPrompt.stderr)

    let resumedPrompt = H.runHook(
      context: context,
      subcommand: "prompt-submit",
      standardInput:
        #"{"session_id":"\#(sessionId)","turn_id":"resumed-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"after restore"}"#,
      extraEnvironment: launchEnvironment.merging(
        [
          "CMUX_CODEX_PID": String(resumedPID)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectEqual(resumedPrompt.status, 0, resumedPrompt.stderr)

    let delayedRebind = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: launchEnvironment.merging(
        [
          "CMUX_CODEX_PID": String(resumedPID)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectEqual(delayedRebind.status, 0, delayedRebind.stderr)

    let staleOldPrompt = H.runHook(
      context: context,
      subcommand: "prompt-submit",
      standardInput:
        #"{"session_id":"\#(sessionId)","turn_id":"stale-old-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"late old hook"}"#,
      extraEnvironment: launchEnvironment.merging(
        [
          "CMUX_CODEX_PID": String(oldPID)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectEqual(staleOldPrompt.status, 0, staleOldPrompt.stderr)

    let record = try H.readSession(sessionId, context: context)
    codexExpectEqual(record["pid"] as? Int, resumedPID)
    codexExpectEqual(record["activePromptDepth"] as? Int, 1)
    codexExpectEqual(record["activePromptTurnId"] as? String, "resumed-turn")
    codexExpectEqual(record["activePromptTurnIds"] as? [String], ["resumed-turn"])
    codexExpectEqual(record["lastPromptTurnId"] as? String, "resumed-turn")
  }

  @Test
  func testDelayedOlderCodexResumeCannotReplaceNewerActiveProcess() throws {
    let context = try H.makeContext(name: "codex-delayed-resume-generation")
    defer { context.cleanup() }

    let sessionId = "newer-active-session"
    let incomingPID = Int(Darwin.getpid())
    let newerPID = 22_222
    let now = Date().timeIntervalSince1970
    let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
    let store: [String: Any] = [
      "version": 1,
      "sessions": [
        sessionId: [
          "sessionId": sessionId,
          "workspaceId": context.workspaceId,
          "surfaceId": context.surfaceId,
          "cwd": context.root.path,
          "pid": newerPID,
          "pidStartSeconds": Int64(now) + 3_600,
          "pidStartMicroseconds": 0,
          "runtimeStatus": "running",
          "activePromptDepth": 1,
          "activePromptTurnId": "newer-turn",
          "activePromptTurnIds": ["newer-turn"],
          "lastPromptTurnId": "newer-turn",
          "startedAt": now,
          "updatedAt": now,
        ]
      ],
    ]
    try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
      .write(to: stateURL, options: .atomic)

    H.startMockServer(context: context, connectionLimit: 24)
    let result = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: H.launchEnvironment(context: context, sessionId: sessionId).merging(
        [
          "CMUX_CODEX_PID": String(incomingPID)
        ], uniquingKeysWith: { _, new in new })
    )

    codexExpectFalse(result.timedOut, result.stderr)
    codexExpectEqual(result.status, 0, result.stderr)
    let record = try H.readSession(sessionId, context: context)
    codexExpectEqual(
      record["pid"] as? Int,
      newerPID,
      "A delayed older resume event must not replace the newer process generation."
    )
    codexExpectEqual(
      record["activePromptDepth"] as? Int,
      1,
      "A delayed older resume event must not clear the newer process's active turn."
    )
    codexExpectFalse(
      context.state.commands.contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "A rejected older resume event must not republish the session binding."
    )
  }

  @Test
  func testDelayedOlderCodexResumeCannotReplaceAcceptedNewerProcessAfterTurnStateClears() throws {
    let context = try H.makeContext(name: "codex-repeat-generation")
    defer { context.cleanup() }
    let sessionId = "accepted-newer-session"
    let olderPID = Int(Darwin.getpid())
    let deadPID = Int(Int32.max)
    let newerProcess = Process()
    let newerProcessInput = Pipe()
    newerProcess.executableURL = URL(fileURLWithPath: "/bin/cat")
    newerProcess.standardInput = newerProcessInput
    try newerProcess.run()
    defer {
      try? newerProcessInput.fileHandleForWriting.close()
      if newerProcess.isRunning {
        newerProcess.terminate()
      }
      newerProcess.waitUntilExit()
    }
    let newerPID = Int(newerProcess.processIdentifier)
    try H.writeRebindState(
      context: context,
      sessionId: sessionId,
      pid: deadPID
    )
    H.startMockServer(context: context, connectionLimit: 48)

    let acceptedResume = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: H.launchEnvironment(context: context, sessionId: sessionId).merging(
        [
          "CMUX_CODEX_PID": String(newerPID)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectFalse(acceptedResume.timedOut, acceptedResume.stderr)
    codexExpectEqual(acceptedResume.status, 0, acceptedResume.stderr)
    var record = try H.readSession(sessionId, context: context)
    codexExpectEqual(record["pid"] as? Int, newerPID)
    codexExpectNil(record["activePromptDepth"])
    codexExpectTrue(
      context.state.commands.contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "The newer resume must replace the dead legacy owner."
    )

    let delayedStart = context.state.commands.count
    let delayedResume = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: H.launchEnvironment(context: context, sessionId: sessionId).merging(
        [
          "CMUX_CODEX_PID": String(olderPID)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectFalse(delayedResume.timedOut, delayedResume.stderr)
    codexExpectEqual(delayedResume.status, 0, delayedResume.stderr)
    record = try H.readSession(sessionId, context: context)
    codexExpectEqual(record["pid"] as? Int, newerPID)
    codexExpectEqual(record["workspaceId"] as? String, context.workspaceId)
    codexExpectEqual(record["surfaceId"] as? String, context.surfaceId)
    codexExpectFalse(
      context.state.commands.dropFirst(delayedStart).contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "A delayed older rebind must remain stale after the accepted newer resume clears interrupted-turn guards."
    )
  }

  @Test
  func testDelayedOlderCodexStopCannotRetireNewerProcessMonitorLease() throws {
    let context = try H.makeContext(name: "codex-stale-stop-lease")
    defer { context.cleanup() }
    let sessionId = "stale-stop-lease-session"
    let turnId = "shared-turn"
    let olderPID = Int(Darwin.getpid())
    let deadPID = Int(Int32.max)
    let newerProcess = Process()
    let newerProcessInput = Pipe()
    newerProcess.executableURL = URL(fileURLWithPath: "/bin/cat")
    newerProcess.standardInput = newerProcessInput
    try newerProcess.run()
    defer {
      try? newerProcessInput.fileHandleForWriting.close()
      if newerProcess.isRunning {
        newerProcess.terminate()
      }
      newerProcess.waitUntilExit()
    }
    let newerPID = Int(newerProcess.processIdentifier)
    try H.writeRebindState(
      context: context,
      sessionId: sessionId,
      pid: deadPID
    )
    H.startMockServer(context: context, connectionLimit: 64)

    let newerEnvironment = H.launchEnvironment(context: context, sessionId: sessionId).merging(
      [
        "CMUX_CODEX_PID": String(newerPID)
      ], uniquingKeysWith: { _, new in new })
    let acceptedResume = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: newerEnvironment
    )
    codexExpectFalse(acceptedResume.timedOut, acceptedResume.stderr)
    codexExpectEqual(acceptedResume.status, 0, acceptedResume.stderr)

    let prompt = H.runHook(
      context: context,
      subcommand: "prompt-submit",
      standardInput:
        #"{"session_id":"\#(sessionId)","turn_id":"\#(turnId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
      extraEnvironment: newerEnvironment
    )
    codexExpectFalse(prompt.timedOut, prompt.stderr)
    codexExpectEqual(prompt.status, 0, prompt.stderr)

    let leaseDirectory = context.root.appendingPathComponent(
      "codex-monitor-leases", isDirectory: true)
    let leaseURLs = try FileManager.default.contentsOfDirectory(
      at: leaseDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    let leaseURL = try codexRequire(leaseURLs.first)
    let activeLease = try codexRequire(
      JSONSerialization.jsonObject(with: Data(contentsOf: leaseURL)) as? [String: Any]
    )
    codexExpectEqual(activeLease["sessionId"] as? String, sessionId)
    codexExpectEqual(activeLease["turnId"] as? String, turnId)
    codexExpectNil(activeLease["retiredAt"])

    let staleStop = H.runHook(
      context: context,
      subcommand: "stop",
      standardInput:
        #"{"session_id":"\#(sessionId)","turn_id":"\#(turnId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"late old stop"}"#,
      extraEnvironment: H.launchEnvironment(context: context, sessionId: sessionId).merging(
        [
          "CMUX_CODEX_PID": String(olderPID)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectFalse(staleStop.timedOut, staleStop.stderr)
    codexExpectEqual(staleStop.status, 0, staleStop.stderr)

    let leaseAfterStaleStop = try codexRequire(
      JSONSerialization.jsonObject(with: Data(contentsOf: leaseURL)) as? [String: Any]
    )
    codexExpectNil(
      leaseAfterStaleStop["retiredAt"],
      "A Stop rejected from an older process generation must not retire the newer process's monitor lease."
    )
  }
}
