import { describe, expect, test } from "bun:test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Cause from "effect/Cause";
import * as Layer from "effect/Layer";
import {
  CLOUD_MCP_TOOLS,
  callCloudMcpTool,
  CloudMcpToolError,
  cmuxTuiArgs,
  handleCloudMcpBody,
  handleCloudMcpMessage,
  type CloudMcpExecResult,
  type CloudMcpGateway,
} from "../services/mcp/cloudMcp";
import { cloudMcpGatewayFor, type CloudMcpCaller } from "../services/mcp/cloudMcpGateway";
import { cmuxTuiRunCommand } from "../services/vms/drivers/cmuxTuiDaemon";
import { guestCuaCommand, guestCuaSession } from "../services/vms/guestCua";
import { computerUseReadinessFor } from "../services/vms/computerUse";
import { noOpVmBillingGateway, VmBillingGateway } from "../services/vms/billingGateway";
import { isVmWorkflowError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { respondVmWorkflowError } from "../services/vms/routeHelpers";
import type { VmRouteResult } from "../services/vms/routeWorkflow";
import type { VmWorkflowProgram } from "../services/vms/workflows";

const TERMINAL = "term_228c5e7589391886d2e22f31759e71e4";
const WORKSPACE = "ws_a2ee592c390e7fa3281014056f2103f0";

type RecordedCall = { readonly machineId: string; readonly args: string };

function fakeGateway(replies: Array<CloudMcpExecResult | ((call: RecordedCall) => CloudMcpExecResult)> = []) {
  const calls: RecordedCall[] = [];
  const gateway: CloudMcpGateway = {
    listMachines: async () => [{ id: "vm-a", name: "alpha", status: "running" }],
    runCmuxTui: async (machineId, args) => {
      const call = { machineId, args };
      calls.push(call);
      const reply = replies.shift();
      if (!reply) throw new Error(`unexpected guest call: ${args}`);
      return typeof reply === "function" ? reply(call) : reply;
    },
  };
  return { gateway, calls };
}

function ok(value: unknown): CloudMcpExecResult {
  return { exitCode: 0, stdout: JSON.stringify(value), stderr: "" };
}

/** What `sh` hands the program for a quoted argument string: one array entry per argv word. */
async function shellWords(args: string): Promise<string[]> {
  const { stdout } = await promisify(execFile)("sh", ["-c", `for a in ${args}; do printf '%s\\0' "$a"; done`], { encoding: "utf8" });
  return stdout.split("\0").slice(0, -1);
}

describe("cloud MCP protocol", () => {
  test("initialize negotiates a supported version and advertises tools", async () => {
    const { gateway } = fakeGateway();
    const reply = await handleCloudMcpMessage(gateway, {
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } },
    });
    expect(reply).toMatchObject({ id: 1, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} } } });
    const unknown = await handleCloudMcpMessage(gateway, {
      jsonrpc: "2.0", id: 2, method: "initialize", params: { protocolVersion: "1999-01-01" },
    });
    expect(unknown).toMatchObject({ result: { protocolVersion: "2025-11-25" } });
  });

  test("notifications get no reply and unknown methods are method-not-found", async () => {
    const { gateway } = fakeGateway();
    expect(await handleCloudMcpMessage(gateway, { jsonrpc: "2.0", method: "notifications/initialized" })).toBeNull();
    expect(await handleCloudMcpMessage(gateway, { jsonrpc: "2.0", id: 3, method: "resources/list" }))
      .toMatchObject({ error: { code: -32601 } });
  });

  test("a batch gets one reply per request, and a defect is a -32603 for that id", async () => {
    const gateway: CloudMcpGateway = {
      listMachines: async () => {
        throw new Error("database down");
      },
      runCmuxTui: async () => ok([]),
    };
    const defects: unknown[] = [];
    const reply = await handleCloudMcpBody(gateway, [
      { jsonrpc: "2.0", id: 1, method: "ping" },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: "b", method: "tools/call", params: { name: "list_machines", arguments: {} } },
    ], (error) => defects.push(error));
    expect(reply).toEqual([
      { jsonrpc: "2.0", id: 1, result: {} },
      { jsonrpc: "2.0", id: "b", error: { code: -32603, message: "Internal error" } },
    ]);
    expect(defects).toHaveLength(1);
    const tooMany = Array.from({ length: 9 }, (_, i) => ({ jsonrpc: "2.0", id: i, method: "ping" }));
    expect(await handleCloudMcpBody(gateway, tooMany, () => {})).toMatchObject({ error: { code: -32600 } });
    expect(await handleCloudMcpBody(gateway, { jsonrpc: "2.0", method: "notifications/initialized" }, () => {})).toBeNull();
  });

  test("every tool states all three ChatGPT hints explicitly", () => {
    for (const tool of CLOUD_MCP_TOOLS) {
      for (const hint of ["readOnlyHint", "destructiveHint", "openWorldHint"] as const) {
        expect(typeof tool.annotations[hint]).toBe("boolean");
      }
    }
    const byName = Object.fromEntries(CLOUD_MCP_TOOLS.map((tool) => [tool.name, tool.annotations]));
    expect(byName.send_input.destructiveHint).toBe(true);
    expect(byName.run_agent.readOnlyHint).toBe(false);
    expect(byName.list_machines.readOnlyHint).toBe(true);
    // Terminal reads go through execVm, which resumes a paused (billed) machine.
    expect(byName.read_terminal.readOnlyHint).toBe(false);
    expect(byName.list_terminals.readOnlyHint).toBe(false);
  });
});

