/**
 * Unit tests for the slash command system.
 */
import { describe, it, expect, mock, beforeEach } from "bun:test";
import {
  SlashRegistry,
  createBuiltinSlashCommands,
  createDefaultSlashRegistry,
} from "../../../src/cli/slash.js";
import type { SlashContext, SlashCommand } from "../../../src/cli/slash.js";
import type { SessionHandle, ToolRegistry, Permissions, Tool } from "../../../src/core/types.js";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

// ---------------------------------------------------------------------------
// Minimal mocks
// ---------------------------------------------------------------------------

function makeMockSession(overrides?: Partial<SessionHandle["meta"]>): SessionHandle & { messages: any[]; replaceMessages: ReturnType<typeof mock> } {
  const holder = { messages: [] as any[] };
  const session: SessionHandle & { messages: any[]; replaceMessages: ReturnType<typeof mock> } = {
    meta: {
      id: "test-session-id-1234",
      cwd: "/test/cwd",
      startedAt: "2026-01-01T00:00:00Z",
      providerId: "anthropic",
      model: "claude-3-5-sonnet-20241022",
      ...overrides,
    },
    get messages() { return holder.messages; },
    set messages(v: any[]) { holder.messages = v; },
    append: mock(async () => {}),
    recordEvent: mock(async () => {}),
    replaceMessages: mock(async (msgs: any[]) => { holder.messages = msgs; }),
  } as any;
  return session;
}

function makeMockTool(name: string, description: string): Tool {
  return {
    name,
    description,
    inputSchema: {} as any,
    run: mock(async () => ({ content: "ok" })),
  };
}

function makeMockToolRegistry(tools: Tool[] = []): ToolRegistry {
  return {
    get: (name: string) => tools.find((t) => t.name === name),
    list: () => tools,
    toSchemas: () => [],
  };
}

function makeMockPermissions(): Permissions {
  return {
    resolve: () => "allow",
    remember: () => {},
    narrow: () => makeMockPermissions(),
    _allow: [],
    _ask: [],
    _deny: [],
  } as any;
}

function makeMockMemoryStore() {
  const records: any[] = [];
  return {
    list: mock(async () => records),
    save: mock(async (record: any) => {
      records.push({ ...record, path: `/fake/${record.name}.md` });
      return { ...record, path: `/fake/${record.name}.md` };
    }),
    remove: mock(async (name: string) => {
      const idx = records.findIndex((r) => r.name === name);
      if (idx !== -1) {
        records.splice(idx, 1);
        return true;
      }
      return false;
    }),
  };
}

