import { describe, test, expect } from "bun:test";
import { sleepTool } from "../../../src/tools/sleep";
import { configTool } from "../../../src/tools/config_tool";
import { structuredOutputTool } from "../../../src/tools/structured_output";
import { enterPlanModeTool, exitPlanModeTool } from "../../../src/tools/plan_mode";
import type { ToolContext, PermissionLevel, Tool } from "../../../src/core/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeCtx(
  sessionId = "test-session",
  permissionLevel: PermissionLevel = "allow",
  extraTools: Tool[] = [],
): ToolContext & { events: Array<{ kind: string; data: unknown }> } {
  const events: Array<{ kind: string; data: unknown }> = [];
  return {
    cwd: "/tmp/test",
    abortSignal: new AbortController().signal,
    log: () => {},
    permissions: {
      resolve: () => permissionLevel,
      remember: () => {},
      narrow: () => makeCtx(sessionId, permissionLevel, extraTools).permissions,
    },
    session: {
      meta: {
        id: sessionId,
        cwd: "/tmp/test",
        startedAt: "2026-05-11T00:00:00.000Z",
        providerId: "anthropic",
        model: "claude-sonnet-4-6",
      },
      messages: [],
      append: async () => {},
      recordEvent: async (event) => {
        events.push(event);
      },
    },
    spawnSubagent: async () => ({
      text: "",
      usage: { inputTokens: 0, outputTokens: 0 },
      transcriptPath: "",
      ok: false,
    }),
    toolRegistry: {
      get: (name) => extraTools.find((t) => t.name === name),
      list: () => extraTools,
      toSchemas: () => [],
    },
    emitHook: async () => ({ action: "pass" }),
    events,
  };
}

// ---------------------------------------------------------------------------
// sleep
// ---------------------------------------------------------------------------

describe("sleep", () => {
  test("waits approximately the specified duration", async () => {
    const ctx = makeCtx();
    const start = Date.now();
    const result = await (sleepTool.run as Function)({ seconds: 0.1 }, ctx);
    const elapsed = Date.now() - start;

    expect(result.isError).toBeUndefined();
    expect(result.content).toBe("Slept for 0.1 seconds.");
    // Should have waited at least 90ms (allow some slack)
    expect(elapsed).toBeGreaterThanOrEqual(90);
  });

  test("aborts early when signal fires", async () => {
    const controller = new AbortController();
    const ctx = makeCtx();
    // Replace abortSignal with our controller's signal
    (ctx as any).abortSignal = controller.signal;

    // Abort after 50ms
    setTimeout(() => controller.abort(), 50);

    const start = Date.now();
    try {
      await (sleepTool.run as Function)({ seconds: 10 }, ctx);
      // Should not reach here
      expect(true).toBe(false);
    } catch (err: unknown) {
      const elapsed = Date.now() - start;
      expect(elapsed).toBeLessThan(2000);
      expect((err as Error).message).toContain("Aborted");
    }
  });
});

// ---------------------------------------------------------------------------
// config_read
// ---------------------------------------------------------------------------

