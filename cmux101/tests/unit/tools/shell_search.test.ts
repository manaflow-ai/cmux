/**
 * Unit tests for shell, glob, and grep tools.
 */

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { mkdtemp, writeFile, mkdir, rm } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";
import type { ToolContext, ToolEvent, ToolResult, SessionHandle, SessionMeta, Permissions } from "../../../src/core/types";
import { shellTool } from "../../../src/tools/shell";
import { globTool } from "../../../src/tools/glob";
import { grepTool } from "../../../src/tools/grep";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeCtx(overrides: Partial<ToolContext> = {}): ToolContext {
  const abortController = new AbortController();

  const sessionMeta: SessionMeta = {
    id: "test-session",
    cwd: process.cwd(),
    startedAt: new Date().toISOString(),
    providerId: "test",
    model: "test-model",
  };

  const session: SessionHandle = {
    meta: sessionMeta,
    messages: [],
    append: async () => {},
    recordEvent: async () => {},
  };

  const permissions: Permissions = {
    resolve: () => "allow",
    remember: () => {},
    narrow: function(allowedTools: string[]) { return this; },
  };

  return {
    session,
    permissions,
    abortSignal: abortController.signal,
    cwd: process.cwd(),
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
    log: () => {},
    ...overrides,
  };
}

/** Collect all ToolEvents from an AsyncIterable and return final result */
async function collectToolEvents(
  iterable: AsyncIterable<ToolEvent>,
): Promise<{ events: ToolEvent[]; result: ToolResult }> {
  const events: ToolEvent[] = [];
  let result: ToolResult | undefined;

  for await (const event of iterable) {
    events.push(event);
    if (event.kind === "result") {
      result = event.result;
    }
  }

  if (!result) throw new Error("No result event yielded");
  return { events, result };
}

// ---------------------------------------------------------------------------
// shell tests
// ---------------------------------------------------------------------------

describe("shellTool", () => {
  test("echo hello returns exit 0 and output", async () => {
    const ctx = makeCtx();
    const raw = shellTool.run({ command: "echo hello" }, ctx);
    // shell returns AsyncIterable
    const { result } = await collectToolEvents(raw as AsyncIterable<ToolEvent>);

    expect(result.isError).toBeFalsy();
    expect(result.content).toContain("hello");
    expect(result.content).toContain("Exit code: 0");
  });

  test("non-zero exit marks isError", async () => {
    const ctx = makeCtx();
    const raw = shellTool.run({ command: "exit 42" }, ctx);
    const { result } = await collectToolEvents(raw as AsyncIterable<ToolEvent>);

    expect(result.isError).toBe(true);
    expect(result.content).toContain("Exit code: 42");
  });

  test("timeout kills process and returns error", async () => {
    const ctx = makeCtx();
    const raw = shellTool.run(
      { command: "sleep 60", timeout_ms: 200 },
      ctx,
    );
    const { result } = await collectToolEvents(raw as AsyncIterable<ToolEvent>);

    expect(result.isError).toBe(true);
    expect(result.content).toContain("timed out");
  });

  test("abort signal kills process", async () => {
    const abortController = new AbortController();
    const ctx = makeCtx({ abortSignal: abortController.signal });

    const raw = shellTool.run({ command: "sleep 60" }, ctx) as AsyncIterable<ToolEvent>;

    // Abort after a short delay
    setTimeout(() => abortController.abort(), 100);

    const { result } = await collectToolEvents(raw);
    expect(result.isError).toBe(true);
    expect(result.content).toContain("aborted");
  });

  test("stdout and stderr are captured", async () => {
    const ctx = makeCtx();
    const raw = shellTool.run(
      { command: 'echo "OUT" && echo "ERR" >&2' },
      ctx,
    );
    const { result } = await collectToolEvents(raw as AsyncIterable<ToolEvent>);

    expect(result.content).toContain("OUT");
    expect(result.content).toContain("ERR");
  });
});

