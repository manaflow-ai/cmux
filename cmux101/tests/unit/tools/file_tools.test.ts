import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import { fileReadTool } from "../../../src/tools/file_read";
import { fileWriteTool } from "../../../src/tools/file_write";
import { fileEditTool } from "../../../src/tools/file_edit";
import type { ToolContext, PermissionLevel } from "../../../src/core/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeCtx(cwd: string, permissionLevel: PermissionLevel = "allow"): ToolContext {
  return {
    cwd,
    abortSignal: new AbortController().signal,
    log: (_level, _text) => {},
    permissions: {
      resolve: (_toolName: string, _input: unknown) => permissionLevel,
      remember: () => {},
      narrow: (allowedTools: string[]) => makeCtx(cwd, permissionLevel).permissions,
    },
    session: {
      meta: {
        id: "test",
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

let tmpDir: string;

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "cmux101-test-"));
});

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// file_read
// ---------------------------------------------------------------------------

describe("file_read", () => {
  test("reads an existing file with line numbers", async () => {
    const filePath = path.join(tmpDir, "hello.txt");
    await Bun.write(filePath, "line one\nline two\nline three\n");

    const ctx = makeCtx(tmpDir);
    const result = await (fileReadTool.run as Function)({ path: filePath }, ctx);

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("line one");
    expect(result.content).toContain("line two");
    expect(result.content).toContain("line three");
    // Line numbers should be padded to 6 chars
    expect(result.content).toMatch(/^\s{5}1\tline one/);
    expect(result.content).toMatch(/\s{5}2\tline two/);
    expect(result.content).toMatch(/\s{5}3\tline three/);
  });

  test("reads with offset and limit", async () => {
    const filePath = path.join(tmpDir, "multi.txt");
    const lines = Array.from({ length: 10 }, (_, i) => `line ${i + 1}`).join("\n");
    await Bun.write(filePath, lines);

    const ctx = makeCtx(tmpDir);
    const result = await (fileReadTool.run as Function)(
      { path: filePath, offset: 2, limit: 3 },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const content = result.content as string;
    // Should start at line 3 (offset=2 means skip first 2 lines)
    expect(content).toContain("line 3");
    expect(content).toContain("line 4");
    expect(content).toContain("line 5");
    expect(content).not.toContain("line 1");
    expect(content).not.toContain("line 2");
    expect(content).not.toContain("line 6");
    // First displayed line number should be 3
    expect(content).toMatch(/\s{5}3\t/);
  });

  test("returns error for missing file", async () => {
    const ctx = makeCtx(tmpDir);
    const result = await (fileReadTool.run as Function)(
      { path: path.join(tmpDir, "nonexistent.txt") },
      ctx
    );

    expect(result.isError).toBe(true);
    expect(result.content).toContain("not found");
  });

  test("resolves relative path against cwd", async () => {
    const filePath = path.join(tmpDir, "relative.txt");
    await Bun.write(filePath, "relative content");

    const ctx = makeCtx(tmpDir);
    const result = await (fileReadTool.run as Function)(
      { path: "relative.txt" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("relative content");
  });

  test("denies path outside cwd when permission is not allow", async () => {
    const outsidePath = path.join(os.tmpdir(), "outside.txt");
    await Bun.write(outsidePath, "secret");

    const subDir = path.join(tmpDir, "subdir");
    await fs.mkdir(subDir);
    const ctx = makeCtx(subDir, "ask");

    const result = await (fileReadTool.run as Function)(
      { path: outsidePath },
      ctx
    );

    expect(result.isError).toBe(true);
    expect(result.content).toContain("Permission denied");

    await fs.unlink(outsidePath).catch(() => {});
  });
});

// ---------------------------------------------------------------------------
// file_write
// ---------------------------------------------------------------------------

describe("file_write", () => {
  test("creates a new file and returns byte count", async () => {
    const filePath = path.join(tmpDir, "new.txt");
    const ctx = makeCtx(tmpDir);
    const content = "hello world";

    const result = await (fileWriteTool.run as Function)(
      { path: filePath, content },
      ctx
    );

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("Wrote");
    expect(result.content).toContain(String(Buffer.byteLength(content, "utf8")));

    const written = await Bun.file(filePath).text();
    expect(written).toBe(content);
  });

  test("creates parent directories if missing", async () => {
    const nestedPath = path.join(tmpDir, "a", "b", "c", "file.txt");
    const ctx = makeCtx(tmpDir);
    const content = "nested content";

    const result = await (fileWriteTool.run as Function)(
      { path: nestedPath, content },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const written = await Bun.file(nestedPath).text();
    expect(written).toBe(content);
  });

  test("overwrites an existing file", async () => {
    const filePath = path.join(tmpDir, "existing.txt");
    await Bun.write(filePath, "old content");

    const ctx = makeCtx(tmpDir);
    const newContent = "new content";

    const result = await (fileWriteTool.run as Function)(
      { path: filePath, content: newContent },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const written = await Bun.file(filePath).text();
    expect(written).toBe(newContent);
  });

  test("resolves relative path against cwd", async () => {
    const ctx = makeCtx(tmpDir);
    const result = await (fileWriteTool.run as Function)(
      { path: "relative-write.txt", content: "relative" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const written = await Bun.file(path.join(tmpDir, "relative-write.txt")).text();
    expect(written).toBe("relative");
  });
});

// ---------------------------------------------------------------------------
// file_edit
// ---------------------------------------------------------------------------

describe("file_edit", () => {
  test("replaces unique string and returns diff", async () => {
    const filePath = path.join(tmpDir, "edit.txt");
    await Bun.write(filePath, "hello world\nhow are you\n");

    const ctx = makeCtx(tmpDir);
    const result = await (fileEditTool.run as Function)(
      { path: filePath, old_string: "hello world", new_string: "goodbye world" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const content = result.content as string;
    // Unified diff format
    expect(content).toContain("---");
    expect(content).toContain("+++");
    expect(content).toContain("-hello world");
    expect(content).toContain("+goodbye world");

    const written = await Bun.file(filePath).text();
    expect(written).toContain("goodbye world");
    expect(written).not.toContain("hello world");
  });

  test("errors if old_string not found", async () => {
    const filePath = path.join(tmpDir, "notfound.txt");
    await Bun.write(filePath, "some content here");

    const ctx = makeCtx(tmpDir);
    const result = await (fileEditTool.run as Function)(
      { path: filePath, old_string: "xyz not present", new_string: "replacement" },
      ctx
    );

    expect(result.isError).toBe(true);
    expect(result.content).toContain("string not found");
  });

  test("errors if old_string not unique and replace_all not set", async () => {
    const filePath = path.join(tmpDir, "multi.txt");
    await Bun.write(filePath, "foo bar\nfoo baz\n");

    const ctx = makeCtx(tmpDir);
    const result = await (fileEditTool.run as Function)(
      { path: filePath, old_string: "foo", new_string: "qux" },
      ctx
    );

    expect(result.isError).toBe(true);
    expect(result.content).toContain("not unique");
    expect(result.content).toContain("2");
    expect(result.content).toContain("replace_all");
  });

  test("replaces all occurrences when replace_all is true", async () => {
    const filePath = path.join(tmpDir, "all.txt");
    await Bun.write(filePath, "foo bar\nfoo baz\nfoo qux\n");

    const ctx = makeCtx(tmpDir);
    const result = await (fileEditTool.run as Function)(
      { path: filePath, old_string: "foo", new_string: "XXX", replace_all: true },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const written = await Bun.file(filePath).text();
    expect(written).toBe("XXX bar\nXXX baz\nXXX qux\n");
    expect(written).not.toContain("foo");
  });

  test("diff output has correct unified diff format", async () => {
    const filePath = path.join(tmpDir, "diffcheck.txt");
    await Bun.write(filePath, "alpha\nbeta\ngamma\n");

    const ctx = makeCtx(tmpDir);
    const result = await (fileEditTool.run as Function)(
      { path: filePath, old_string: "beta", new_string: "BETA" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const diff = result.content as string;
    // Should have unified diff markers
    expect(diff).toMatch(/^--- /m);
    expect(diff).toMatch(/^\+\+\+ /m);
    expect(diff).toMatch(/^@@ /m);
    expect(diff).toContain("-beta");
    expect(diff).toContain("+BETA");
  });

  test("errors for missing file", async () => {
    const ctx = makeCtx(tmpDir);
    const result = await (fileEditTool.run as Function)(
      {
        path: path.join(tmpDir, "ghost.txt"),
        old_string: "x",
        new_string: "y",
      },
      ctx
    );

    expect(result.isError).toBe(true);
    expect(result.content).toContain("not found");
  });
});
