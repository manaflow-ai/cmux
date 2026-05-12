/**
 * Unit tests for runner permission handling.
 *
 * Tests the "ask" flow: no askUser -> deny, askUser returning
 * "yes"/"no"/"yes-session"/"yes-always" and the side-effects.
 */

import { describe, it, expect, mock } from "bun:test";
import { Runner } from "../../../src/core/runner.js";
import { createPermissionResolver } from "../../../src/core/permissions.js";
import type {
  Provider,
  SessionHandle,
  ToolRegistry,
  Tool,
  ToolResult,
  ToolContext,
  PermissionLevel,
  StreamEvent,
  Message,
} from "../../../src/core/types.js";
import { z } from "zod";

// ---------------------------------------------------------------------------
// Minimal stubs
// ---------------------------------------------------------------------------

/** Fake provider: turn 1 emits a tool call; turn 2 ends cleanly. */
function makeProvider(toolName: string, toolInput: unknown = {}): Provider {
  let callCount = 0;
  return {
    id: "fake",
    displayName: "Fake",
    listModels: async () => [],
    stream() {
      callCount++;
      const turn = callCount;
      return (async function* () {
        if (turn === 1) {
          const id = "tool-1";
          yield { kind: "message_start", messageId: "msg-1" } as StreamEvent;
          yield { kind: "tool_call_start", id, name: toolName } as StreamEvent;
          yield { kind: "tool_call_end", id, input: toolInput } as StreamEvent;
          yield { kind: "message_stop", reason: "tool_use" } as StreamEvent;
        } else {
          yield { kind: "message_start", messageId: "msg-2" } as StreamEvent;
          yield { kind: "message_stop", reason: "end_turn" } as StreamEvent;
        }
      })();
    },
  };
}

/** Fake session that accumulates messages. */
function makeSession(): SessionHandle & { messages: Message[] } {
  const messages: Message[] = [];
  return {
    meta: {
      id: "test-session",
      cwd: "/tmp",
      startedAt: new Date().toISOString(),
      providerId: "fake",
      model: "fake-model",
    },
    get messages() { return messages; },
    async append(msg: Message) { messages.push(msg); },
    async recordEvent() {},
  };
}

/** Create a simple tool that records calls and returns a fixed result. */
function makeTool(name: string, result: ToolResult = { content: "ok", isError: false }): Tool & { callCount: number } {
  const obj = {
    name,
    description: "test tool",
    inputSchema: z.object({}).passthrough(),
    callCount: 0,
    async run(_input: unknown, _ctx: ToolContext): Promise<ToolResult> {
      obj.callCount++;
      return result;
    },
    defaultPermission: "ask" as PermissionLevel,
  };
  return obj;
}

/** Create a tool registry with a single tool. */
function makeRegistry(tool: Tool): ToolRegistry {
  return {
    get: (n: string) => (n === tool.name ? tool : undefined),
    list: () => [tool],
    toSchemas: () => [{ name: tool.name, description: tool.description, inputSchema: {} }],
  };
}

// ---------------------------------------------------------------------------
// Helper: run and collect tool results from session messages
// ---------------------------------------------------------------------------

async function runAndGetToolResults(
  runner: Runner,
  session: ReturnType<typeof makeSession>,
): Promise<Array<{ is_error?: boolean; content: string }>> {
  await runner.run("test");
  // Tool results are in tool-role messages
  const results: Array<{ is_error?: boolean; content: string }> = [];
  for (const msg of session.messages) {
    if (msg.role === "tool") {
      for (const block of msg.content) {
        if (block.type === "tool_result") {
          results.push({
            is_error: block.is_error,
            content: typeof block.content === "string" ? block.content : JSON.stringify(block.content),
          });
        }
      }
    }
  }
  return results;
}

// ---------------------------------------------------------------------------
// Tests: no askUser
// ---------------------------------------------------------------------------

