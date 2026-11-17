import { describe, expect, test } from "bun:test";
import {
  CLOUD_MCP_LISTED_TOOLS,
  CLOUD_MCP_TOOL_ALIASES,
  CLOUD_MCP_TOOLS,
  callCloudMcpTool,
  handleCloudMcpMessage,
  resolveCloudMcpToolName,
  type CloudMcpExecResult,
  type CloudMcpGateway,
  type CloudMcpToolResult,
} from "../services/mcp/cloudMcp";
import { IdempotencyCache } from "../services/mcp/cloudMcpIdempotency";

const TERMINAL = "term_228c5e7589391886d2e22f31759e71e4";
const WORKSPACE = "ws_a2ee592c390e7fa3281014056f2103f0";

function ok(value: unknown): CloudMcpExecResult {
  return { exitCode: 0, stdout: JSON.stringify(value), stderr: "" };
}

/** A gateway that answers every guest call, counting them. */
function countingGateway(callerId: string | undefined, reply: (args: string) => CloudMcpExecResult = () => ok({ value: {} })) {
  const calls: string[] = [];
  const gateway: CloudMcpGateway = {
    callerId,
    listMachines: async () => [{ id: "vm-a", name: "alpha", status: "running" }],
    runCmuxTui: async (_machineId, args) => {
      calls.push(args);
      await Promise.resolve();
      return reply(args);
    },
  };
  return { gateway, calls };
}

const agentReply = (args: string) =>
  args.includes("create") ? ok({ value: { workspace_id: WORKSPACE } }) : ok({ value: { terminal_id: TERMINAL } });

describe("cloud MCP noun_verb names", () => {
  test("tools are noun_verb, and every old name resolves to the same handler", async () => {
    expect(CLOUD_MCP_TOOLS.map((t) => t.name).sort()).toEqual(
      ["agent_run", "machine_list", "terminal_input_write", "terminal_list", "terminal_read"],
    );
    for (const [alias, target] of Object.entries(CLOUD_MCP_TOOL_ALIASES)) {
      const live = CLOUD_MCP_TOOLS.some((t) => t.name === target);
      expect(resolveCloudMcpToolName(alias)).toBe(live ? target : null);
    }
    const { gateway } = countingGateway(undefined);
    expect(await callCloudMcpTool(gateway, "list_machines", {})).toEqual(await callCloudMcpTool(gateway, "machine_list", {}));
    const viaOld = countingGateway(undefined);
    const viaNew = countingGateway(undefined);
    const args = { machine_id: "vm-a", terminal_id: TERMINAL, text: "ls", submit: true };
    expect(await callCloudMcpTool(viaOld.gateway, "send_input", args)).toEqual(await callCloudMcpTool(viaNew.gateway, "terminal_input_write", args));
    expect(viaOld.calls).toEqual(viaNew.calls);
  });

  test("tools/list carries each live alias as a deprecated copy, and tools/call takes it", async () => {
    const names = CLOUD_MCP_LISTED_TOOLS.map((t) => t.name);
    for (const alias of ["list_machines", "list_terminals", "read_terminal", "send_input", "run_agent"]) {
      expect(names).toContain(alias);
    }
    expect(names).not.toContain("create_machine"); // no machine_create on this server yet
    const alias = CLOUD_MCP_LISTED_TOOLS.find((t) => t.name === "send_input");
    expect(alias?.description.startsWith("Deprecated alias of terminal_input_write")).toBe(true);
    const { gateway } = countingGateway(undefined);
    const reply = await handleCloudMcpMessage(gateway, {
      jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_machines", arguments: {} },
    });
    expect(reply).toMatchObject({ result: { structuredContent: { machines: [{ id: "vm-a" }] } } });
    expect(await handleCloudMcpMessage(gateway, {
      jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "machine_explode", arguments: {} },
    })).toMatchObject({ error: { code: -32602 } });
  });
});