function makeCtx(overrides: Partial<SlashContext> = {}): SlashContext {
  return {
    session: makeMockSession(),
    toolRegistry: makeMockToolRegistry([
      makeMockTool("bash", "Run shell commands"),
      makeMockTool("read_file", "Read a file"),
    ]),
    permissions: makeMockPermissions(),
    cwd: "/test/cwd",
    abort: mock(() => {}),
    exit: mock(() => {}),
    appendSystemMessage: mock(async () => {}),
    refreshSession: mock(async () => {}),
    getMemoryStore: () => makeMockMemoryStore(),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// SlashRegistry basics
// ---------------------------------------------------------------------------

describe("SlashRegistry", () => {
  it("registers and retrieves a command by name", () => {
    const reg = new SlashRegistry();
    const cmd: SlashCommand = {
      name: "test",
      description: "Test command",
      run: async () => ({ consumed: true }),
    };
    reg.register(cmd);
    expect(reg.get("test")).toBe(cmd);
  });

  it("registers aliases and resolves them", () => {
    const reg = new SlashRegistry();
    const cmd: SlashCommand = {
      name: "quit",
      aliases: ["exit"],
      description: "Quit",
      run: async () => ({ consumed: true }),
    };
    reg.register(cmd);
    expect(reg.get("quit")).toBe(cmd);
    expect(reg.get("exit")).toBe(cmd);
  });

  it("list() deduplicates aliased commands", () => {
    const reg = new SlashRegistry();
    const cmd: SlashCommand = {
      name: "quit",
      aliases: ["exit"],
      description: "Quit",
      run: async () => ({ consumed: true }),
    };
    reg.register(cmd);
    const list = reg.list();
    expect(list.filter((c) => c === cmd).length).toBe(1);
  });

  it("isSlashInput returns true for / prefixed input", () => {
    const reg = new SlashRegistry();
    expect(reg.isSlashInput("/help")).toBe(true);
    expect(reg.isSlashInput("hello")).toBe(false);
    expect(reg.isSlashInput("")).toBe(false);
  });

  it("dispatch returns consumed=false for unknown command", async () => {
    const reg = new SlashRegistry();
    const result = await reg.dispatch("/unknown-xyz", makeCtx());
    expect(result.consumed).toBe(false);
  });

  it("dispatch returns consumed=false for non-slash input", async () => {
    const reg = new SlashRegistry();
    const result = await reg.dispatch("hello world", makeCtx());
    expect(result.consumed).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Built-in commands count
// ---------------------------------------------------------------------------

describe("createBuiltinSlashCommands", () => {
  it("returns exactly 15 commands", () => {
    const commands = createBuiltinSlashCommands();
    expect(commands.length).toBe(15);
  });

  it("includes all expected command names", () => {
    const reg = createDefaultSlashRegistry();
    const names = reg.list().map((c) => c.name);
    const expected = [
      "help",
      "quit",
      "clear",
      "model",
      "resume",
      "skills",
      "memory",
      "tools",
      "status",
      "cost",
      "permissions",
      "export",
      "init",
      "doctor",
      "compact",
    ];
    for (const name of expected) {
      expect(names).toContain(name);
    }
  });
});

// ---------------------------------------------------------------------------
// /help
// ---------------------------------------------------------------------------

describe("/help", () => {
  it("renders a list including all command names", async () => {
    const reg = createDefaultSlashRegistry();
    const ctx = makeCtx();
    const result = await reg.dispatch("/help", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toBeDefined();

    const display = result.display!;
    const expectedNames = [
      "help",
      "quit",
      "clear",
      "model",
      "resume",
      "skills",
      "memory",
      "tools",
      "status",
      "cost",
      "permissions",
      "export",
      "init",
      "doctor",
      "compact",
    ];
    for (const name of expectedNames) {
      expect(display).toContain(`/${name}`);
    }
  });
});

// ---------------------------------------------------------------------------
// /quit
// ---------------------------------------------------------------------------

describe("/quit", () => {
  it("calls ctx.exit and returns consumed=true", async () => {
    const exitFn = mock(() => {});
    const ctx = makeCtx({ exit: exitFn });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/quit", ctx);
    expect(result.consumed).toBe(true);
    expect(exitFn).toHaveBeenCalledTimes(1);
  });

  it("/exit alias also calls ctx.exit", async () => {
    const exitFn = mock(() => {});
    const ctx = makeCtx({ exit: exitFn });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/exit", ctx);
    expect(result.consumed).toBe(true);
    expect(exitFn).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// /clear
// ---------------------------------------------------------------------------

describe("/clear", () => {
  it("calls refreshSession and returns consumed=true", async () => {
    const refreshFn = mock(async () => {});
    const ctx = makeCtx({ refreshSession: refreshFn });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/clear", ctx);
    expect(result.consumed).toBe(true);
    expect(refreshFn).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// /model
// ---------------------------------------------------------------------------

describe("/model", () => {
  it("with no args displays current model", async () => {
    const ctx = makeCtx();
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/model", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("claude-3-5-sonnet-20241022");
  });

  it("with arg switches model", async () => {
    const ctx = makeCtx();
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/model claude-opus-4", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("claude-opus-4");
    expect(ctx.session.meta.model).toBe("claude-opus-4");
  });
});

// ---------------------------------------------------------------------------
// /tools
// ---------------------------------------------------------------------------

describe("/tools", () => {
  it("lists tools from registry", async () => {
    const ctx = makeCtx();
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/tools", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("bash");
    expect(result.display).toContain("read_file");
    expect(result.display).toContain("Run shell commands");
  });

  it("shows message when no tools registered", async () => {
    const ctx = makeCtx({
      toolRegistry: makeMockToolRegistry([]),
    });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/tools", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("No tools");
  });
});

// ---------------------------------------------------------------------------
// Unknown /xyz
// ---------------------------------------------------------------------------

describe("unknown command", () => {
  it("/xyz returns consumed=false", async () => {
    const reg = createDefaultSlashRegistry();
    const ctx = makeCtx();
    const result = await reg.dispatch("/xyz-not-a-command", ctx);
    expect(result.consumed).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// /export
// ---------------------------------------------------------------------------

describe("/export", () => {
  it("writes transcript to a file and returns the path", async () => {
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "cmux101-slash-test-"));
    const outPath = path.join(tmpDir, "transcript.md");

    const ctx = makeCtx({
      cwd: tmpDir,
    });
    // Add a message to the session
    (ctx.session as any).messages = [
      { role: "user", content: [{ type: "text", text: "Hello world" }] },
    ];

    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch(`/export ${outPath}`, ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain(outPath);

    // Verify file was written
    const stat = await fs.stat(outPath);
    expect(stat.isFile()).toBe(true);

    const content = await Bun.file(outPath).text();
    expect(content).toContain("Hello world");
    expect(content).toContain("test-session-id-1234");

    // Cleanup
    await fs.rm(tmpDir, { recursive: true });
  });

  it("uses default path when no path arg provided", async () => {
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "cmux101-slash-test-"));
    const ctx = makeCtx({ cwd: tmpDir });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/export", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("test-session-id-1234");
    expect(result.display).toContain("cmux101-session-");

    // Cleanup
    await fs.rm(tmpDir, { recursive: true });
  });
});

// ---------------------------------------------------------------------------
// /memory list
// ---------------------------------------------------------------------------

describe("/memory list", () => {
  it("calls memory store list() and returns results", async () => {
    const store = makeMockMemoryStore();
    // Pre-populate with a record
    await store.save({
      name: "test-note",
      description: "A test note",
      type: "user",
      body: "Some content",
      scope: "global",
    });

    const ctx = makeCtx({ getMemoryStore: () => store });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/memory list", ctx);
    expect(result.consumed).toBe(true);
    expect(store.list).toHaveBeenCalled();
    expect(result.display).toContain("test-note");
  });

  it("shows message when no memories stored", async () => {
    const store = makeMockMemoryStore();
    const ctx = makeCtx({ getMemoryStore: () => store });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/memory list", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("No memories");
  });

  it("/memory with no args defaults to list", async () => {
    const store = makeMockMemoryStore();
    const ctx = makeCtx({ getMemoryStore: () => store });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/memory", ctx);
    expect(result.consumed).toBe(true);
    expect(store.list).toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// /status
// ---------------------------------------------------------------------------

describe("/status", () => {
  it("displays session info", async () => {
    const ctx = makeCtx();
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/status", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("test-session-id-1234");
    expect(result.display).toContain("anthropic");
    expect(result.display).toContain("claude-3-5-sonnet-20241022");
  });
});

// ---------------------------------------------------------------------------
// /cost
// ---------------------------------------------------------------------------

describe("/cost", () => {
  it("displays not-implemented message", async () => {
    const ctx = makeCtx();
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/cost", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("not yet implemented");
  });
});

// ---------------------------------------------------------------------------
// /compact
// ---------------------------------------------------------------------------

describe("/compact", () => {
  it("returns empty message when no messages", async () => {
    const ctx = makeCtx();
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/compact", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("empty");
  });

  it("reduces message count and produces a summary for a long conversation", async () => {
    const session = makeMockSession();
    // Add 10 messages: 5 to be summarized + 5 to be kept
    const makeMsg = (i: number) => ({
      role: "user" as const,
      content: [{ type: "text" as const, text: `Message number ${i}` }],
    });
    for (let i = 0; i < 10; i++) {
      session.messages.push(makeMsg(i));
    }

    const ctx = makeCtx({ session });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/compact", ctx);

    expect(result.consumed).toBe(true);
    expect(result.display).toContain("10 messages");
    // After compaction: 1 summary + 5 kept = 6
    expect(result.display).toContain("6 messages");
    // replaceMessages was called
    expect((session.replaceMessages as ReturnType<typeof mock>).mock.calls.length).toBe(1);
    // The resulting messages array is 6 items
    expect(session.messages.length).toBe(6);
    // First message is the summary
    expect(session.messages[0].content[0].text).toContain("[compacted conversation summary]");
  });

  it("does not add a summary message when all messages fit in keep window", async () => {
    const session = makeMockSession();
    // Add only 3 messages (less than KEEP=5)
    for (let i = 0; i < 3; i++) {
      session.messages.push({
        role: "user" as const,
        content: [{ type: "text" as const, text: `msg ${i}` }],
      });
    }
    const ctx = makeCtx({ session });
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/compact", ctx);

    expect(result.consumed).toBe(true);
    // All 3 messages are kept, no summary prepended
    expect(session.messages.length).toBe(3);
  });
});

// ---------------------------------------------------------------------------
// /doctor
// ---------------------------------------------------------------------------

describe("/doctor", () => {
  it("runs preflight checks and displays results", async () => {
    const ctx = makeCtx();
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/doctor", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("PASS");
    expect(result.display).toContain("Provider configured");
    expect(result.display).toContain("Tools registered");
  });
});

// ---------------------------------------------------------------------------
// /permissions
// ---------------------------------------------------------------------------

describe("/permissions", () => {
  it("displays permission rules", async () => {
    const ctx = makeCtx();
    const reg = createDefaultSlashRegistry();
    const result = await reg.dispatch("/permissions", ctx);
    expect(result.consumed).toBe(true);
    expect(result.display).toContain("Permission rules");
    expect(result.display).toContain("Allow");
    expect(result.display).toContain("Deny");
  });
});
