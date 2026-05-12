import { describe, test, expect } from "bun:test";
import { lspTool } from "../../../src/tools/lsp";
import type { ToolContext, PermissionLevel } from "../../../src/core/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeCtx(permissionLevel: PermissionLevel = "allow"): ToolContext {
  const cwd = process.cwd();
  return {
    cwd,
    abortSignal: new AbortController().signal,
    log: (_level, _text) => {},
    permissions: {
      resolve: (_toolName: string, _input: unknown) => permissionLevel,
      remember: () => {},
      narrow: (_allowedTools: string[]) => makeCtx(permissionLevel).permissions,
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

const EXPECTED_MSG =
  "LSP integration not yet implemented — install a language server and configure mcp_<server> for now, or use grep/file_read.";

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("lsp — stub", () => {
  test("returns the stub message and isError:false", async () => {
    const ctx = makeCtx();
    const result = await (lspTool.run as Function)(
      { action: "hover", path: "src/main.ts", line: 10, character: 5 },
      ctx
    );

    expect(result.isError).toBeFalsy();
    expect(result.content).toBe(EXPECTED_MSG);
  });

  test("all actions return the stub message", async () => {
    const actions = ["hover", "definition", "references", "diagnostics", "symbols", "format"] as const;
    const ctx = makeCtx();

    for (const action of actions) {
      const result = await (lspTool.run as Function)(
        { action, path: "src/foo.py" },
        ctx
      );
      expect(result.isError).toBeFalsy();
      expect(result.content).toBe(EXPECTED_MSG);
    }
  });

  test("accepts optional line, character, query fields", async () => {
    const ctx = makeCtx();
    const result = await (lspTool.run as Function)(
      { action: "symbols", path: "src/bar.ts", query: "MyClass" },
      ctx
    );

    expect(result.isError).toBeFalsy();
    expect(result.content).toBe(EXPECTED_MSG);
  });

  test("tool has allow default permission", () => {
    expect(lspTool.defaultPermission).toBe("allow");
  });

  test("tool name is lsp", () => {
    expect(lspTool.name).toBe("lsp");
  });
});
