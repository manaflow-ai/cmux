/**
 * Unit tests for MCP client manager and tool builder.
 */

import { describe, test, expect, mock, beforeEach } from "bun:test";
import { jsonSchemaToZod, buildMcpTools } from "../../../src/tools/mcp.js";
import { McpClientManager, type McpConnection } from "../../../src/mcp/client.js";
import type { McpServerConfig } from "../../../src/core/types.js";
import { z } from "zod";

// ---------------------------------------------------------------------------
// jsonSchemaToZod tests
// ---------------------------------------------------------------------------

describe("jsonSchemaToZod", () => {
  test("handles type:string", () => {
    const schema = jsonSchemaToZod({ type: "string" });
    expect(schema.parse("hello")).toBe("hello");
    expect(() => schema.parse(42)).toThrow();
  });

  test("handles type:number", () => {
    const schema = jsonSchemaToZod({ type: "number" });
    expect(schema.parse(3.14)).toBe(3.14);
    expect(() => schema.parse("nope")).toThrow();
  });

  test("handles type:integer", () => {
    const schema = jsonSchemaToZod({ type: "integer" });
    expect(schema.parse(5)).toBe(5);
    expect(() => schema.parse(3.14)).toThrow();
  });

  test("handles type:boolean", () => {
    const schema = jsonSchemaToZod({ type: "boolean" });
    expect(schema.parse(true)).toBe(true);
    expect(() => schema.parse("true")).toThrow();
  });

  test("handles type:array with items", () => {
    const schema = jsonSchemaToZod({ type: "array", items: { type: "string" } });
    expect(schema.parse(["a", "b"])).toEqual(["a", "b"]);
    expect(() => schema.parse([1, 2])).toThrow();
  });

  test("handles type:array without items", () => {
    const schema = jsonSchemaToZod({ type: "array" });
    expect(schema.parse([1, "a", true])).toEqual([1, "a", true]);
  });

  test("handles type:object with required fields", () => {
    const schema = jsonSchemaToZod({
      type: "object",
      properties: {
        name: { type: "string" },
        age: { type: "integer" },
        bio: { type: "string" },
      },
      required: ["name", "age"],
    });
    // required fields present => ok
    expect(schema.parse({ name: "Alice", age: 30 })).toMatchObject({ name: "Alice", age: 30 });
    // optional field included => ok
    expect(schema.parse({ name: "Bob", age: 25, bio: "Hello" })).toMatchObject({ bio: "Hello" });
    // missing required => throws
    expect(() => schema.parse({ name: "Alice" })).toThrow();
    // missing optional => ok
    expect(schema.parse({ name: "Alice", age: 30 })).not.toHaveProperty("bio");
  });

  test("handles enum of strings", () => {
    const schema = jsonSchemaToZod({ enum: ["red", "green", "blue"] });
    expect(schema.parse("red")).toBe("red");
    expect(() => schema.parse("purple")).toThrow();
  });

  test("handles enum of mixed values", () => {
    const schema = jsonSchemaToZod({ enum: [1, "two", true] });
    expect(schema.parse(1)).toBe(1);
    expect(schema.parse("two")).toBe("two");
    expect(() => schema.parse("three")).toThrow();
  });

  test("falls back to z.record(z.unknown()) for unrecognized schema", () => {
    const schema = jsonSchemaToZod({ type: "bogus-type" } as Record<string, unknown>);
    // Should not throw and should accept any record
    expect(schema.parse({ anything: "goes" })).toMatchObject({ anything: "goes" });
  });

  test("handles nested objects", () => {
    const schema = jsonSchemaToZod({
      type: "object",
      properties: {
        address: {
          type: "object",
          properties: {
            city: { type: "string" },
            zip: { type: "string" },
          },
          required: ["city"],
        },
      },
      required: ["address"],
    });
    expect(schema.parse({ address: { city: "SF" } })).toMatchObject({ address: { city: "SF" } });
    expect(() => schema.parse({ address: {} })).toThrow();
  });
});

// ---------------------------------------------------------------------------
// buildMcpTools tests
// ---------------------------------------------------------------------------

