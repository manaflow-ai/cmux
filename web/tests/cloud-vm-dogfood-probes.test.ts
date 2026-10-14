import { expect, test } from "bun:test";
import { runAgentProbes } from "../scripts/cloud-vm/dogfood-probes.mjs";

function harness({ failReads = false, echoOnly = false } = {}) {
  let now = 0;
  let event = "";
  let screen = "";
  const calls: string[] = [];
  const steps: string[] = [];
  const notes: string[] = [];
  const terminal = "term_00000000000000000000000000000001";
  return {
    calls, steps, notes,
    runtime: {
      localSocket: "/tmp/dogfood-test.sock", terminal, marker: "dogfood-test",
      now: () => now,
      sleep: async (milliseconds: number) => { now += milliseconds; },
      note: (message: string) => { notes.push(message); },
      timed: async (name: string, work: () => Promise<unknown>) => {
        steps.push(name);
        now = 0;
        return work();
      },
      typeLine: async (_terminal: string, line: string) => {
        calls.push(line);
        event = line.includes("--event Stop") ? "idle" : "working";
        if (line.includes("hook status")) {
          screen = echoOnly ? line : `dogfood-test-hooks-claude:installed\ndogfood-test-hooks-codex:missing\ndogfood-test-hooks-done`;
        }
      },
      waitForScreen: async (_socket: string, _terminal: string, pattern: string, timeout: number) => {
        if (!new RegExp(pattern, "m").test(screen)) {
          now += timeout;
          throw new Error("screen wait timed out");
        }
      },
      runTui: async (argv: string[], timeout: number) => {
        const command = argv.join(" ");
        calls.push(command);
        if (failReads) {
          now += timeout;
          return { code: 1, stdout: "", stderr: "host unavailable" };
        }
        if (command.includes("screen read")) return { code: 0, stdout: screen, stderr: "" };
        if (command.includes("agent list")) return {
          code: 0,
          stdout: JSON.stringify([{ terminal_id: terminal, source: "hook", state: event }]),
          stderr: "",
        };
        return { code: 0, stdout: JSON.stringify([{ title: "dogfood-test" }]), stderr: "" };
      },
    },
  };
}

test("observes both hook providers and public CLI agent states", async () => {
  const { runtime } = harness();
  const result = await runAgentProbes(runtime);
  expect(result.agentHooks.providers).toEqual({
    claude: { installed: true, state: "installed" },
    codex: { installed: false, state: "missing" },
  });
  expect(result.agentStatusWorking.ok).toBe(true);
  expect(result.agentStatusWorking.statesSeen).toEqual(["working"]);
  expect(result.agentStatusIdle.ok).toBe(true);
  expect(result.agentStatusIdle.statesSeen).toEqual(["idle"]);
  expect(result.notifyReachesHost.ok).toBe(true);
});

test("waits for executed hook output rather than the echoed command", async () => {
  const { runtime } = harness({ echoOnly: true });
  const result = await runAgentProbes(runtime);
  expect(result.agentHooks.ok).toBe(false);
  expect(result.agentHooks.elapsedMs).toBe(30_000);
});

test("records deadline failures and continues every probe", async () => {
  const { runtime, steps, notes } = harness({ failReads: true });
  const result = await runAgentProbes(runtime);
  expect(steps).toEqual(["agentHooks", "agentStatusWorking", "agentStatusIdle", "notifyReachesHost"]);
  expect(notes).toHaveLength(4);
  for (const probe of Object.values(result)) {
    expect(probe.ok).toBe(false);
    expect(probe.elapsedMs).toBeLessThanOrEqual(30_000);
    expect(probe.lastSeen).not.toBeNull();
  }
});
