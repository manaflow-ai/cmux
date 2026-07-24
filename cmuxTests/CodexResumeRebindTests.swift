import Darwin
import Foundation
import Testing

@Suite("Codex resume rebinding", .serialized)
struct CodexResumeRebindTests {
  private typealias H = CodexResumeTestHarness

  @Test
  func testCodexSessionEndAcceptsRecordedLeaseAfterProcessExit() throws {
    let context = try H.makeContext(name: "codex-dead-session-end")
    defer { context.cleanup() }
    let sessionId = "dead-owner-session-end"
    let processLeaseId = UUID().uuidString
    let codexProcess = Process()
    let codexInput = Pipe()
    codexProcess.executableURL = URL(fileURLWithPath: "/bin/cat")
    codexProcess.standardInput = codexInput
    try codexProcess.run()
    let codexPID = Int(codexProcess.processIdentifier)
    let launchEnvironment = H.launchEnvironment(
      context: context,
      sessionId: sessionId
    ).merging(
      [
        "CMUX_CODEX_PID": String(codexPID),
        "CMUX_CODEX_PROCESS_LEASE_ID": processLeaseId,
      ], uniquingKeysWith: { _, new in new })
    H.startMockServer(context: context, connectionLimit: 48)

    let start = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(start.timedOut, start.stderr)
    codexExpectEqual(start.status, 0, start.stderr)
    codexExpectEqual(
      try H.readSession(sessionId, context: context)["pid"] as? Int,
      codexPID
    )

    try codexInput.fileHandleForWriting.close()
    codexProcess.waitUntilExit()
    codexExpectFalse(codexProcess.isRunning)

    let teardownCommandStart = context.state.commands.count
    let sessionEnd = H.runHook(
      context: context,
      subcommand: "session-end",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(sessionEnd.timedOut, sessionEnd.stderr)
    codexExpectEqual(sessionEnd.status, 0, sessionEnd.stderr)

    let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
    let state = try codexRequire(
      JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
    )
    let sessions = try codexRequire(state["sessions"] as? [String: Any])
    codexExpectNil(
      sessions[sessionId],
      "The recorded owner lease must authorize its delayed final teardown after the Codex process exits."
    )
    codexExpectTrue(
      context.state.commands.dropFirst(teardownCommandStart).contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.clear"
      },
      "The delayed final teardown must clear the persisted resume binding."
    )
  }