describe("Runner – no askUser, tool resolves to 'ask'", () => {
  it("denies the tool and sets is_error", async () => {
    const tool = makeTool("shell");
    const registry = makeRegistry(tool);
    const session = makeSession();

    const permissions = createPermissionResolver({
      // No explicit allow/deny — tool defaults to "ask", fallback is "ask"
      askUser: async () => "ask", // won't be called from runner
    });

    const runner = new Runner({
      session,
      provider: makeProvider("shell"),
      toolRegistry: registry,
      permissions,
      cwd: "/tmp",
      // No askUser provided
    });

    const results = await runAndGetToolResults(runner, session);
    expect(results.length).toBeGreaterThan(0);
    expect(results[0]!.is_error).toBe(true);
    expect(results[0]!.content).toContain("denied");
    // Tool should not have run
    expect(tool.callCount).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Tests: askUser returning "yes"
// ---------------------------------------------------------------------------

describe("Runner – askUser returning 'yes'", () => {
  it("allows the tool to run once", async () => {
    const tool = makeTool("shell");
    const registry = makeRegistry(tool);
    const session = makeSession();

    const permissions = createPermissionResolver({
      askUser: async () => "ask",
    });

    const askUser = mock(async (_toolName: string, _input: unknown) => "yes" as const);

    const runner = new Runner({
      session,
      provider: makeProvider("shell"),
      toolRegistry: registry,
      permissions,
      cwd: "/tmp",
      askUser,
    });

    const results = await runAndGetToolResults(runner, session);
    expect(askUser).toHaveBeenCalledTimes(1);
    expect(askUser.mock.calls[0]![0]).toBe("shell");
    expect(results[0]!.is_error).toBeFalsy();
    expect(tool.callCount).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// Tests: askUser returning "no"
// ---------------------------------------------------------------------------

describe("Runner – askUser returning 'no'", () => {
  it("denies the tool with is_error", async () => {
    const tool = makeTool("shell");
    const registry = makeRegistry(tool);
    const session = makeSession();

    const permissions = createPermissionResolver({
      askUser: async () => "ask",
    });

    const askUser = mock(async () => "no" as const);

    const runner = new Runner({
      session,
      provider: makeProvider("shell"),
      toolRegistry: registry,
      permissions,
      cwd: "/tmp",
      askUser,
    });

    const results = await runAndGetToolResults(runner, session);
    expect(results[0]!.is_error).toBe(true);
    expect(tool.callCount).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Tests: askUser returning "yes-always" -> permissions.remember called
// ---------------------------------------------------------------------------

describe("Runner – askUser returning 'yes-always'", () => {
  it("calls permissions.remember with 'project' scope and allows the tool", async () => {
    const tool = makeTool("shell");
    const registry = makeRegistry(tool);
    const session = makeSession();

    const permissions = createPermissionResolver({
      askUser: async () => "ask",
    });

    // Spy on remember
    const rememberCalls: Array<[string, PermissionLevel, string | undefined]> = [];
    const origRemember = permissions.remember.bind(permissions);
    permissions.remember = (toolName, level, scope) => {
      rememberCalls.push([toolName, level, scope]);
      origRemember(toolName, level, scope);
    };

    const askUser = mock(async () => "yes-always" as const);

    const runner = new Runner({
      session,
      provider: makeProvider("shell"),
      toolRegistry: registry,
      permissions,
      cwd: "/tmp",
      askUser,
    });

    const results = await runAndGetToolResults(runner, session);

    // Tool should have run
    expect(tool.callCount).toBe(1);
    expect(results[0]!.is_error).toBeFalsy();

    // remember should have been called with project scope
    expect(rememberCalls.length).toBeGreaterThan(0);
    const rememberCall = rememberCalls.find(([name]) => name === "shell");
    expect(rememberCall).toBeDefined();
    expect(rememberCall![1]).toBe("allow");
    expect(rememberCall![2]).toBe("project");
  });
});

// ---------------------------------------------------------------------------
// Tests: askUser returning "yes-session"
// ---------------------------------------------------------------------------

describe("Runner – askUser returning 'yes-session'", () => {
  it("calls permissions.remember with 'session' scope and allows the tool", async () => {
    const tool = makeTool("shell");
    const registry = makeRegistry(tool);
    const session = makeSession();

    const permissions = createPermissionResolver({
      askUser: async () => "ask",
    });

    const rememberCalls: Array<[string, PermissionLevel, string | undefined]> = [];
    const origRemember = permissions.remember.bind(permissions);
    permissions.remember = (toolName, level, scope) => {
      rememberCalls.push([toolName, level, scope]);
      origRemember(toolName, level, scope);
    };

    const askUser = mock(async () => "yes-session" as const);

    const runner = new Runner({
      session,
      provider: makeProvider("shell"),
      toolRegistry: registry,
      permissions,
      cwd: "/tmp",
      askUser,
    });

    const results = await runAndGetToolResults(runner, session);

    expect(tool.callCount).toBe(1);
    expect(results[0]!.is_error).toBeFalsy();

    const rememberCall = rememberCalls.find(([name]) => name === "shell");
    expect(rememberCall).toBeDefined();
    expect(rememberCall![1]).toBe("allow");
    expect(rememberCall![2]).toBe("session");
  });
});