describe("cloud MCP idempotency_key", () => {
  test("terminal_input_write with the same key twice writes once and echoes the key", async () => {
    const cache = new IdempotencyCache<CloudMcpToolResult>();
    const { gateway, calls } = countingGateway("user-1");
    const args = { machine_id: "vm-a", terminal_id: TERMINAL, text: "deploy", submit: true, idempotency_key: "k-1" };
    const first = await callCloudMcpTool(gateway, "terminal_input_write", args, cache);
    const again = await callCloudMcpTool(gateway, "send_input", args, cache); // the alias shares the key
    expect(calls).toHaveLength(1);
    expect(first.structuredContent).toMatchObject({ idempotency_key: "k-1", submitted: true });
    expect(first.structuredContent?.replayed).toBeUndefined();
    expect(again.structuredContent).toMatchObject({ idempotency_key: "k-1", replayed: true });
  });

  test("agent_run with the same key twice, even at once, starts one agent", async () => {
    const cache = new IdempotencyCache<CloudMcpToolResult>();
    const { gateway, calls } = countingGateway("user-1", agentReply);
    const args = { machine_id: "vm-a", agent: "claude", prompt: "fix it", idempotency_key: "run-1" };
    const results = await Promise.all([1, 2, 3].map(() => callCloudMcpTool(gateway, "agent_run", args, cache)));
    expect(calls).toHaveLength(2); // one workspace create, one run
    expect(new Set(results.map((r) => r.structuredContent?.terminal_id))).toEqual(new Set([TERMINAL]));
  });

  test("keys are per caller; other arguments conflict; no key always acts", async () => {
    const cache = new IdempotencyCache<CloudMcpToolResult>();
    const a = countingGateway("user-a");
    const b = countingGateway("user-b");
    const args = { machine_id: "vm-a", terminal_id: TERMINAL, text: "x", idempotency_key: "same" };
    await callCloudMcpTool(a.gateway, "terminal_input_write", args, cache);
    await callCloudMcpTool(b.gateway, "terminal_input_write", args, cache);
    expect([a.calls.length, b.calls.length]).toEqual([1, 1]);
    const clash = await callCloudMcpTool(a.gateway, "terminal_input_write", { ...args, text: "y" }, cache);
    expect(clash.structuredContent).toMatchObject({ error: "idempotency.conflict" });
    const bad = await callCloudMcpTool(a.gateway, "terminal_input_write", { ...args, idempotency_key: "has space" }, cache);
    expect(bad.structuredContent).toMatchObject({ error: "invalid_arguments" });
    const plain = { machine_id: "vm-a", terminal_id: TERMINAL, text: "z" };
    await callCloudMcpTool(a.gateway, "terminal_input_write", plain, cache);
    await callCloudMcpTool(a.gateway, "terminal_input_write", plain, cache);
    expect(a.calls).toHaveLength(3);
  });

  test("a failed call is forgotten, so the retry acts again", async () => {
    const cache = new IdempotencyCache<CloudMcpToolResult>();
    let fail = true;
    const { gateway, calls } = countingGateway("user-1", () => (fail ? { exitCode: 1, stdout: "", stderr: "busy" } : ok({ value: {} })));
    const args = { machine_id: "vm-a", terminal_id: TERMINAL, text: "x", idempotency_key: "k" };
    expect((await callCloudMcpTool(gateway, "terminal_input_write", args, cache)).isError).toBe(true);
    fail = false;
    const retried = await callCloudMcpTool(gateway, "terminal_input_write", args, cache);
    expect(retried.isError).toBeUndefined();
    expect(retried.structuredContent?.replayed).toBeUndefined();
    expect(calls).toHaveLength(2);
  });

  test("the cache is bounded by size and by age", async () => {
    let now = 0;
    const cache = new IdempotencyCache<number>(1000, 4, () => now);
    let runs = 0;
    const act = async () => ++runs;
    for (let i = 0; i < 10; i++) {
      now = i;
      await cache.once("s", `k${i}`, "fp", act, () => false);
    }
    expect(cache.size).toBe(4);
    expect((await cache.once("s", "k9", "fp", act, () => false)).replayed).toBe(true);
    now = 5000;
    expect((await cache.once("s", "k9", "fp", act, () => false)).replayed).toBe(false);
    expect(cache.size).toBe(1);
  });

  test("bench: per-call overhead of the dedupe lookup", async () => {
    const N = 20_000;
    const { gateway } = countingGateway("user-1");
    const base = { machine_id: "vm-a", terminal_id: TERMINAL, text: "hello from the bench" };
    const cache = new IdempotencyCache<CloudMcpToolResult>();
    const time = async (label: string, args: (i: number) => Record<string, unknown>) => {
      const start = performance.now();
      for (let i = 0; i < N; i++) await callCloudMcpTool(gateway, "terminal_input_write", args(i), cache);
      const us = ((performance.now() - start) * 1000) / N;
      console.log(`cloud-mcp dedupe bench ${label}: ${us.toFixed(2)} us/call`);
    };
    await time("before (no idempotency_key)", () => base);
    await time("after, new key each call (cache full, evicts)", (i) => ({ ...base, idempotency_key: `key-${i}` }));
    await time("after, replay of one key", () => ({ ...base, idempotency_key: "key-0x" }));
    expect(cache.size).toBeLessThanOrEqual(1000);
  });
});
