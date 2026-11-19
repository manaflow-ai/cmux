import { expect, test } from "bun:test";
import { HarnessSwitch, type SwitchPort } from "../src/agent-session/acpmux/harnessSwitch";

// Leo, 2026-11-17, on a new chat in his NIGHTLY: "i also ran into this error jsut now when starting a
// chat!" The card read "Claude Code couldn't start." with Details "cmux did not start a session",
// while acpmux had started the session (codex-24, ready, never opened). The page's connection to
// acpmux dropped while `session/new` was out: the old client answers the start with no session
// (direct.ts startSession on a closed client), and the switch failed the chat on that answer,
// although a dropped connection is no failure and the next client runs the start again.

function port(create: SwitchPort["create"], opened: string[] = []): SwitchPort {
  return {
    turnRunning: () => false,
    shown: () => undefined,
    create,
    leave: () => undefined,
    open: async (sessionId) => {
      opened.push(sessionId);
      return sessionId;
    },
    send: async () => undefined,
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  };
}

async function settle(): Promise<void> {
  for (let i = 0; i < 10; i++) await Promise.resolve();
}

test("a start whose connection dropped while session/new was out runs again on the next client, never fails", async () => {
  const harnessSwitch = new HarnessSwitch();
  let answer: (sessionId: string | undefined) => void = () => undefined;
  const first = port(() => new Promise<string | undefined>((resolve) => (answer = resolve)));
  harnessSwitch.connect(first);
  const started = harnessSwitch.switchTo("claude", "/Users/leo/Projects/leo-workspace");
  await settle();
  expect(harnessSwitch.view().intent?.phase).toBe("starting");

  // The connection drops; the old client's start then answers with no session.
  harnessSwitch.disconnect(first);
  answer(undefined);
  await settle();
  expect(harnessSwitch.view().intent?.phase).not.toBe("failed");
  expect(harnessSwitch.view().intent?.error).toBeUndefined();

  // The next client runs the start and the chat opens.
  const opened: string[] = [];
  harnessSwitch.connect(port(async () => "s2", opened));
  await expect(started).resolves.toBe("s2");
  expect(opened).toEqual(["s2"]);
});

test("a start replaced by a reconnect before the old one answers opens on the new client", async () => {
  const harnessSwitch = new HarnessSwitch();
  let answer: (sessionId: string | undefined) => void = () => undefined;
  harnessSwitch.connect(port(() => new Promise<string | undefined>((resolve) => (answer = resolve))));
  const started = harnessSwitch.switchTo("codex", "/Users/leo/Projects");
  await settle();

  // A reconnect installs the new client with no disconnect in between (the page's own reconnect).
  const opened: string[] = [];
  harnessSwitch.connect(port(async () => "s2", opened));
  answer(undefined);
  await expect(started).resolves.toBe("s2");
});

test("a start the same connection answers with no session still fails and says so", async () => {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(port(async () => undefined));
  void harnessSwitch.switchTo("claude", "/Users/leo/Projects");
  await settle();
  expect(harnessSwitch.view().intent?.phase).toBe("failed");
});
