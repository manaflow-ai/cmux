import { describe, expect, test } from "bun:test";

import {
  CloudVmRunAdapter,
  CloudVmRunAdapterError,
  prepareCloudVmRunAttempt,
  type CloudVmRunAttemptSpec,
} from "../services/vms/cloudVmRunAdapter";

type ExecResult = { exitCode: number; stdout: string; stderr: string };

const attempt: CloudVmRunAttemptSpec = {
  runId: "run_01",
  attemptId: "attempt_01",
  index: 0,
  vmId: "vm_01",
  agent: "codex",
  prompt: "Review 'quoted' input; do not run arbitrary shell",
  cwd: "/work/repo",
  lease: { leaseId: "lease_01", leaseEpoch: 2 },
};

const value = (body: Record<string, unknown>): ExecResult => ({
  exitCode: 0,
  stdout: JSON.stringify({ value: body }),
  stderr: "",
});

describe("cloud VM Run adapter", () => {
  test("builds a fixed direct-argv attempt and quotes prompt text", async () => {
    const prepared = prepareCloudVmRunAttempt(attempt);
    const commands: string[] = [];
    const adapter = new CloudVmRunAdapter({
      exec: async (_vmId, command) => {
        commands.push(command);
        return commands.length === 1 ? value({ workspace_id: "ws_1" }) : value({ terminal_id: "term_1" });
      },
    });
    const ref = await adapter.start(prepared);
    expect(ref.workspaceId).toBe("ws_1");
    expect(ref.terminalId).toBe("term_1");
    expect(() => adapter.assertLease(ref, { leaseId: "lease_old", leaseEpoch: 1 })).toThrow("no longer current");
    expect(() => adapter.assertLease(ref, { leaseId: "lease_01", leaseEpoch: 2 })).not.toThrow();
    expect(commands[0]).toContain("workspace create --empty");
    expect(commands[0]).toContain("--correlation-key 'cmux-run:run_01:attempt_01:workspace'");
    expect(commands[1]).toContain("--correlation-key 'cmux-run:run_01:attempt_01:terminal'");
    expect(commands[1]).toContain("-- '/usr/local/bin/cmux' agent 'codex' -- 'Review '\\\''quoted'\\\'' input; do not run arbitrary shell'");
    expect(commands[1]).not.toContain("sh -c");
  });

  test("uses daemon correlation keys so a lost start response replays", async () => {
    const prepared = prepareCloudVmRunAttempt(attempt);
    let terminalStarts = 0;
    const adapter = new CloudVmRunAdapter({
      exec: async (_vmId, command) => {
        if (command.includes("workspace create")) {
          return value({ workspace_id: "ws_1", replayed: terminalStarts > 0 });
        }
        terminalStarts += 1;
        return value({ terminal_id: "term_1", replayed: terminalStarts > 1 });
      },
    });
    const first = await adapter.start(prepared);
    const second = await adapter.start(prepared);
    expect(first.terminalId).toBe(second.terminalId);
    expect(first.replayed).toBe(false);
    expect(second.replayed).toBe(true);
    expect(terminalStarts).toBe(2);
  });

  test("maps terminal exit receipts and rejects a different terminal", async () => {
    const prepared = prepareCloudVmRunAttempt(attempt);
    const adapter = new CloudVmRunAdapter({
      exec: async (_vmId, command) => {
        if (command.includes("workspace create")) return value({ workspace_id: "ws_1" });
        if (command.includes("workspace 'ws_1' run")) return value({ terminal_id: "term_1" });
        return value({ terminal_id: "term_1", state: "exited", outcome: { kind: "exit", code: 0 } });
      },
    });
    const ref = await adapter.start(prepared);
    await expect(adapter.readReceipt(ref, 1000)).resolves.toEqual({ terminalId: "term_1", status: "succeeded", exitCode: 0 });
    const mismatched = { ...ref, terminalId: "term_other" };
    await expect(adapter.readReceipt(mismatched, 1000)).rejects.toMatchObject({ code: "receipt_mismatch" });
  });

  test("keeps a signalled terminal failure distinct from explicit cancellation", async () => {
    const prepared = prepareCloudVmRunAttempt(attempt);
    let waits = 0;
    const adapter = new CloudVmRunAdapter({
      exec: async (_vmId, command) => {
        if (command.includes("workspace create")) return value({ workspace_id: "ws_1" });
        if (command.includes("workspace 'ws_1' run")) return value({ terminal_id: "term_1" });
        waits += 1;
        return value({ terminal_id: "term_1", state: "exited", outcome: { kind: waits === 1 ? "signal" : "exit", signal: 9, code: 1 } });
      },
    });
    const ref = await adapter.start(prepared);
    await expect(adapter.readReceipt(ref)).resolves.toMatchObject({ status: "failed", signal: 9 });
    await expect(adapter.readReceipt(ref)).resolves.toMatchObject({ status: "failed", exitCode: 1 });
  });

  test("replays output from a cursor and fails closed on a cursor gap", async () => {
    const prepared = prepareCloudVmRunAttempt(attempt);
    let outputCalls = 0;
    const adapter = new CloudVmRunAdapter({
      exec: async (_vmId, command) => {
        if (command.includes("workspace create")) return value({ workspace_id: "ws_1" });
        if (command.includes("workspace 'ws_1' run")) return value({ terminal_id: "term_1" });
        if (command.includes("output read")) {
          outputCalls += 1;
          return value({ terminal_id: "term_1", text: outputCalls === 1 ? "one\\n" : "two\\n", start_offset: outputCalls === 1 ? 0 : 4, next_offset: outputCalls === 1 ? 4 : 8, complete: outputCalls > 1 });
        }
        return value({ terminal_id: "term_1", state: "exited", outcome: { kind: "exit", code: 0 } });
      },
    });
    const ref = await adapter.start(prepared);
    await expect(adapter.readOutput(ref, 0)).resolves.toMatchObject({ text: "one\\n", startOffset: 0, nextOffset: 4 });
    await expect(adapter.readOutput(ref, 4)).resolves.toMatchObject({ text: "two\\n", startOffset: 4, nextOffset: 8 });
    const gap = { ...ref };
    const gapAdapter = new CloudVmRunAdapter({
      exec: async (_vmId, command) => command.includes("output read")
        ? value({ terminal_id: "term_1", text: "wrong\\n", start_offset: 5, next_offset: 10, complete: true })
        : value({ workspace_id: "ws_1" }),
    });
    await expect(gapAdapter.readOutput(gap, 0)).rejects.toMatchObject({ code: "replay_gap" });
  });

  test("bridges output and the durable terminal receipt into replayable events", async () => {
    const prepared = prepareCloudVmRunAttempt(attempt);
    let outputCalls = 0;
    let waitCalls = 0;
    const adapter = new CloudVmRunAdapter({
      exec: async (_vmId, command) => {
        if (command.includes("workspace create")) return value({ workspace_id: "ws_1" });
        if (command.includes("workspace 'ws_1' run")) return value({ terminal_id: "term_1" });
        if (command.includes("output read")) {
          outputCalls += 1;
          return value(outputCalls === 1
            ? { terminal_id: "term_1", text: "done\\n", start_offset: 0, next_offset: 5, complete: true }
            : { terminal_id: "term_1", text: "", start_offset: 5, next_offset: 5, complete: true });
        }
        waitCalls += 1;
        return value(waitCalls === 1
          ? { terminal_id: "term_1", state: "pending" }
          : { terminal_id: "term_1", state: "exited", outcome: { kind: "exit", code: 0 } });
      },
    });
    const ref = await adapter.start(prepared);
    const events = [];
    for await (const event of adapter.events(ref)) events.push(event);
    expect(events).toEqual([
      { kind: "output", eventId: "attempt_01:output:0", seq: 20, payload: { text: "done\\n", startOffset: 0, nextOffset: 5 } },
      { kind: "state", eventId: "attempt_01:state:running", seq: 21, payload: { terminalId: "term_1", status: "running" } },
      { kind: "state", eventId: "attempt_01:state:succeeded", seq: 22, payload: { terminalId: "term_1", status: "succeeded", exitCode: 0 } },
    ]);
    expect(waitCalls).toBe(2);
  });

  test("rejects unsupported agents and malformed lease-shaped input", () => {
    expect(() => prepareCloudVmRunAttempt({ ...attempt, agent: "shell" as never })).toThrow(CloudVmRunAdapterError);
    expect(() => prepareCloudVmRunAttempt({ ...attempt, index: -1 })).toThrow("attempt index");
  });
});

