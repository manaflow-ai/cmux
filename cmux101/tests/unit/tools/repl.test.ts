import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { replTool, clearReplSessions } from "../../../src/tools/repl";
import type { ToolContext, PermissionLevel } from "../../../src/core/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

let sessionCounter = 0;

function makeCtx(
  sessionId: string = `test-session-${++sessionCounter}`,
  permissionLevel: PermissionLevel = "allow",
  abortController?: AbortController
): ToolContext {
  const cwd = process.cwd();
  return {
    cwd,
    abortSignal: abortController?.signal ?? new AbortController().signal,
    log: (_level, _text) => {},
    permissions: {
      resolve: (_toolName: string, _input: unknown) => permissionLevel,
      remember: () => {},
      narrow: (_allowedTools: string[]) => makeCtx(sessionId, permissionLevel).permissions,
    },
    session: {
      meta: {
        id: sessionId,
        cwd,
        startedAt: new Date().toISOString(),
        providerId: "test",
        model: "test",
      },
      messages: [],
      append: async () => {},
      recordEvent: async () => {},
    },
    spawnSubagent: async () => ({
      text: "",
      usage: { inputTokens: 0, outputTokens: 0 },
      transcriptPath: "",
      ok: false,
    }),
    toolRegistry: {
      get: () => undefined,
      list: () => [],
      toSchemas: () => [],
    },
    emitHook: async () => ({ action: "pass" }),
  };
}

const hasPython = await Bun.which("python3") !== null;

beforeEach(() => {
  clearReplSessions();
});

afterEach(() => {
  clearReplSessions();
});

// ---------------------------------------------------------------------------
// Python tests (skipped if python3 not available)
// ---------------------------------------------------------------------------

describe("repl — python", () => {
  test("evaluates a simple expression", async () => {
    if (!hasPython) {
      console.log("Skipping: python3 not available");
      return;
    }

    const ctx = makeCtx("python-session-1");
    const result = await (replTool.run as Function)(
      { language: "python", code: "print(1 + 1)" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("2");
  });

  test("shares state across calls in the same session", async () => {
    if (!hasPython) {
      console.log("Skipping: python3 not available");
      return;
    }

    const ctx = makeCtx("python-session-2");

    // Define variable
    const r1 = await (replTool.run as Function)(
      { language: "python", code: "x = 42" },
      ctx
    );
    expect(r1.isError).toBeUndefined();

    // Use it in subsequent call
    const r2 = await (replTool.run as Function)(
      { language: "python", code: "print(x)" },
      ctx
    );
    expect(r2.isError).toBeUndefined();
    expect(r2.content).toContain("42");
  });

  test("does NOT share state across different sessions", async () => {
    if (!hasPython) {
      console.log("Skipping: python3 not available");
      return;
    }

    const ctx1 = makeCtx("session-A");
    const ctx2 = makeCtx("session-B");

    await (replTool.run as Function)(
      { language: "python", code: "secret = 999" },
      ctx1
    );

    // session-B should not have 'secret'
    const r = await (replTool.run as Function)(
      { language: "python", code: "print('secret' in dir())" },
      ctx2
    );
    expect(r.content).toContain("False");
  });

  test("abort kills the subprocess", async () => {
    if (!hasPython) {
      console.log("Skipping: python3 not available");
      return;
    }

    const ac = new AbortController();
    const ctx = makeCtx("abort-session", "allow", ac);

    // Abort immediately before the call
    ac.abort();

    const result = await (replTool.run as Function)(
      { language: "python", code: "print('should not run')" },
      ctx
    );

    expect(result.isError).toBe(true);
    expect(result.content).toContain("Aborted");
  });
});

// ---------------------------------------------------------------------------
// Node tests
// ---------------------------------------------------------------------------

describe("repl — node", () => {
  test("evaluates a simple expression", async () => {
    const ctx = makeCtx("node-session-1");
    const result = await (replTool.run as Function)(
      { language: "node", code: "console.log(1 + 1)" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("2");
  });

  test("shares state across calls", async () => {
    const ctx = makeCtx("node-session-2");

    await (replTool.run as Function)(
      { language: "node", code: "var y = 77" },
      ctx
    );

    const r2 = await (replTool.run as Function)(
      { language: "node", code: "console.log(y)" },
      ctx
    );

    expect(r2.isError).toBeUndefined();
    expect(r2.content).toContain("77");
  });
});