// ---------------------------------------------------------------------------
// glob tests
// ---------------------------------------------------------------------------

let tmpDir: string;

beforeAll(async () => {
  tmpDir = await mkdtemp(join(tmpdir(), "cmux-glob-test-"));

  // Create test file tree
  await mkdir(join(tmpDir, "src"), { recursive: true });
  await mkdir(join(tmpDir, "src", "nested"), { recursive: true });
  await mkdir(join(tmpDir, "node_modules", "pkg"), { recursive: true });

  await writeFile(join(tmpDir, "index.ts"), "export {};");
  await writeFile(join(tmpDir, "src", "foo.ts"), "export const foo = 1;");
  await writeFile(join(tmpDir, "src", "bar.ts"), "export const bar = 2;");
  await writeFile(join(tmpDir, "src", "nested", "deep.ts"), "export const deep = 3;");
  await writeFile(join(tmpDir, "node_modules", "pkg", "index.js"), "module.exports = {};");
});

afterAll(async () => {
  if (tmpDir) await rm(tmpDir, { recursive: true, force: true });
});

describe("globTool", () => {
  test("matches *.ts files and excludes node_modules", async () => {
    const ctx = makeCtx({ cwd: tmpDir });
    const result = await globTool.run({ pattern: "**/*.ts" }, ctx) as ToolResult;

    expect(result.content).toContain("index.ts");
    expect(result.content).toContain("src/foo.ts");
    expect(result.content).toContain("src/bar.ts");
    expect(result.content).toContain("src/nested/deep.ts");
    expect(result.content).not.toContain("node_modules");
  });

  test("header shows correct count", async () => {
    const ctx = makeCtx({ cwd: tmpDir });
    const result = await globTool.run({ pattern: "src/*.ts" }, ctx) as ToolResult;

    expect(result.content).toContain("Found 2 matches:");
  });

  test("uses provided cwd override", async () => {
    const ctx = makeCtx({ cwd: "/" });
    const result = await globTool.run({ pattern: "*.ts", cwd: tmpDir }, ctx) as ToolResult;

    expect(result.content).toContain("index.ts");
  });

  test("no matches returns Found 0 matches header", async () => {
    const ctx = makeCtx({ cwd: tmpDir });
    const result = await globTool.run({ pattern: "**/*.nonexistent" }, ctx) as ToolResult;

    expect(result.content).toContain("Found 0 matches");
  });
});

// ---------------------------------------------------------------------------
// grep tests
// ---------------------------------------------------------------------------

describe("grepTool", () => {
  test("finds pattern in files", async () => {
    const ctx = makeCtx({ cwd: tmpDir });
    const result = await grepTool.run(
      { pattern: "export const", path: "src" },
      ctx,
    ) as ToolResult;

    expect(result.content).toContain("foo");
    expect(result.content).toContain("bar");
  });

  test("case insensitive search", async () => {
    const ctx = makeCtx({ cwd: tmpDir });
    const result = await grepTool.run(
      { pattern: "EXPORT", path: "src", case_insensitive: true },
      ctx,
    ) as ToolResult;

    expect(result.content).not.toBe("No matches found.");
    expect(result.content).toContain("export");
  });

  test("no match returns no matches message", async () => {
    const ctx = makeCtx({ cwd: tmpDir });
    const result = await grepTool.run(
      { pattern: "zzz_definitely_not_there_zzz" },
      ctx,
    ) as ToolResult;

    expect(result.content).toBe("No matches found.");
  });

  test("output format is file:line:content", async () => {
    const ctx = makeCtx({ cwd: tmpDir });
    const result = await grepTool.run(
      { pattern: "export \\{\\}", path: "index.ts" },
      ctx,
    ) as ToolResult;

    if (result.content !== "No matches found.") {
      // Each line should match file:line:content format
      const lines = (result.content as string).split("\n").filter(Boolean);
      for (const line of lines) {
        expect(line).toMatch(/^[^:]+:\d+:.*/);
      }
    }
  });
});
