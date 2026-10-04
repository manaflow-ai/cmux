import { describe, expect, test } from "bun:test";
import { HarnessProfiles } from "./harnessProfiles";
import { applySwitch, HarnessSwitch, PREWARM_DEBOUNCE_MS, type SwitchClock, type SwitchPort } from "./harnessSwitch";
import { paneHeader, type AcpmuxSnapshot } from "./model";

type Deferred<T> = { promise: Promise<T>; resolve(value: T): void; reject(error: unknown): void };
function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
}
const settle = async () => {
  for (let pass = 0; pass < 6; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

/// A client whose session/new replies the test releases, recording every call in order.
class FakePort implements SwitchPort {
  calls: string[] = [];
  creates: { harness: string; reply: Deferred<string | undefined> }[] = [];
  sent: { text: string; promptId: string }[] = [];
  running = false;
  cwds: (string | undefined)[] = [];
  session: { sessionId: string; harness?: string; empty: boolean; cwd?: string } | undefined = {
    sessionId: "claude-1",
    harness: "claude",
    empty: false,
  };
  openFails?: Error;
  turnRunning = () => this.running;
  shown = () => this.session;
  create = (harness: string, cwd?: string) => {
    this.calls.push(`create ${harness}`);
    this.cwds.push(cwd);
    const reply = deferred<string | undefined>();
    this.creates.push({ harness, reply });
    return reply.promise;
  };
  leave = () => {
    this.calls.push("leave");
    this.session = undefined;
  };
  open = async (sessionId: string) => {
    this.calls.push(`open ${sessionId}`);
    if (this.openFails) throw this.openFails;
    this.session = { sessionId, harness: sessionId.split("-")[0], empty: true };
    return sessionId;
  };
  send = async (text: string, _attachments: unknown, promptId: string) => {
    this.calls.push(`send ${text}`);
    this.sent.push({ text, promptId });
    return "sent";
  };
  setModel = async (model: string) => {
    this.calls.push(`model ${model}`);
  };
  setMode = async (mode: string) => {
    this.calls.push(`mode ${mode}`);
  };
  setConfig = async (id: string, value: string) => {
    this.calls.push(`config ${id}=${value}`);
  };
  discard = (sessionId: string) => {
    this.calls.push(`discard ${sessionId}`);
  };
  prewarm = (harness: string) => {
    this.calls.push(`prewarm ${harness}`);
  };
}

/// Time the test moves by hand.
class FakeClock implements SwitchClock {
  time = 0;
  timers: { at: number; run(): void; cancelled: boolean }[] = [];
  now = () => this.time;
  schedule = (run: () => void, ms: number) => {
    const timer = { at: this.time + ms, run, cancelled: false };
    this.timers.push(timer);
    return () => {
      timer.cancelled = true;
    };
  };
  advance(ms: number) {
    this.time += ms;
    for (const timer of this.timers.splice(0))
      if (timer.cancelled) continue;
      else if (timer.at <= this.time) timer.run();
      else this.timers.push(timer);
  }
}

const memoryStorage = () => {
  const map = new Map<string, string>();
  return {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
  } as unknown as Storage;
};

const CLAUDE_SNAPSHOT: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [{ id: "u1", version: 1, at: 1, kind: "user", text: "old chat" }],
  sessions: [],
  connection: "connected",
  sessionId: "claude-1",
  summary: { sessionId: "claude-1", harness: "claude", model: "opus", cwd: "/work" },
  isWorking: false,
  queue: [],
  catalog: [
    { id: "claude", name: "Claude Code", models: [{ id: "opus" }] },
    { id: "codex", name: "Codex", models: [{ id: "gpt-6-astra" }, { id: "gpt-6.1-sol" }] },
    { id: "opencode", name: "OpenCode", models: [{ id: "default" }] },
  ],
  canLoadOlder: false,
};

function setup(storage = memoryStorage()) {
  const clock = new FakeClock();
  const store = new HarnessSwitch(clock);
  const port = new FakePort();
  const restored: string[] = [];
  const opened: string[] = [];
  const notices: string[] = [];
  store.setHandlers({
    restore: (text) => restored.push(text),
    opened: (id) => opened.push(id),
    notice: (text) => notices.push(text),
  });
  store.connect(port);
  const profiles = new HarnessProfiles(() => storage);
  const draw = (raw: AcpmuxSnapshot = CLAUDE_SNAPSHOT) => applySwitch(raw, store.view(), raw.catalog, profiles);
  return { clock, store, port, restored, opened, notices, profiles, draw };
}

describe("harness switch: the pick draws in the frame it happens", () => {
  test("picker, composer and header show the new harness before acpmux answers, on a new chat", () => {
    const { store, port, profiles, draw } = setup();
    profiles.observe({
      sessionId: "codex-0",
      harness: "codex",
      model: "gpt-6.1-sol",
      modes: { availableModes: [{ id: "auto", name: "Auto" }], currentModeId: "auto" },
    });
    let notified = 0;
    store.subscribe(() => (notified += 1));
    void store.switchTo("codex");
    // Synchronous: no await between the pick and what the pane draws.
    expect(notified).toBe(1);
    const shown = draw();
    expect(shown.summary?.harness).toBe("codex");
    expect(shown.summary?.model).toBe("gpt-6.1-sol");
    expect(shown.summary?.modes?.currentModeId).toBe("auto");
    expect(paneHeader(shown).title).toBe("Codex");
    expect(shown.rows).toEqual([]);
    expect(shown.sessionId).toBeUndefined();
    expect(shown.switching).toEqual({ harness: "codex", name: "Codex", phase: "starting" });
    expect(port.calls).toEqual(["leave", "create codex"]);
  });

  test("the new chat starts in the shown chat's folder and draws it at once", () => {
    const { store, port, draw } = setup();
    port.session = { sessionId: "claude-1", harness: "claude", empty: false, cwd: "/work/app" };
    void store.switchTo("codex");
    void store.switchTo("opencode");
    expect(port.cwds).toEqual(["/work/app", "/work/app"]);
    expect(draw({ ...CLAUDE_SNAPSHOT, summary: undefined, sessionId: undefined, rows: [] }).summary?.cwd).toBe(
      "/work/app",
    );
  });

  test("without a profile, the catalog's first model stands in until the session reports", () => {
    const { store, draw } = setup();
    void store.switchTo("codex");
    expect(draw().summary?.model).toBe("gpt-6-astra");
  });
});

describe("harness switch: a prompt sent before the session is ready", () => {
  test("queues on the new chat with a quiet starting line, then goes out first, keeping its row", async () => {
    const { store, port, draw, opened } = setup();
    const done = store.switchTo("codex");
    const turn = store.send("hello codex");
    expect(turn).toBeDefined();
    const queued = draw().rows;
    expect(queued).toHaveLength(1);
    expect(queued[0]).toMatchObject({ kind: "user", text: "hello codex", pending: true, status: "Starting Codex…" });
    expect(port.sent).toEqual([]);
    port.creates[0]!.reply.resolve("codex-1");
    expect(await done).toBe("codex-1");
    expect(port.calls).toEqual(["leave", "create codex", "open codex-1", "send hello codex"]);
    // The sent prompt's optimistic row is the queued row's id, so it does not remount.
    expect(`local-${port.sent[0]!.promptId}`).toBe(queued[0]!.id);
    expect(await turn).toBe("sent");
    expect(opened).toEqual(["codex-1"]);
    expect(store.view().intent).toBeUndefined();
  });

  test("a model, mode and effort picked while it starts go to the new session before the prompt", async () => {
    const { store, port, draw } = setup();
    void store.switchTo("codex");
    expect(store.pickModel("gpt-6.1-sol")).toBeDefined();
    expect(store.pickMode("read-only")).toBe(true);
    expect(store.pickConfig("reasoning_effort", "high")).toBe(true);
    expect(draw().summary?.model).toBe("gpt-6.1-sol");
    void store.send("go");
    port.creates[0]!.reply.resolve("codex-1");
    await settle();
    expect(port.calls.slice(2)).toEqual([
      "open codex-1",
      "model gpt-6.1-sol",
      "mode read-only",
      "config reasoning_effort=high",
      "send go",
    ]);
  });

  test("with no prompt the switch opens the session and ends; Send then goes as usual", async () => {
    const { store, port } = setup();
    void store.switchTo("codex");
    port.creates[0]!.reply.resolve("codex-1");
    await settle();
    expect(store.view().intent).toBeUndefined();
    expect(store.send("later")).toBeUndefined();
  });
});

describe("harness switch: failure", () => {
  test("hands the queued prompt back to the composer, marks the harness, and Retry starts it again", async () => {
    const { store, port, draw, restored } = setup();
    const done = store.switchTo("opencode");
    const turn = store.send("hi opencode");
    port.creates[0]!.reply.reject(new Error("API key is missing"));
    expect(await done).toBeUndefined();
    await expect(turn!).rejects.toThrow("API key is missing");
    expect(restored).toEqual(["hi opencode"]);
    const shown = draw();
    expect(shown.switching).toEqual({
      harness: "opencode",
      name: "OpenCode",
      phase: "failed",
      error: "API key is missing",
    });
    expect(shown.rows).toEqual([]);
    store.retry();
    expect(port.calls.filter((call) => call.startsWith("create"))).toEqual(["create opencode", "create opencode"]);
    expect(draw().switching?.phase).toBe("starting");
  });

  // Data loss: a queued prompt's attachments must come back with its text, exactly as they were.
  test("a failed or cancelled queued prompt hands back its attachments with its text", async () => {
    const image = { id: "a1", kind: "image" as const, name: "shot.png", mimeType: "image/png", size: 3, data: "AAA" };
    const file = { id: "a2", kind: "text" as const, name: "notes.md", mimeType: "text/markdown", size: 2, text: "hi" };
    const { store, port } = setup();
    const handedBack: unknown[][] = [];
    store.setHandlers({ restore: (...args: unknown[]) => void handedBack.push(args) } as never);
    void store.switchTo("opencode");
    void store.send("with an image", [image])?.catch(() => undefined);
    void store.send("with a file", [file])?.catch(() => undefined);
    port.creates[0]!.reply.reject(new Error("boom"));
    await settle();
    expect(handedBack).toEqual([["with an image\n\nwith a file", [image, file]]]);
    void store.switchTo("codex");
    void store.send("cancel me", [file])?.catch(() => undefined);
    store.cancelQueued(store.view().intent!.queued[0]!.id);
    expect(handedBack[1]).toEqual(["cancel me", [file]]);
  });

  test("Send after a failure retries with that prompt queued", async () => {
    const { store, port } = setup();
    void store.switchTo("opencode");
    port.creates[0]!.reply.reject(new Error("boom"));
    await settle();
    void store.send("again");
    expect(port.creates).toHaveLength(2);
    port.creates[1]!.reply.resolve("opencode-2");
    await settle();
    expect(port.sent.map((prompt) => prompt.text)).toEqual(["again"]);
  });

  test("a session that will not open fails the same way", async () => {
    const { store, port, restored } = setup();
    port.openFails = new Error("attach refused");
    void store.switchTo("codex");
    void store.send("x")?.catch(() => undefined);
    port.creates[0]!.reply.resolve("codex-1");
    await settle();
    expect(store.view().intent?.phase).toBe("failed");
    expect(restored).toEqual(["x"]);
  });
});

describe("harness switch: a switch during a switch", () => {
  test("the last pick wins; the earlier session is discarded when it lands; queued prompts follow", async () => {
    const { store, port, draw } = setup();
    const first = store.switchTo("codex");
    void store.send("for the new chat");
    const second = store.switchTo("opencode");
    expect(draw().summary?.harness).toBe("opencode");
    expect(draw().rows[0]?.status).toBe("Starting OpenCode…");
    expect(await first).toBeUndefined();
    port.creates[0]!.reply.resolve("codex-1");
    await settle();
    expect(port.calls).toContain("discard codex-1");
    expect(port.calls).not.toContain("open codex-1");
    port.creates[1]!.reply.resolve("opencode-1");
    expect(await second).toBe("opencode-1");
    await settle();
    expect(port.sent.map((prompt) => prompt.text)).toEqual(["for the new chat"]);
  });

  test("picking back to the empty chat the pane left reuses it, with no session/new", async () => {
    const { store, port } = setup();
    port.session = { sessionId: "claude-1", harness: "claude", empty: true };
    void store.switchTo("codex");
    const back = store.switchTo("claude");
    expect(await back).toBe("claude-1");
    expect(port.calls).toEqual(["leave", "create codex", "open claude-1"]);
    port.creates[0]!.reply.resolve("codex-1");
    await settle();
    expect(port.calls).toContain("discard codex-1");
    expect(port.calls).not.toContain("discard claude-1");
  });

  test("the same pick twice is one switch", () => {
    const { store, port } = setup();
    void store.switchTo("codex");
    void store.switchTo("codex");
    expect(port.creates).toHaveLength(1);
  });
});

describe("harness switch: during a streaming turn", () => {
  test("applies to the next turn: the stream stays on screen until the next prompt opens the new chat", async () => {
    const { store, port, draw } = setup();
    port.running = true;
    const streaming = { ...CLAUDE_SNAPSHOT, isWorking: true };
    void store.switchTo("codex");
    let shown = draw(streaming);
    expect(shown.rows).toEqual(streaming.rows);
    expect(shown.sessionId).toBe("claude-1");
    expect(shown.isWorking).toBe(true);
    expect(shown.summary?.harness).toBe("codex");
    expect(shown.switching?.phase).toBe("deferred");
    expect(port.calls).toEqual(["create codex"]);
    port.creates[0]!.reply.resolve("codex-1");
    await settle();
    // Ready, and still waiting: nothing cut the stream.
    expect(port.calls).toEqual(["create codex"]);
    expect(store.view().intent?.phase).toBe("waiting");
    void store.send("next turn");
    shown = draw(streaming);
    expect(shown.rows.map((row) => row.text)).toEqual(["next turn"]);
    await settle();
    expect(port.calls).toEqual(["create codex", "leave", "open codex-1", "send next turn"]);
  });

  test("picking the streaming session's own harness again drops the pending switch", async () => {
    const { store, port } = setup();
    port.running = true;
    void store.switchTo("codex");
    expect(await store.switchTo("claude")).toBe("claude-1");
    expect(store.view().intent).toBeUndefined();
    port.creates[0]!.reply.resolve("codex-1");
    await settle();
    expect(port.calls).toContain("discard codex-1");
  });
});

describe("harness switch: reconnect", () => {
  test("a dropped connection is not a failure: the next client runs the switch and sends the prompt", async () => {
    const { store, port, restored } = setup();
    void store.switchTo("codex");
    const turn = store.send("survives");
    store.disconnect(port);
    port.creates[0]!.reply.reject(new Error("The agent connection was interrupted."));
    await settle();
    expect(store.view().intent?.phase).toBe("starting");
    expect(restored).toEqual([]);
    const next = new FakePort();
    store.connect(next);
    expect(next.calls).toEqual(["create codex"]);
    next.creates[0]!.reply.resolve("codex-2");
    await settle();
    expect(next.sent.map((prompt) => prompt.text)).toEqual(["survives"]);
    expect(await turn).toBe("sent");
  });

  test("a switch picked while disconnected waits for the client", () => {
    const store = new HarnessSwitch(new FakeClock());
    void store.switchTo("codex");
    const port = new FakePort();
    port.session = undefined;
    store.connect(port);
    expect(port.calls).toEqual(["create codex"]);
  });
});

describe("harness switch: cancel and model picks", () => {
  test("selecting another session cancels the switch and hands the queued prompt back", async () => {
    const { store, port, restored } = setup();
    void store.switchTo("codex");
    const turn = store.send("not lost");
    store.cancel();
    expect(restored).toEqual(["not lost"]);
    await expect(turn!).rejects.toThrow();
    port.creates[0]!.reply.resolve("codex-1");
    await settle();
    expect(port.calls).toContain("discard codex-1");
  });

  test("Cancel on a queued prompt takes it back to the composer; the harness keeps starting", async () => {
    const { store, port, draw, restored } = setup();
    void store.switchTo("opencode");
    const first = store.send("keep me");
    void store.send("send me");
    const row = draw().rows[0]!;
    expect(row.queued).toBeDefined();
    store.cancelQueued(row.queued!);
    expect(restored).toEqual(["keep me"]);
    await expect(first!).rejects.toThrow();
    expect(draw().rows.map((candidate) => candidate.text)).toEqual(["send me"]);
    port.creates[0]!.reply.resolve("opencode-1");
    await settle();
    expect(port.sent.map((prompt) => prompt.text)).toEqual(["send me"]);
  });

  test("a model pick in a live session draws at once, then follows what the agent reports", async () => {
    const { store, port, draw } = setup();
    void store.pickModel("sonnet", { sessionId: "claude-1", model: "opus" });
    expect(port.calls).toEqual(["model sonnet"]);
    const shown = draw();
    expect(shown.summary?.model).toBe("sonnet");
    expect(shown.summary?.confirmedModel).toBe("opus");
    const reported = { ...CLAUDE_SNAPSHOT, summary: { ...CLAUDE_SNAPSHOT.summary!, model: "haiku" } };
    expect(draw(reported).summary?.model).toBe("haiku");
  });

  test("a model the agent refuses reverts and says why", async () => {
    const { store, port, draw, notices } = setup();
    port.setModel = async () => {
      throw new Error("not on this plan");
    };
    await store.pickModel("sonnet", { sessionId: "claude-1", model: "opus" });
    expect(draw().summary?.model).toBe("opus");
    expect(notices).toEqual(["Couldn't switch to sonnet: not on this plan"]);
  });
});

describe("harness switch: prewarm hints", () => {
  test("debounced, one per harness per window, never for the harness on screen", () => {
    const { store, port, clock } = setup();
    store.hint("codex");
    store.hint("opencode");
    clock.advance(PREWARM_DEBOUNCE_MS);
    expect(port.calls).toEqual(["prewarm opencode"]);
    store.hint(undefined);
    store.hint("opencode");
    clock.advance(PREWARM_DEBOUNCE_MS);
    expect(port.calls).toEqual(["prewarm opencode"]);
    store.hint("claude");
    clock.advance(PREWARM_DEBOUNCE_MS);
    expect(port.calls).toEqual(["prewarm opencode"]);
    store.hint("codex");
    store.hint(undefined);
    clock.advance(PREWARM_DEBOUNCE_MS);
    expect(port.calls).toEqual(["prewarm opencode"]);
    expect(clock.timers.filter((timer) => !timer.cancelled)).toEqual([]);
  });
});