describe("cloud MCP tool arguments", () => {
  test("a terminal id that is not a term_ id never reaches the machine", async () => {
    const { gateway, calls } = fakeGateway();
    for (const terminal_id of ["term_x; rm -rf ~", "$(id)", "current", "pane_abc", "term_"]) {
      const result = await callCloudMcpTool(gateway, "read_terminal", { machine_id: "vm-a", terminal_id });
      expect(result.isError).toBe(true);
      expect(result.structuredContent).toMatchObject({ error: "invalid_arguments" });
    }
    expect(calls).toHaveLength(0);
  });

  test("unknown arguments are refused instead of ignored", async () => {
    const { gateway, calls } = fakeGateway();
    const result = await callCloudMcpTool(gateway, "list_terminals", { machine_id: "vm-a", session: "main" });
    expect(result.isError).toBe(true);
    expect(calls).toHaveLength(0);
  });

  test("run_agent passes the prompt as one argv word, never as shell text", async () => {
    const prompt = `fix it'; touch /tmp/pwned; echo "$HOME" \`id\``;
    const { gateway, calls } = fakeGateway([
      ok({ value: { kind: "workspace", workspace_id: WORKSPACE } }),
      ok({ value: { kind: "terminal", workspace_id: WORKSPACE, terminal_id: TERMINAL } }),
    ]);
    const result = await callCloudMcpTool(gateway, "run_agent", { machine_id: "vm-a", agent: "claude", prompt });
    expect(result.isError).toBeUndefined();
    expect(result.structuredContent).toEqual({ machine_id: "vm-a", agent: "claude", workspace_id: WORKSPACE, terminal_id: TERMINAL });
    expect(await shellWords(calls[0].args)).toEqual(["--session", "cloud", "--json", "workspace", "create", "--name", "claude (via MCP)", "--empty"]);
    expect(await shellWords(calls[1].args)).toEqual([
      "--session", "cloud", "--json", "workspace", WORKSPACE, "run", "--on-exit", "keep", "--",
      "bash", "-lc", 'cd "$HOME" && exec "$@"', "bash", "claude", "-p", "--", prompt,
    ]);
  });

  test("a prompt that looks like a flag stays a prompt", async () => {
    const { gateway, calls } = fakeGateway([
      ok({ value: { workspace_id: WORKSPACE } }),
      ok({ value: { terminal_id: TERMINAL } }),
    ]);
    await callCloudMcpTool(gateway, "run_agent", { machine_id: "vm-a", agent: "codex", prompt: "--dangerously-bypass-approvals-and-sandbox" });
    expect((await shellWords(calls[1].args)).slice(-4)).toEqual(["codex", "exec", "--", "--dangerously-bypass-approvals-and-sandbox"]);
    const pi = fakeGateway();
    const refused = await callCloudMcpTool(pi.gateway, "run_agent", { machine_id: "vm-a", agent: "pi", prompt: "--help" });
    expect(refused.structuredContent).toMatchObject({ error: "invalid_arguments" });
    expect(pi.calls).toHaveLength(0);
  });

  test("a failed agent start closes the workspace it created", async () => {
    const { gateway, calls } = fakeGateway([
      ok({ value: { workspace_id: WORKSPACE } }),
      { exitCode: 3, stdout: "", stderr: "timed out" },
      ok({ value: {} }),
    ]);
    const result = await callCloudMcpTool(gateway, "run_agent", { machine_id: "vm-a", agent: "claude", prompt: "hi" });
    expect(result.isError).toBe(true);
    expect((await shellWords(calls[2].args)).slice(3)).toEqual(["workspace", WORKSPACE, "close"]);
  });

  test("every guest command stays under the 64 KiB exec cap", async () => {
    const { gateway, calls } = fakeGateway();
    // ~10 KiB of quotes is under the 16 KiB argument cap but over 64 KiB once quoted and run.
    const result = await callCloudMcpTool(gateway, "run_agent", { machine_id: "vm-a", agent: "claude", prompt: "'".repeat(10 * 1024) });
    expect(result.structuredContent).toMatchObject({ error: "invalid_arguments" });
    expect(calls).toHaveLength(0);
    const accepted = fakeGateway([ok({ value: {} })]);
    await callCloudMcpTool(accepted.gateway, "send_input", { machine_id: "vm-a", terminal_id: TERMINAL, text: "x".repeat(16 * 1024) });
    expect(accepted.calls).toHaveLength(1);
    expect(Buffer.byteLength(cmuxTuiRunCommand(accepted.calls[0].args))).toBeLessThanOrEqual(64 * 1024);
  });

  test("send_input is one write, with Enter as a carriage return only when asked", async () => {
    const { gateway, calls } = fakeGateway([ok({ value: {} }), ok({ value: {} })]);
    const result = await callCloudMcpTool(gateway, "send_input", { machine_id: "vm-a", terminal_id: TERMINAL, text: "ls -la", submit: true });
    expect(result.structuredContent).toMatchObject({ submitted: true, sent_bytes: 6 });
    await callCloudMcpTool(gateway, "send_input", { machine_id: "vm-a", terminal_id: TERMINAL, text: "draft" });
    expect(await Promise.all(calls.map(async (call) => (await shellWords(call.args)).slice(3)))).toEqual([
      ["terminal", TERMINAL, "write", "--text", "ls -la\r"],
      ["terminal", TERMINAL, "write", "--text", "draft"],
    ]);
  });

  test("read_terminal returns the text once, as content", async () => {
    const { gateway } = fakeGateway([ok({ text: "hello", rows: 24 })]);
    const result = await callCloudMcpTool(gateway, "read_terminal", { machine_id: "vm-a", terminal_id: TERMINAL });
    expect(result.content).toEqual([{ type: "text", text: "hello" }]);
    expect(result.structuredContent).toEqual({ machine_id: "vm-a", terminal_id: TERMINAL, source: "screen" });
  });

  test("a failed guest command is a tool error, not a thrown request", async () => {
    const { gateway } = fakeGateway([{ exitCode: 1, stdout: "", stderr: "selector.not_found: term_x" }]);
    const result = await callCloudMcpTool(gateway, "read_terminal", { machine_id: "vm-a", terminal_id: "term_x" });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("selector.not_found");
  });

  test("cmuxTuiArgs targets the machine's cloud session", async () => {
    expect(await shellWords(cmuxTuiArgs(["terminal", "list"]))).toEqual(["--session", "cloud", "--json", "terminal", "list"]);
  });

  test("computer-use arguments stay scoped to the desktop and return screenshots as MCP images", async () => {
    const calls: Array<{ machineId: string; tool: string; args: Record<string, unknown> }> = [];
    const gateway: CloudMcpGateway = {
      listMachines: async () => [],
      runCmuxTui: async () => ok({}),
      runCua: async (machineId, tool, args) => {
        calls.push({ machineId, tool, args });
        return ok({
          structuredContent: {
            platform: "linux",
          },
          content: [
            { type: "text", text: "desktop captured" },
            { type: "image", data: "aGVsbG8=", mimeType: "image/png" },
          ],
        });
      },
    };
    const result = await callCloudMcpTool(gateway, "computer_screenshot", {
      machine_id: "vm-a",
    });
    expect(result.isError).toBeUndefined();
    expect(result.content).toEqual([
      { type: "text", text: "desktop captured" },
      { type: "image", data: "aGVsbG8=", mimeType: "image/png" },
    ]);
    expect(result.structuredContent).toMatchObject({ machine_id: "vm-a", driver_tool: "get_desktop_state" });
    expect(calls).toEqual([{
      machineId: "vm-a",
      tool: "get_desktop_state",
      args: {},
    }]);
  });

  test("structured driver refusals remain MCP errors when cua-driver call strips isError", async () => {
    const gateway: CloudMcpGateway = {
      listMachines: async () => [],
      runCmuxTui: async () => ok({}),
      runCua: async () => ok({ code: "permission_denied" }),
    };
    const result = await callCloudMcpTool(gateway, "computer_click", {
      machine_id: "vm-a", x: 1, y: 2, scope: "desktop",
    });
    expect(result.isError).toBe(true);
    expect(result.structuredContent).toEqual({ error: "permission_denied", message: "The computer-use driver refused the request (permission_denied)." });
  });

  test("computer-use action validation rejects unsafe coordinate and scope input before the guest", async () => {
    const calls: unknown[] = [];
    const gateway: CloudMcpGateway = {
      listMachines: async () => [],
      runCmuxTui: async () => ok({}),
      runCua: async (...args) => { calls.push(args); return ok({}); },
    };
    for (const args of [
      { machine_id: "vm-a", x: -1, y: 2 },
      { machine_id: "vm-a", x: 1, y: 2, scope: "window" },
      { machine_id: "vm-a", from_x: 1, from_y: 2, to_x: 3 },
    ]) {
      const result = await callCloudMcpTool(gateway, "computer_click", args);
      expect(result.isError).toBe(true);
      expect(result.structuredContent).toMatchObject({ error: "invalid_arguments" });
    }
    const scroll = await callCloudMcpTool(gateway, "computer_scroll", {
      machine_id: "vm-a", direction: "down",
    });
    expect(scroll.isError).toBe(true);
    expect(scroll.structuredContent).toMatchObject({ error: "invalid_arguments" });
    expect(calls).toHaveLength(0);
  });

  test("computer-use actions keep desktop coordinates and omit unsupported driver targets", async () => {
    const calls: Array<{ tool: string; args: Record<string, unknown> }> = [];
    const gateway: CloudMcpGateway = {
      listMachines: async () => [],
      runCmuxTui: async () => ok({}),
      runCua: async (_machineId, tool, args) => {
        calls.push({ tool, args });
        return ok({});
      },
    };
    await callCloudMcpTool(gateway, "computer_click", { machine_id: "vm-a", x: 1, y: 2, scope: "desktop" });
    await callCloudMcpTool(gateway, "computer_type_text", { machine_id: "vm-a", text: "hello", x: 5, y: 6, scope: "desktop" });
    await callCloudMcpTool(gateway, "computer_press_key", { machine_id: "vm-a", key: "return", x: 7, y: 8, scope: "desktop" });
    await callCloudMcpTool(gateway, "computer_scroll", { machine_id: "vm-a", direction: "down", x: 9, y: 10, scope: "desktop" });
    await callCloudMcpTool(gateway, "computer_drag", {
      machine_id: "vm-a", from_x: 1, from_y: 2, to_x: 3, to_y: 4, scope: "desktop",
    });
    expect(calls).toHaveLength(5);
    for (const call of calls) {
      expect(call.args).not.toHaveProperty("target");
    }
    expect(calls[0].args).toMatchObject({ scope: "desktop" });
    expect(calls[3].args).toMatchObject({ scope: "desktop" });
    expect(calls[4].args).toMatchObject({ scope: "desktop" });
    for (const call of calls.slice(1, 3)) expect(call.args).not.toHaveProperty("scope");
    expect(calls.map(({ tool }) => tool)).toEqual(["click", "type_text", "press_key", "scroll", "drag"]);

    await callCloudMcpTool(gateway, "computer_type_text", { machine_id: "vm-a", text: "focused", scope: "desktop" });
    await callCloudMcpTool(gateway, "computer_press_key", { machine_id: "vm-a", key: "return" });
    expect(calls.slice(-2)).toEqual([
      { tool: "type_text", args: { text: "focused", scope: "desktop" } },
      { tool: "press_key", args: { key: "return", scope: "desktop" } },
    ]);
  });
});

