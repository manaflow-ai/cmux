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
    link: "connected",
    emitReason: "connected",
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

/** A port whose opened session runs `sonnet` in `default`, effort `high` (the old model's levels). */
function openedPort(calls: string[]): SwitchPort {
  let open = false;
  return {
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
              {
                id: "effort",
                category: "thought_level",
                currentValue: "high",
                options: [{ value: "low" }, { value: "high" }],
              },
            ],
          }
        : undefined,
    create: async () => "s1",
    open: async (sessionId) => {
      open = true;
      return sessionId;
    },
    send: async (text) => void calls.push(`send ${text}`),
    // The agent answers a model switch a few turns later than an option pick.
    setModel: async (model) => {
      for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
      calls.push(`model ${model}`);
    },
    setMode: async (mode) => void calls.push(`mode ${mode}`),
    setConfig: async (configId, value) => void calls.push(`config ${configId}=${value}`),
  };
}

test("a new chat's held model goes before its effort, which goes even when the old model did not list it", async () => {
  // A model switch resets an effort the new model lacks (cmux-codex-acp set_option): an effort that
  // landed first was reset, and the chat ran on the model's default level, not the one picked (Leo
  // 2026-11-17: picks "don't randomly change to other things").
  const calls: string[] = [];
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(openedPort(calls));
  const started = harnessSwitch.switchTo("claude", "/work", { model: "opus", options: { effort: "xhigh" } });
  harnessSwitch.pickMode("bypassPermissions");
  const sent = harnessSwitch.send("fix the tests");
  await started;
  await sent;
  expect(calls[0]).toBe("model opus");
  expect(calls.slice(1, 3).sort()).toEqual(["config effort=xhigh", "mode bypassPermissions"]);
  expect(calls[3]).toBe("send fix the tests");
});

test("the chips keep a new chat's held picks until its session reports them", async () => {
  // The switch ends (its prompt goes) once the agent answered each pick, before the session's own
  // report of them: the chips went from the pick back to the start value, then to the pick again.
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(openedPort([]));
  const started = harnessSwitch.switchTo("claude", "/work", { model: "opus", options: { effort: "xhigh" } });
  harnessSwitch.pickMode("bypassPermissions");
  const sent = harnessSwitch.send("fix the tests");
  await started;
  await sent;
  const reported = (model: string, mode: string, effort: string): AcpmuxSnapshot =>
    ({
      sessionId: "s1",
      rows: [],
      catalog: [],
      summary: {
        sessionId: "s1",
        turnCount: 1,
        harness: "claude",
        model,
        modes: { availableModes: [{ id: "default" }, { id: "bypassPermissions" }], currentModeId: mode },
        configOptions: [
          {
            id: "effort",
            category: "thought_level",
            currentValue: effort,
            options: [{ value: "low" }, { value: "high" }, { value: "xhigh" }],
          },
        ],
      },
    }) as unknown as AcpmuxSnapshot;
  const chips = (snapshot: AcpmuxSnapshot) => {
    const summary = applySwitch(snapshot, harnessSwitch.view()).summary!;
    return [summary.model, summary.modes?.currentModeId, summary.configOptions?.[0]?.currentValue];
  };
  // Before the session's report: the picks, not what the session started on.
  const before = reported("sonnet", "default", "high");
  harnessSwitch.reconcile(before);
  expect(chips(before)).toEqual(["opus", "bypassPermissions", "xhigh"]);
  // The report names them: nothing is left to draw over it.
  const after = reported("opus", "bypassPermissions", "xhigh");
  harnessSwitch.reconcile(after);
  expect(harnessSwitch.view().settling).toBeUndefined();
  expect(chips(after)).toEqual(["opus", "bypassPermissions", "xhigh"]);
  // A value set elsewhere later shows as it is.
  expect(chips(reported("opus", "default", "low"))).toEqual(["opus", "default", "low"]);
});