  @Test
  func testDelayedSameGenerationCodexResumeCannotClearActiveTurn() throws {
    let context = try H.makeContext(name: "codex-same-generation-active")
    defer { context.cleanup() }
    let sessionId = "same-generation-active"
    let pid = Int(Darwin.getpid())
    let launchEnvironment = H.launchEnvironment(context: context, sessionId: sessionId).merging(
      [
        "CMUX_CODEX_PID": String(pid)
      ], uniquingKeysWith: { _, new in new })
    H.startMockServer(context: context, connectionLimit: 64)

    let initialStart = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(initialStart.timedOut, initialStart.stderr)
    codexExpectEqual(initialStart.status, 0, initialStart.stderr)

    let idempotentStart = context.state.commands.count
    let idempotentResume = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(idempotentResume.timedOut, idempotentResume.stderr)
    codexExpectEqual(idempotentResume.status, 0, idempotentResume.stderr)
    codexExpectTrue(
      context.state.commands.dropFirst(idempotentStart).contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "A repeated same-generation rebind remains idempotent before turn events."
    )

    let prompt = H.runHook(
      context: context,
      subcommand: "prompt-submit",
      standardInput:
        #"{"session_id":"\#(sessionId)","turn_id":"active-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(prompt.timedOut, prompt.stderr)
    codexExpectEqual(prompt.status, 0, prompt.stderr)

    let delayedStart = context.state.commands.count
    let delayedResume = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(delayedResume.timedOut, delayedResume.stderr)
    codexExpectEqual(delayedResume.status, 0, delayedResume.stderr)
    let record = try H.readSession(sessionId, context: context)
    codexExpectEqual(record["activePromptDepth"] as? Int, 1)
    codexExpectEqual(record["activePromptTurnId"] as? String, "active-turn")
    codexExpectEqual(record["activePromptTurnIds"] as? [String], ["active-turn"])
    codexExpectEqual(record["lastPromptTurnId"] as? String, "active-turn")
    codexExpectEqual(record["workspaceId"] as? String, context.workspaceId)
    codexExpectEqual(record["surfaceId"] as? String, context.surfaceId)
    codexExpectFalse(
      context.state.commands.dropFirst(delayedStart).contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "A delayed same-generation SessionStart must not erase a newer active turn."
    )
  }

  @Test
  func testDelayedSameGenerationCodexResumeCannotResurrectCompletedTurn() throws {
    let context = try H.makeContext(name: "codex-same-generation-complete")
    defer { context.cleanup() }
    let sessionId = "same-generation-complete"
    let pid = Int(Darwin.getpid())
    let launchEnvironment = H.launchEnvironment(context: context, sessionId: sessionId).merging(
      [
        "CMUX_CODEX_PID": String(pid)
      ], uniquingKeysWith: { _, new in new })
    H.startMockServer(context: context, connectionLimit: 64)

    let initialStart = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(initialStart.timedOut, initialStart.stderr)
    codexExpectEqual(initialStart.status, 0, initialStart.stderr)

    let prompt = H.runHook(
      context: context,
      subcommand: "prompt-submit",
      standardInput:
        #"{"session_id":"\#(sessionId)","turn_id":"completed-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"finish"}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(prompt.timedOut, prompt.stderr)
    codexExpectEqual(prompt.status, 0, prompt.stderr)

    let stop = H.runHook(
      context: context,
      subcommand: "stop",
      standardInput:
        #"{"session_id":"\#(sessionId)","turn_id":"completed-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"done"}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(stop.timedOut, stop.stderr)
    codexExpectEqual(stop.status, 0, stop.stderr)
    let completedRecord = try H.readSession(sessionId, context: context)

    let delayedStart = context.state.commands.count
    let delayedResume = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: launchEnvironment
    )
    codexExpectFalse(delayedResume.timedOut, delayedResume.stderr)
    codexExpectEqual(delayedResume.status, 0, delayedResume.stderr)
    let record = try H.readSession(sessionId, context: context)
    codexExpectNil(record["activePromptDepth"])
    codexExpectEqual(record["lastPromptTurnId"] as? String, "completed-turn")
    codexExpectTrue(
      (record["terminalPromptTurnIds"] as? [String])?.contains("completed-turn") == true)
    codexExpectEqual(record["lastSubtitle"] as? String, completedRecord["lastSubtitle"] as? String)
    codexExpectEqual(record["lastBody"] as? String, completedRecord["lastBody"] as? String)
    codexExpectEqual(
      record["runtimeStatus"] as? String, completedRecord["runtimeStatus"] as? String)
    codexExpectEqual(record["workspaceId"] as? String, context.workspaceId)
    codexExpectEqual(record["surfaceId"] as? String, context.surfaceId)
    codexExpectFalse(
      context.state.commands.dropFirst(delayedStart).contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "A delayed same-generation SessionStart must not resurrect a completed turn."
    )
  }

  @Test
  func testCodexResumeRebindAcceptsDeadPreviousPIDWhenGenerationWasDropped() throws {
    let context = try H.makeContext(name: "codex-missing-generation")
    defer { context.cleanup() }
    let sessionId = "missing-generation-dead-process"
    let incomingPID = Int(Darwin.getpid())
    let deadPID = Int(Int32.max)
    try H.writeRebindState(
      context: context,
      sessionId: sessionId,
      pid: deadPID
    )
    H.startMockServer(context: context, connectionLimit: 24)

    let resume = H.runHook(
      context: context,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: H.launchEnvironment(context: context, sessionId: sessionId).merging(
        [
          "CMUX_CODEX_PID": String(incomingPID)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectFalse(resume.timedOut, resume.stderr)
    codexExpectEqual(resume.status, 0, resume.stderr)
    let record = try H.readSession(sessionId, context: context)
    codexExpectEqual(record["pid"] as? Int, incomingPID)
    codexExpectNil(record["activePromptDepth"])
    codexExpectTrue(
      context.state.commands.contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "A live resume must recover when an older CLI dropped process-generation fields and the previous PID is dead."
    )
  }

  @Test
  func testCodexResumeRebindRejectsLiveOrUnknownPreviousProcessWithoutGeneration() throws {
    let liveContext = try H.makeContext(name: "codex-live-generation")
    let missingContext = try H.makeContext(name: "codex-no-generation")
    defer {
      liveContext.cleanup()
      missingContext.cleanup()
    }
    let liveSessionId = "missing-generation-live-process"
    let missingPIDSessionId = "missing-generation-missing-process"
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    defer {
      if sleeper.isRunning {
        sleeper.terminate()
      }
      sleeper.waitUntilExit()
    }

    try H.writeRebindState(
      context: liveContext,
      sessionId: liveSessionId,
      pid: Int(Darwin.getpid())
    )
    try H.writeRebindState(
      context: missingContext,
      sessionId: missingPIDSessionId,
      pid: nil
    )
    H.startMockServer(context: liveContext, connectionLimit: 24)
    H.startMockServer(context: missingContext, connectionLimit: 24)

    let liveResume = H.runHook(
      context: liveContext,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(liveSessionId)","cwd":"\#(liveContext.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: H.launchEnvironment(context: liveContext, sessionId: liveSessionId).merging(
        [
          "CMUX_CODEX_PID": String(sleeper.processIdentifier)
        ], uniquingKeysWith: { _, new in new })
    )
    codexExpectFalse(liveResume.timedOut, liveResume.stderr)
    codexExpectEqual(liveResume.status, 0, liveResume.stderr)
    let liveRecord = try H.readSession(liveSessionId, context: liveContext)
    codexExpectEqual(liveRecord["pid"] as? Int, Int(Darwin.getpid()))
    codexExpectEqual(liveRecord["activePromptDepth"] as? Int, 1)
    codexExpectFalse(
      liveContext.state.commands.contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "A missing generation must not replace a different PID that is still live."
    )

    let missingResume = H.runHook(
      context: missingContext,
      subcommand: "session-start",
      standardInput:
        #"{"session_id":"\#(missingPIDSessionId)","cwd":"\#(missingContext.root.path)","hook_event_name":"SessionStart","cmux_resume_rebind":true}"#,
      extraEnvironment: H.launchEnvironment(context: missingContext, sessionId: missingPIDSessionId)
        .merging(
          [
            "CMUX_CODEX_PID": String(sleeper.processIdentifier)
          ], uniquingKeysWith: { _, new in new })
    )
    codexExpectFalse(missingResume.timedOut, missingResume.stderr)
    codexExpectEqual(missingResume.status, 0, missingResume.stderr)
    let missingRecord = try H.readSession(missingPIDSessionId, context: missingContext)
    codexExpectNil(missingRecord["pid"])
    codexExpectEqual(missingRecord["activePromptDepth"] as? Int, 1)
    codexExpectFalse(
      missingContext.state.commands.contains {
        H.jsonObject($0)?["method"] as? String == "surface.resume.set"
      },
      "A missing previous PID cannot prove that an interrupted owner exited."
    )
  }
}