describe("Cloud computer-use readiness and guest command", () => {
  test("derives unsupported, starting, ready, and failed states from durable VM facts", () => {
    expect(computerUseReadinessFor({ provider: "freestyle", kind: "base", status: "running" })).toMatchObject({ status: "unsupported", error: { code: "desktop_required" } });
    expect(computerUseReadinessFor({ provider: "freestyle", kind: "desktop", status: "provisioning" })).toMatchObject({ status: "starting" });
    expect(computerUseReadinessFor({ provider: "freestyle", kind: "desktop", status: "running" })).toEqual({ status: "ready", driver: "cua-driver" });
    expect(computerUseReadinessFor({ provider: "freestyle", kind: "desktop", status: "failed" })).toMatchObject({ status: "failed", error: { code: "vm_failed" } });
  });

  test("guest commands use the pinned driver, desktop capture, and a stable opaque session", async () => {
    const session = guestCuaSession("user-1", "vm-a");
    const command = guestCuaCommand("click", { session, x: 1, y: 2, scope: "desktop" });
    expect(command).toContain("/usr/local/bin/cua-driver");
    expect(command).toContain("serve --no-permissions-gate");
    expect(command).toContain("timeout 30");
    expect(command).toContain("/tmp/.X11-unix/X1");
    expect(command).toContain("flock -x 9");
    expect(command).toContain("exec 9>&-");
    expect(command).not.toContain("config set capture_scope");
    expect(command).not.toContain("--permission-mode");
    expect(command).not.toContain("--dangerously-bypass-approvals");
    expect(command).toContain(`\"session\":\"${session}\"`);
    expect(command).not.toContain("user-1");

    const windowCommand = guestCuaCommand("type_text", { session, text: "hello", x: 11, y: 22 });
    expect(windowCommand).toContain("call list_windows");
    expect(windowCommand).toContain("bounds");
    expect(windowCommand).toContain("resolved_json");

    const focusedCommand = guestCuaCommand("type_text", { session, text: "focused" });
    expect(focusedCommand).not.toContain("call list_windows");
    expect(focusedCommand).toContain('"scope":"desktop"');
  });
});