describe("config_read", () => {
  test("returns expected fields in JSON", async () => {
    const ctx = makeCtx("cfg-session");
    const result = await (configTool.run as Function)({}, ctx);

    expect(result.isError).toBeUndefined();
    const parsed = JSON.parse(result.content as string);

    expect(parsed).toHaveProperty("provider", "anthropic");
    expect(parsed).toHaveProperty("model", "claude-sonnet-4-6");
    expect(parsed).toHaveProperty("cwd", "/tmp/test");
    expect(parsed).toHaveProperty("sessionId", "cfg-session");
    expect(parsed).toHaveProperty("startedAt");
    expect(parsed).toHaveProperty("registeredToolCount");
    expect(parsed).toHaveProperty("cmuxAvailable");
    expect(typeof parsed.registeredToolCount).toBe("number");
    expect(typeof parsed.cmuxAvailable).toBe("boolean");
  });

  test("cmuxAvailable is false when no cmux tools registered", async () => {
    const ctx = makeCtx();
    const result = await (configTool.run as Function)({}, ctx);
    const parsed = JSON.parse(result.content as string);
    expect(parsed.cmuxAvailable).toBe(false);
  });

  test("registeredToolCount reflects tool registry size", async () => {
    const fakeTool: Tool = {
      name: "fake_tool",
      description: "fake",
      inputSchema: {} as any,
      run: async () => ({ content: "" }),
    };
    const ctx = makeCtx("cfg-session-2", "allow", [fakeTool]);
    const result = await (configTool.run as Function)({}, ctx);
    const parsed = JSON.parse(result.content as string);
    expect(parsed.registeredToolCount).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// structured_output
// ---------------------------------------------------------------------------

describe("structured_output", () => {
  test("formats valid data as indented JSON", async () => {
    const ctx = makeCtx();
    const schema = {
      type: "object",
      properties: {
        name: { type: "string" },
        count: { type: "number" },
        active: { type: "boolean" },
      },
      required: ["name"],
    };
    const data = { name: "test", count: 42, active: true };

    const result = await (structuredOutputTool.run as Function)({ schema, data }, ctx);

    expect(result.isError).toBeUndefined();
    const parsed = JSON.parse(result.content as string);
    expect(parsed).toEqual(data);
  });

  test("rejects when required field is missing", async () => {
    const ctx = makeCtx();
    const schema = {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    };
    const data = { other: "field" };

    const result = await (structuredOutputTool.run as Function)({ schema, data }, ctx);
    expect(result.isError).toBe(true);
    expect(result.content).toContain("name");
  });

  test("rejects wrong field type", async () => {
    const ctx = makeCtx();
    const schema = {
      type: "object",
      properties: { count: { type: "number" } },
    };
    const data = { count: "not-a-number" };

    const result = await (structuredOutputTool.run as Function)({ schema, data }, ctx);
    expect(result.isError).toBe(true);
    expect(result.content).toContain("count");
  });

  test("rejects non-object schema type", async () => {
    const ctx = makeCtx();
    const schema = { type: "array" };
    const data = {};

    const result = await (structuredOutputTool.run as Function)({ schema, data }, ctx);
    expect(result.isError).toBe(true);
    expect(result.content).toContain("type");
  });
});

// ---------------------------------------------------------------------------
// enter_plan_mode / exit_plan_mode
// ---------------------------------------------------------------------------

describe("plan_mode", () => {
  test("enter_plan_mode records plan_mode event with on:true", async () => {
    const ctx = makeCtx("plan-session-1");
    const result = await (enterPlanModeTool.run as Function)({ reason: "planning phase" }, ctx);

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("Entered plan mode");
    expect(result.content).toContain("planning phase");

    expect(ctx.events).toHaveLength(1);
    expect(ctx.events[0].kind).toBe("plan_mode");
    expect((ctx.events[0].data as any).on).toBe(true);
    expect((ctx.events[0].data as any).reason).toBe("planning phase");
  });

  test("enter_plan_mode works without reason", async () => {
    const ctx = makeCtx("plan-session-2");
    const result = await (enterPlanModeTool.run as Function)({}, ctx);

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("Entered plan mode");
    expect(ctx.events[0].kind).toBe("plan_mode");
    expect((ctx.events[0].data as any).on).toBe(true);
  });

  test("exit_plan_mode records plan_mode event with on:false", async () => {
    const ctx = makeCtx("plan-session-3");
    const result = await (exitPlanModeTool.run as Function)({}, ctx);

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("Exited plan mode");

    expect(ctx.events).toHaveLength(1);
    expect(ctx.events[0].kind).toBe("plan_mode");
    expect((ctx.events[0].data as any).on).toBe(false);
  });

  test("enter then exit records two events in order", async () => {
    const ctx = makeCtx("plan-session-4");

    await (enterPlanModeTool.run as Function)({ reason: "planning" }, ctx);
    await (exitPlanModeTool.run as Function)({}, ctx);

    expect(ctx.events).toHaveLength(2);
    expect((ctx.events[0].data as any).on).toBe(true);
    expect((ctx.events[1].data as any).on).toBe(false);
  });
});