/// A port whose open answers undefined (a newer open of the same chat won, issue 44964) while the
/// chat is on screen, attached or not as `attached` says.
function supersededOpenPort(attached: boolean, calls: string[]): SwitchPort {
  let open = false;
  return {
    ...trustRefusingPort(),
    shown: () => (open ? { sessionId: "s1", harness: "claude", empty: true } : undefined),
    create: async () => "s1",
    open: async () => {
      open = true;
      return undefined;
    },
    attached: async (sessionId) => attached && open && sessionId === "s1",
    send: async (text) => void calls.push(`send ${text}`),
  };
}

test("an open a newer open of the same chat won still sends the first prompt to the chat on screen", async () => {
  const calls: string[] = [];
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(supersededOpenPort(true, calls));
  const started = harnessSwitch.switchTo("claude", "/work");
  const sent = harnessSwitch.send("fix the tests");
  expect(await started).toBe("s1");
  await sent;
  expect(calls).toEqual(["send fix the tests"]);
  expect(harnessSwitch.view().intent?.phase).not.toBe("failed");
});

test("an open that answers undefined with its chat not attached still fails", async () => {
  const calls: string[] = [];
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(supersededOpenPort(false, calls));
  const started = harnessSwitch.switchTo("claude", "/work");
  const sent = harnessSwitch.send("fix the tests");
  void sent?.catch(() => undefined);
  await started;
  expect(calls).toEqual([]);
  expect(harnessSwitch.view().intent?.phase).toBe("failed");
});

// cmux#45946: the session a pick on a sessionless page started, for the Cloud start that replaces it.
test("pickSession answers the session a deferred pick started, once its start settles", async () => {
  let answer: (id: string) => void = () => undefined;
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect({
    ...trustRefusingPort(),
    create: () => new Promise<string | undefined>((resolve) => (answer = (id) => resolve(id))),
  });
  expect(await harnessSwitch.pickSession(10)).toBeUndefined();
  void harnessSwitch.switchTo("codex", null, { deferred: true, model: "gpt-6.1-sol" });
  const picked = harnessSwitch.pickSession(5000);
  answer("codex-session");
  expect(await picked).toBe("codex-session");
  // Settled already: answered at once.
  expect(await harnessSwitch.pickSession(0)).toBe("codex-session");
  harnessSwitch.cancel();
  expect(await harnessSwitch.pickSession(0)).toBeUndefined();
});

test("pickSession gives up on a start that never answers, and answers none for a failed or Trust-held pick", async () => {
  const stuck = new HarnessSwitch();
  stuck.connect(startingPort());
  void stuck.switchTo("codex", null, { deferred: true });
  expect(await stuck.pickSession(20)).toBeUndefined();
  const trust = new HarnessSwitch();
  trust.connect(trustRefusingPort());
  void trust.switchTo("claude", "/work/untrusted", { deferred: true });
  await Promise.resolve();
  await Promise.resolve();
  expect(await trust.pickSession(1000)).toBeUndefined();
});

test("a mode picked on a harness comes back when the pane switches away and back to it", async () => {
  // agent-pane-picks-hold (real acpmux): Full access on Codex, Claude Code, back to Codex read "Mode".
  const calls: string[] = [];
  let shown: ReturnType<SwitchPort["shown"]>;
  let next = 0;
  const harnessOf = new Map<string, string>();
  const port: SwitchPort = {
    ...trustRefusingPort(),
    shown: () => shown,
    create: async (harness) => {
      const id = `s${++next}`;
      harnessOf.set(id, harness);
      return id;
    },
    open: async (sessionId) => {
      shown = { sessionId, harness: harnessOf.get(sessionId), modeId: "agent", empty: true, configOptions: [] };
      return sessionId;
    },
    setMode: async (mode) => void calls.push(`mode ${mode}`),
  };
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(port);
  void harnessSwitch.switchTo("codex", "/work");
  harnessSwitch.pickMode("agent-full-access");
  void harnessSwitch.switchTo("claude", "/work");
  const back = harnessSwitch.switchTo("codex", "/work");
  expect(await back).toBeDefined();
  expect(shown?.harness).toBe("codex");
  expect(calls).toEqual(["mode agent-full-access"]);
});