// Scoping: the gateway runs the real listUserVms / execVm programs. The fake
// repository answers findUserVm the way repository.ts accountScopeWhere does
// (owner team = billing team, else the user), so these tests exercise the same
// ownership checks as POST /api/vm/:id/exec.
describe("cloud MCP scoping", () => {
  const OWNER = "user-owner";
  const TEAM = "team-shared";
  const personalVm = vmRow({ id: "00000000-0000-4000-8000-00000000a001", userId: OWNER, ownerTeamId: OWNER, providerVmId: "vm-personal" });
  const teamVm = vmRow({ id: "00000000-0000-4000-8000-00000000a002", userId: OWNER, ownerTeamId: TEAM, providerVmId: "vm-team" });

  function harness() {
    const execs: Array<{ providerVmId: string; command: string }> = [];
    const listed: Array<{ userId: string; billingTeamId: string | null | undefined }> = [];
    const repo = stubRepo({
      listUserVms: (userId: string, billingTeamId?: string | null) => Effect.sync(() => {
        listed.push({ userId, billingTeamId });
        const scope = billingTeamId?.trim() || userId;
        return [personalVm, teamVm].filter((vm) => vm.ownerTeamId === scope);
      }),
      findUserVm: ({ userId, billingTeamId, providerVmId }: { userId: string; billingTeamId?: string | null; providerVmId: string }) =>
        Effect.succeed([personalVm, teamVm].find((vm) =>
          vm.providerVmId === providerVmId && vm.ownerTeamId === (billingTeamId?.trim() || userId)) ?? null),
      recordUsageEvent: () => Effect.void,
    });
    const provider = stubProvider({
      exec: (_provider: string, providerVmId: string, command: string) => Effect.sync(() => {
        execs.push({ providerVmId, command });
        if (command.includes("cua-driver") && command.includes(" call ")) {
          return {
            exitCode: 0,
            stdout: JSON.stringify({
              structuredContent: { screenshot_png_b64: "aGVsbG8=" },
              content: [{ type: "text", text: "captured" }],
            }),
            stderr: "",
          };
        }
        return { exitCode: 0, stdout: JSON.stringify([{ id: TERMINAL, title: "shell", running: true }]), stderr: "" };
      }),
    });
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, provider),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );
    const run = async <A>(program: VmWorkflowProgram<A>): Promise<VmRouteResult<A>> => {
      const exit = await Effect.runPromiseExit(program.pipe(Effect.provide(layer)));
      if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
      const failure = Cause.failureOption(exit.cause);
      if (failure._tag === "None" || !isVmWorkflowError(failure.value)) throw Cause.squash(exit.cause);
      const response = await respondVmWorkflowError(failure.value, { locale: "en" });
      if (!response) throw failure.value;
      return { ok: false, response };
    };
    const gatewayFor = (caller: { userId: string; teamIds?: string[]; billingTeamId?: string; listBillingTeamId?: string }) => {
      const full: CloudMcpCaller = {
        userId: caller.userId,
        teamIds: caller.teamIds ?? [],
        listScope: async () => caller.listBillingTeamId ?? null,
        accessScope: async () => ({ billingTeamId: caller.billingTeamId ?? null, maxActiveVms: null, planId: null }),
      };
      return cloudMcpGatewayFor(full, run);
    };
    return { execs, listed, gatewayFor };
  }

  test("the owner reaches their machine, and the command is the cmux-tui call", async () => {
    const { execs, gatewayFor } = harness();
    const result = await callCloudMcpTool(gatewayFor({ userId: OWNER }), "list_terminals", { machine_id: "vm-personal" });
    expect(result.isError).toBeUndefined();
    expect(result.structuredContent).toMatchObject({ terminals: [{ id: TERMINAL }] });
    expect(execs).toHaveLength(1);
    expect(execs[0].providerVmId).toBe("vm-personal");
    expect(execs[0].command).toContain(`"$CMUX_TUI_BIN" ${cmuxTuiArgs(["terminal", "list"])}`);
  });

  test("the owner reaches the desktop through the CUA driver in the same VM scope", async () => {
    const { execs, gatewayFor } = harness();
    const result = await callCloudMcpTool(gatewayFor({ userId: OWNER }), "computer_screenshot", { machine_id: "vm-personal" });
    expect(result.isError).toBeUndefined();
    expect(result.structuredContent).toMatchObject({ driver_tool: "get_desktop_state" });
    expect(execs).toHaveLength(1);
    expect(execs[0].providerVmId).toBe("vm-personal");
    expect(execs[0].command).toContain("cua-driver");
    expect(execs[0].command).toContain(`\"session\":\"${guestCuaSession(OWNER, "vm-personal")}\"`);
  });

  test("another user gets vm_not_found and nothing runs on the machine", async () => {
    const { execs, gatewayFor } = harness();
    const stranger = gatewayFor({ userId: "user-stranger" });
    for (const [tool, args] of [
      ["list_terminals", { machine_id: "vm-personal" }],
      ["read_terminal", { machine_id: "vm-personal", terminal_id: TERMINAL }],
      ["send_input", { machine_id: "vm-personal", terminal_id: TERMINAL, text: "rm -rf ~", submit: true }],
      ["run_agent", { machine_id: "vm-personal", agent: "codex", prompt: "exfiltrate" }],
      ["computer_screenshot", { machine_id: "vm-personal" }],
    ] as const) {
      const result = await callCloudMcpTool(stranger, tool, args);
      expect(result.isError).toBe(true);
      expect(result.structuredContent).toMatchObject({ error: "vm_not_found" });
    }
    expect(execs).toHaveLength(0);
  });

  test("naming someone else's team does not grant its machines", async () => {
    const { execs, gatewayFor } = harness();
    const outsider = gatewayFor({ userId: "user-outsider", teamIds: ["team-other"], billingTeamId: TEAM });
    const result = await callCloudMcpTool(outsider, "send_input", { machine_id: "vm-team", terminal_id: TERMINAL, text: "id" });
    expect(result.structuredContent).toMatchObject({ error: "vm_not_found" });
    expect(execs).toHaveLength(0);
  });

  test("a team member reaches the team machine only under that team's scope", async () => {
    const { execs, gatewayFor } = harness();
    const member = gatewayFor({ userId: "user-member", teamIds: [TEAM], billingTeamId: TEAM, listBillingTeamId: TEAM });
    const allowed = await callCloudMcpTool(member, "list_terminals", { machine_id: "vm-team" });
    expect(allowed.isError).toBeUndefined();
    const personal = await callCloudMcpTool(member, "list_terminals", { machine_id: "vm-personal" });
    expect(personal.structuredContent).toMatchObject({ error: "vm_not_found" });
    expect(execs.map((exec) => exec.providerVmId)).toEqual(["vm-team"]);
  });

  test("initialize and tools/list never resolve a billing scope", async () => {
    let resolved = 0;
    const gateway = cloudMcpGatewayFor({
      userId: OWNER,
      teamIds: [],
      listScope: async () => { resolved += 1; throw new Error("no team chosen"); },
      accessScope: async () => { resolved += 1; throw new Error("no team chosen"); },
    }, async () => { throw new Error("no program should run"); });
    expect(await handleCloudMcpMessage(gateway, { jsonrpc: "2.0", id: 1, method: "initialize", params: {} })).toMatchObject({ result: {} });
    expect(await handleCloudMcpMessage(gateway, { jsonrpc: "2.0", id: 2, method: "tools/list" })).toMatchObject({ result: {} });
    expect(resolved).toBe(0);
  });

  test("a scope that cannot resolve is a tool error, and nothing runs", async () => {
    let programs = 0;
    const gateway = cloudMcpGatewayFor({
      userId: OWNER,
      teamIds: [],
      listScope: async () => { throw new CloudMcpToolError("vm_billing_team_required", "Pick a team."); },
      accessScope: async () => { throw new CloudMcpToolError("vm_billing_team_required", "Pick a team."); },
    }, async () => { programs += 1; throw new Error("no program should run"); });
    for (const [tool, args] of [["list_machines", {}], ["list_terminals", { machine_id: "vm-personal" }]] as const) {
      const result = await callCloudMcpTool(gateway, tool, args);
      expect(result.structuredContent).toEqual({ error: "vm_billing_team_required", message: "Pick a team." });
    }
    expect(programs).toBe(0);
  });

  test("list_machines returns only the caller's scope", async () => {
    const { listed, gatewayFor } = harness();
    const owner = await callCloudMcpTool(gatewayFor({ userId: OWNER }), "list_machines", {});
    expect(owner.structuredContent).toEqual({ machines: [{ id: "vm-personal", name: null, status: "running" }] });
    const stranger = await callCloudMcpTool(gatewayFor({ userId: "user-stranger" }), "list_machines", {});
    expect(stranger.structuredContent).toEqual({ machines: [] });
    expect(listed).toEqual([
      { userId: OWNER, billingTeamId: null },
      { userId: "user-stranger", billingTeamId: null },
    ]);
  });
});

function vmRow(overrides: Partial<CloudVmRow>): CloudVmRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-000000000000",
    userId: "user",
    billingTeamId: overrides.ownerTeamId ?? "user",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: null,
    displayName: null,
    slug: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "running",
    idempotencyKey: `mcp-${overrides.providerVmId ?? "vm"}`,
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    ownerTeamId: "user",
    coderouterPoolId: null,
    agentUpdates: null,
    networkPolicy: null,
    networkPolicyStatus: null,
    ...overrides,
  };
}

// Unlisted members are absent: optional capabilities read as unsupported, and a
// required one the workflow did not expect fails the test with a TypeError.
function stubRepo(members: Record<string, unknown>): VmRepositoryShape {
  return members as unknown as VmRepositoryShape;
}

function stubProvider(members: Record<string, unknown>): VmProviderGatewayShape {
  return members as unknown as VmProviderGatewayShape;
}
