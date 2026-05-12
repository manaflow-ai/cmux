import { describe, test, expect, beforeEach } from "bun:test";
import { todoWriteTool, todoListTool, todoUpdateTool } from "../../../src/tools/todos";
import type { ToolContext, PermissionLevel } from "../../../src/core/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeCtx(sessionId: string, permissionLevel: PermissionLevel = "allow"): ToolContext {
  return {
    cwd: "/tmp",
    abortSignal: new AbortController().signal,
    log: () => {},
    permissions: {
      resolve: () => permissionLevel,
      remember: () => {},
      narrow: () => makeCtx(sessionId, permissionLevel).permissions,
    },
    session: {
      meta: {
        id: sessionId,
        cwd: "/tmp",
        startedAt: new Date().toISOString(),
        providerId: "test",
        model: "test-model",
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("todo_write", () => {
  test("replaces the current session list", async () => {
    const ctx = makeCtx("session-write-1");

    // Write initial list
    const result1 = await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Task A" }, { subject: "Task B", description: "Do B" }] },
      ctx,
    );
    expect(result1.isError).toBeUndefined();
    expect(result1.content).toContain("Task A");
    expect(result1.content).toContain("Task B");

    // Replace with a new list
    const result2 = await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Task C" }] },
      ctx,
    );
    expect(result2.content).toContain("Task C");
    expect(result2.content).not.toContain("Task A");
    expect(result2.content).not.toContain("Task B");
  });

  test("new todos start as pending", async () => {
    const ctx = makeCtx("session-write-2");
    const result = await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Pending task" }] },
      ctx,
    );
    // Pending badge is [ ]
    expect(result.content).toContain("[ ]");
  });

  test("assigns sequential ids starting at 1", async () => {
    const ctx = makeCtx("session-write-3");
    const result = await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Alpha" }, { subject: "Beta" }] },
      ctx,
    );
    expect(result.content).toContain("[1]");
    expect(result.content).toContain("[2]");
  });
});

describe("todo_list", () => {
  test("returns current list after write", async () => {
    const ctx = makeCtx("session-list-1");

    await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Listed item" }] },
      ctx,
    );

    const result = await (todoListTool.run as Function)({}, ctx);
    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("Listed item");
  });

  test("returns placeholder when list is empty", async () => {
    const ctx = makeCtx("session-list-empty");
    const result = await (todoListTool.run as Function)({}, ctx);
    expect(result.content).toContain("no todos");
  });
});

describe("todo_update", () => {
  test("updates status of a todo", async () => {
    const ctx = makeCtx("session-update-1");
    await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Update me" }] },
      ctx,
    );

    const result = await (todoUpdateTool.run as Function)(
      { id: "1", status: "in_progress" },
      ctx,
    );
    expect(result.isError).toBeUndefined();
    // in_progress badge is [~]
    expect(result.content).toContain("[~]");
  });

  test("updates subject of a todo", async () => {
    const ctx = makeCtx("session-update-2");
    await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Old subject" }] },
      ctx,
    );

    const result = await (todoUpdateTool.run as Function)(
      { id: "1", subject: "New subject" },
      ctx,
    );
    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("New subject");
    expect(result.content).not.toContain("Old subject");
  });

  test("returns error for unknown id", async () => {
    const ctx = makeCtx("session-update-3");
    await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Only item" }] },
      ctx,
    );

    const result = await (todoUpdateTool.run as Function)(
      { id: "999", status: "completed" },
      ctx,
    );
    expect(result.isError).toBe(true);
    expect(result.content).toContain("999");
  });

  test("marks todo as completed", async () => {
    const ctx = makeCtx("session-update-complete");
    await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Finish me" }] },
      ctx,
    );

    const result = await (todoUpdateTool.run as Function)(
      { id: "1", status: "completed" },
      ctx,
    );
    // completed badge is [x]
    expect(result.content).toContain("[x]");
  });
});

describe("session isolation", () => {
  test("two sessions have separate todo lists", async () => {
    const ctxA = makeCtx("session-iso-A");
    const ctxB = makeCtx("session-iso-B");

    await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Session A task" }] },
      ctxA,
    );

    await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Session B task" }] },
      ctxB,
    );

    const listA = await (todoListTool.run as Function)({}, ctxA);
    const listB = await (todoListTool.run as Function)({}, ctxB);

    expect(listA.content).toContain("Session A task");
    expect(listA.content).not.toContain("Session B task");

    expect(listB.content).toContain("Session B task");
    expect(listB.content).not.toContain("Session A task");
  });

  test("writing to one session does not affect another", async () => {
    const ctxA = makeCtx("session-iso-C");
    const ctxB = makeCtx("session-iso-D");

    await (todoWriteTool.run as Function)(
      { todos: [{ subject: "Item for C" }] },
      ctxA,
    );

    // Session D should still be empty
    const listB = await (todoListTool.run as Function)({}, ctxB);
    expect(listB.content).toContain("no todos");
  });
});
