import { expect, test } from "bun:test";
import { HarnessSwitch, START_DEADLINE_MS, type SwitchClock, type SwitchPort } from "../harnessSwitch";
import { startThenSend } from "./firstSend";

/// A port whose agent starts at once; records what the switch asked of it.
function recordingPort(calls: string[], create: SwitchPort["create"] = async (harness) => `${harness}-session`) {
  let shownId: string | undefined;
  const port: SwitchPort = {
    turnRunning: () => false,
    shown: () => (shownId ? { sessionId: shownId, empty: true } : undefined),
    create: async (harness, cwd, model) => {
      calls.push(`create ${harness} ${cwd} ${model ?? ""}`.trim());
      return create(harness, cwd, model);
    },
    leave: () => undefined,
    open: async (sessionId) => {
      calls.push(`open ${sessionId}`);
      shownId = sessionId;
      return sessionId;
    },
    send: async (text) => {
      calls.push(`send ${text}`);
    },
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: (sessionId) => calls.push(`discard ${sessionId}`),
    prewarm: () => undefined,
    prewarmSupported: () => false,
  };
  return port;
}

const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

// cmux#55755: an Antigravity chat picked from the composer's chips, then sent from a chat with a
// project folder. The pick is a deferred switch; the send's chat.new (the same harness and folder)
// answers that switch's start, which resolves only once a prompt reaches it.
test("a first send after a chip pick reaches the agent instead of waiting on its own start", async () => {
  const calls: string[] = [];
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(recordingPort(calls));
  void harnessSwitch.switchTo("antigravity", "/work", { deferred: true, model: "gemini-4-hydrogen" });
  await settle();
  expect(harnessSwitch.view().intent?.phase).toBe("waiting");

  const start = () => harnessSwitch.switchTo("antigravity", "/work", { model: "gemini-4-hydrogen" });
  const send = () => harnessSwitch.send("hello agy") ?? Promise.reject(new Error("no switch held it"));
  await startThenSend(start, send, true);

  expect(calls).toEqual(["create antigravity /work gemini-4-hydrogen", "open antigravity-session", "send hello agy"]);
});

test("waiting for a held pick's start before sending never sends (the deadlock the fix avoids)", async () => {
  const calls: string[] = [];
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(recordingPort(calls));
  void harnessSwitch.switchTo("antigravity", "/work", { deferred: true });
  await settle();

  let sent = false;
  void startThenSend(
    () => harnessSwitch.switchTo("antigravity", "/work"),
    async () => {
      sent = true;
      return harnessSwitch.send("hello agy");
    },
    false,
  );
  await settle();
  expect(sent).toBe(false);
  expect(calls).toEqual(["create antigravity /work"]);
  harnessSwitch.cancel();
});

test("without a held pick the start comes before the prompt", async () => {
  const order: string[] = [];
  await startThenSend(
    async () => {
      await settle();
      order.push("start");
    },
    async () => order.push("send"),
    false,
  );
  expect(order).toEqual(["start", "send"]);
});

/// A clock whose timers run only when the test says so.
function manualClock() {
  const timers: { at: number; run: () => void; live: boolean }[] = [];
  let now = 0;
  const clock: SwitchClock = {
    now: () => now,
    schedule: (run, ms) => {
      const timer = { at: now + ms, run, live: true };
      timers.push(timer);
      return () => (timer.live = false);
    },
  };
  const advance = (ms: number) => {
    now += ms;
    for (const timer of timers) {
      if (timer.live && timer.at <= now) {
        timer.live = false;
        timer.run();
      }
    }
  };
  return { clock, advance };
}

test("a start that never answers fails with Retry and hands the prompt back; its late session is discarded", async () => {
  const calls: string[] = [];
  let answer: (id: string) => void = () => undefined;
  const { clock, advance } = manualClock();
  const harnessSwitch = new HarnessSwitch(clock);
  harnessSwitch.connect(
    recordingPort(calls, () => new Promise<string | undefined>((resolve) => (answer = (id) => resolve(id)))),
  );
  const restored: string[] = [];
  harnessSwitch.setHandlers({ restore: (text) => restored.push(text) });

  void harnessSwitch.switchTo("antigravity", "/work", { deferred: true });
  const sent = harnessSwitch.send("hello agy");
  let refusal: unknown;
  void sent?.catch((error: unknown) => (refusal = error));
  await settle();

  advance(START_DEADLINE_MS - 1);
  await settle();
  expect(harnessSwitch.view().intent?.phase).not.toBe("failed");

  advance(1);
  await settle();
  const intent = harnessSwitch.view().intent;
  expect(intent?.phase).toBe("failed");
  expect(intent?.error).toContain("Antigravity");
  expect(restored).toEqual(["hello agy"]);
  expect(refusal).toBeInstanceOf(Error);

  // acpmux answers long after: nobody uses that session, and nothing is sent to it.
  answer("late-session");
  await settle();
  expect(calls).toEqual(["create antigravity /work", "discard late-session"]);
  expect(harnessSwitch.view().intent?.phase).toBe("failed");
});
