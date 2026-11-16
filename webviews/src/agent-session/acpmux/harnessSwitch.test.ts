import { expect, test } from "bun:test";
import { applySwitch, HarnessSwitch, type SwitchPort } from "./harnessSwitch";
import type { AcpmuxSnapshot } from "./model";

const trustRefusal = Object.assign(new Error("trust.pending"), {
  reason: "trust.pending",
  cwd: "/work/untrusted",
});

function trustRefusingPort(): SwitchPort {
  return {
    turnRunning: () => false,
    shown: () => undefined,
    create: async () => {
      throw trustRefusal;
    },
    leave: () => undefined,
    open: async () => undefined,
    send: async () => undefined,
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  };
}

test("a blank deferred Return can leave New Tab while HarnessSwitch holds trust", async () => {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(trustRefusingPort());

  // This is the chat.new promise the New Tab submit observes. It must remain pending until Trust;
  // the blank-return branch clears the page synchronously rather than waiting for this promise.
  let settled = false;
  const started = harnessSwitch.switchTo("claude", "/work/untrusted", { deferred: true });
  void started.then(
    () => {
      settled = true;
    },
    () => {
      settled = true;
    },
  );
  await Promise.resolve();
  await Promise.resolve();

  expect(settled).toBe(false);
  expect(harnessSwitch.view().intent).toMatchObject({
    phase: "trust",
    harness: "claude",
    cwd: "/work/untrusted",
    shown: false,
  });
});

test("cancel drops a trust-waiting intent before folder-free recovery starts", async () => {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(trustRefusingPort());
  const restored: string[] = [];
  harnessSwitch.setHandlers({ restore: (text) => restored.push(text) });
  void harnessSwitch.switchTo("claude", "/work/untrusted");
  await Promise.resolve();
  await Promise.resolve();
  expect(harnessSwitch.view().intent?.phase).toBe("trust");
  harnessSwitch.cancel();
  expect(harnessSwitch.view().intent).toBeUndefined();
});

/// A port whose `session/new` never answers: the agent is still starting.
function startingPort(): SwitchPort {
  return { ...trustRefusingPort(), create: () => new Promise<string | undefined>(() => undefined) };
}

test("a prompt held while the agent starts reads as sent, and Stop hands every held prompt back", async () => {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(startingPort());
  const restored: string[] = [];
  harnessSwitch.setHandlers({ restore: (text) => restored.push(text) });
  void harnessSwitch.switchTo("claude", "/work");
  const first = harnessSwitch.send("fix the tests");
  const second = harnessSwitch.send("then lint");
  void first?.catch(() => undefined);
  void second?.catch(() => undefined);
  const raw = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "connected",
    origin: "local",
    isWorking: false,
    queue: [],
    catalog: [{ id: "claude", name: "Claude Code", models: [] }],
    canLoadOlder: false,
  } as unknown as AcpmuxSnapshot;
  const drawn = applySwitch(raw, harnessSwitch.view());
  const held = drawn.rows.filter((row) => row.queued !== undefined);
  expect(held).toHaveLength(2);
  // No "Starting Claude Code…" on them (Leo, 2026-11-01): the Thinking line under them covers it.
  expect(held.every((row) => row.status === undefined && row.pending === true)).toBe(true);
  expect(drawn.switching?.phase).toBe("starting");

  expect(harnessSwitch.cancelQueuedAll()).toBe(true);
  expect(restored).toEqual(["fix the tests\n\nthen lint"]);
  await expect(first).rejects.toMatchObject({ handedBack: true });
  // The agent keeps starting; nothing is left to hand back, so the next Stop stops the turn.
  expect(harnessSwitch.view().intent?.phase).toBe("starting");
  expect(harnessSwitch.cancelQueuedAll()).toBe(false);
});

test("a new chat's first prompt waits only on the picks its session does not already have", async () => {
  // Each pick is a round trip to the agent that the first prompt waits on, seconds apiece on a busy
  // Mac (Leo, 2026-11-05: "it thinks so so long..."): one the session started with is not sent.
  const calls: string[] = [];
  let open = false;
  const port: SwitchPort = {
    ...trustRefusingPort(),
    shown: () =>
      open
        ? {
            sessionId: "s1",
            harness: "claude",
            model: "opus",
            modeId: "default",
            empty: true,
            configOptions: [
              { id: "effort", category: "thought_level", currentValue: "high", options: [{ value: "high" }] },
              { id: "fast-mode", currentValue: "off", options: [{ value: "off" }, { value: "on" }] },
            ],
          }
        : undefined,
    create: async () => "s1",
    open: async (sessionId) => {
      open = true;
      return sessionId;
    },
    send: async (text) => void calls.push(`send ${text}`),
    setModel: async (model) => void calls.push(`model ${model}`),
    setMode: async (mode) => void calls.push(`mode ${mode}`),
    setConfig: async (configId, value) => void calls.push(`config ${configId}=${value}`),
  };
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(port);
  const started = harnessSwitch.switchTo("claude", "/work", {
    model: "opus",
    options: { effort: "high", "fast-mode": "on" },
  });
  harnessSwitch.pickMode("default");
  const sent = harnessSwitch.send("fix the tests");
  expect(await started).toBe("s1");
  await sent;
  expect(calls).toEqual(["config fast-mode=on", "send fix the tests"]);
});

test("a new chat still sends every pick its session differs on before the first prompt", async () => {
  // A model switch can reset effort, so the effort the old model reported is sent again too.
  const calls: string[] = [];
  let open = false;
  const port: SwitchPort = {
    ...trustRefusingPort(),
    shown: () =>
      open
        ? {
            sessionId: "s1",
            harness: "claude",
            model: "sonnet",
            modeId: "default",
            empty: true,
            configOptions: [
              { id: "effort", category: "thought_level", currentValue: "high", options: [{ value: "high" }] },
            ],
          }
        : undefined,
    create: async () => "s1",
    open: async (sessionId) => {
      open = true;
      return sessionId;
    },
    send: async (text) => void calls.push(`send ${text}`),
    setModel: async (model) => void calls.push(`model ${model}`),
    setMode: async (mode) => void calls.push(`mode ${mode}`),
    setConfig: async (configId, value) => void calls.push(`config ${configId}=${value}`),
  };
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(port);
  const started = harnessSwitch.switchTo("claude", "/work", { model: "opus", options: { effort: "high" } });
  harnessSwitch.pickMode("acceptEdits");
  const sent = harnessSwitch.send("fix the tests");
  await started;
  await sent;
  expect(calls.slice(0, 3).sort()).toEqual(["config effort=high", "mode acceptEdits", "model opus"]);
  expect(calls[3]).toBe("send fix the tests");
});