describe("buildMcpTools", () => {
  const fakeCallTool = mock(async () => ({
    content: [{ type: "text", text: "result" }],
  }));

  const makeConnection = (
    name: string,
    toolNames: string[],
  ): McpConnection => ({
    name,
    tools: toolNames.map((t) => ({
      name: t,
      description: `Tool ${t}`,
      inputSchema: {
        type: "object",
        properties: { input: { type: "string" } },
        required: ["input"],
      },
    })),
    callTool: fakeCallTool,
    close: mock(async () => {}),
  });

  test("generates correct namespaced tool names", () => {
    const conn = makeConnection("my-server", ["read_file", "write_file"]);
    const tools = buildMcpTools([conn]);
    const names = tools.map((t) => t.name);
    expect(names).toContain("mcp__my-server__read_file");
    expect(names).toContain("mcp__my-server__write_file");
  });

  test("sanitizes slashes and spaces in name", () => {
    const conn = makeConnection("My Server", ["do/something cool"]);
    const tools = buildMcpTools([conn]);
    expect(tools[0].name).toBe("mcp__my_server__do_something_cool");
  });

  test("prefixes description with [MCP/serverName]", () => {
    const conn = makeConnection("github", ["list_prs"]);
    const tools = buildMcpTools([conn]);
    expect(tools[0].description).toBe("[MCP/github] Tool list_prs");
  });

  test("produces tools from multiple connections", () => {
    const conn1 = makeConnection("fs", ["read", "write"]);
    const conn2 = makeConnection("gh", ["pr_list"]);
    const tools = buildMcpTools([conn1, conn2]);
    expect(tools).toHaveLength(3);
  });

  test("defaultPermission is 'ask'", () => {
    const conn = makeConnection("srv", ["tool1"]);
    const tools = buildMcpTools([conn]);
    expect(tools[0].defaultPermission).toBe("ask");
  });

  test("tool run calls connection.callTool and maps result to content string", async () => {
    const conn = makeConnection("srv", ["echo"]);
    const tools = buildMcpTools([conn]);
    const tool = tools[0];

    const ctx = makeToolContext();
    const result = await (tool.run as Function)({ input: "hello" }, ctx);
    expect(result.content).toBe("result");
    expect(result.isError).toBeUndefined();
  });

  test("tool run returns isError on callTool failure", async () => {
    const failConn: McpConnection = {
      name: "failing",
      tools: [
        {
          name: "boom",
          description: "Explodes",
          inputSchema: { type: "object" },
        },
      ],
      callTool: async () => {
        throw new Error("connection error");
      },
      close: async () => {},
    };
    const tools = buildMcpTools([failConn]);
    const ctx = makeToolContext();
    const result = await (tools[0].run as Function)({}, ctx);
    expect(result.isError).toBe(true);
    expect(result.content).toContain("connection error");
  });

  test("tool run respects abortSignal that is already aborted", async () => {
    const conn = makeConnection("srv", ["slow"]);
    const tools = buildMcpTools([conn]);
    const ac = new AbortController();
    ac.abort();
    const ctx = makeToolContext(ac.signal);
    const result = await (tools[0].run as Function)({}, ctx);
    expect(result.isError).toBe(true);
    expect(result.content).toContain("aborted");
  });
});

// ---------------------------------------------------------------------------
// McpClientManager — failing server connection test
// ---------------------------------------------------------------------------

describe("McpClientManager", () => {
  test("connect() rejects with a clear error for a bad stdio command", async () => {
    const logs: string[] = [];
    const manager = new McpClientManager((level, msg) => logs.push(`${level}: ${msg}`));

    const badConfig: McpServerConfig = {
      name: "bad-server",
      transport: "stdio",
      command: "__this_command_does_not_exist__",
      args: [],
    };

    await expect(manager.connect(badConfig)).rejects.toThrow();
    // Manager itself should still be operational
    expect(manager.connections()).toHaveLength(0);
  });

  test("connect() rejects with clear error when command is missing for stdio", async () => {
    const manager = new McpClientManager(() => {});
    const badConfig: McpServerConfig = {
      name: "no-cmd",
      transport: "stdio",
      // command intentionally omitted
    };
    await expect(manager.connect(badConfig)).rejects.toThrow(/no command/);
  });

  test("connect() rejects with clear error when url is missing for sse", async () => {
    const manager = new McpClientManager(() => {});
    const badConfig: McpServerConfig = {
      name: "no-url",
      transport: "sse",
    };
    await expect(manager.connect(badConfig)).rejects.toThrow(/no url/);
  });

  test("disconnectAll() closes all connections without throwing", async () => {
    const closed: string[] = [];
    // Inject pre-built fake connections directly via casting
    const manager = new McpClientManager(() => {});

    // Access private _connections to inject fake connections
    const fakeConn1: McpConnection = {
      name: "c1",
      tools: [],
      callTool: async () => ({}),
      close: async () => { closed.push("c1"); },
    };
    const fakeConn2: McpConnection = {
      name: "c2",
      tools: [],
      callTool: async () => ({}),
      close: async () => { closed.push("c2"); },
    };

    // @ts-expect-error — accessing private field for test
    manager._connections.push(fakeConn1, fakeConn2);

    await manager.disconnectAll();
    expect(closed).toContain("c1");
    expect(closed).toContain("c2");
    expect(manager.connections()).toHaveLength(0);
  });

  test("loadMcpFromConfig skips failing servers and returns healthy ones", async () => {
    // We can't easily mock the SDK transport in unit tests without spawning
    // real processes, so we test the graceful-failure path via the
    // per-server error logging in loadMcpFromConfig.
    const { loadMcpFromConfig } = await import("../../../src/tools/mcp.js");
    const logs: string[] = [];

    const result = await loadMcpFromConfig(
      {
        defaultProvider: "test",
        defaultModel: "test",
        providers: {},
        mcp: [
          {
            name: "bad-server",
            transport: "stdio",
            command: "__nonexistent_cmd__",
          },
        ],
      },
      (level, msg) => logs.push(`${level}: ${msg}`),
    );

    // Should return no connections (server failed), but not throw
    expect(result.connections).toHaveLength(0);
    expect(result.tools).toHaveLength(0);
    // Error should have been logged
    expect(logs.some((l) => l.includes("error") && l.includes("bad-server"))).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

import type { ToolContext, PermissionLevel } from "../../../src/core/types.js";

function makeToolContext(signal?: AbortSignal): ToolContext {
  return {
    cwd: "/tmp",
    abortSignal: signal ?? new AbortController().signal,
    log: () => {},
    permissions: {
      resolve: () => "allow" as PermissionLevel,
      remember: () => {},
      narrow: () => makeToolContext(signal).permissions,
    },
    session: {
      meta: {
        id: "test",
        cwd: "/tmp",
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
