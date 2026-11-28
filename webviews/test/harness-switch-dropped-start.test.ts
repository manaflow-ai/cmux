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

// Leo, 2026-11-12, after a reboot: "if we do the recovery needs to be a lot better and it shouldn't
// talk so much bullshit". A start whose connection to acpmux went down before the pane noticed the
// drop failed the switch with "cmux lost its connection to the agent service while starting Claude
// Code. Try again, and if it keeps happening, quit and reopen cmux to reconnect." and a Retry
// button. A lost connection is nothing the person can fix: the switch keeps its prompt and starts
// again by itself.
for (const code of ["transport.closed", "native.not_connected", "transport.connect_failed"]) {
  test(`a start refused with ${code} on the same client never fails and starts again by itself`, async () => {
    const harnessSwitch = new HarnessSwitch();
    const restored: string[] = [];
    harnessSwitch.setHandlers({ restore: (text) => restored.push(text) });
    let calls = 0;
    const opened: string[] = [];
    harnessSwitch.connect(
      port(async () => {
        calls += 1;
        if (calls === 1) throw Object.assign(new Error("connection closed"), { code });
        return "s2";
      }, opened),
    );
    const started = harnessSwitch.switchTo("claude", "/Users/leo/Projects");
    await settle();
    expect(harnessSwitch.view().intent?.phase).toBe("starting");
    expect(harnessSwitch.view().intent?.error).toBeUndefined();
    expect(restored).toEqual([]);
    await expect(started).resolves.toBe("s2");
    expect(calls).toBe(2);
    expect(opened).toEqual(["s2"]);
  });
}

test("a start lost with its connection runs on the next client when a reconnect comes first", async () => {
  const harnessSwitch = new HarnessSwitch();
  const first = port(async () => {
    throw Object.assign(new Error("connection closed"), { interrupted: true });
  });
  harnessSwitch.connect(first);
  const started = harnessSwitch.switchTo("codex", "/Users/leo/Projects");
  await settle();
  expect(harnessSwitch.view().intent?.phase).toBe("starting");
  const opened: string[] = [];
  harnessSwitch.disconnect(first);
  harnessSwitch.connect(port(async () => "s3", opened));
  await expect(started).resolves.toBe("s3");
  expect(opened).toEqual(["s3"]);
});

test("a start the agent itself refuses still fails and says so", async () => {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(
    port(async () => {
      throw Object.assign(new Error("spawn claude-agent-acp ENOENT"), { code: "spawn.failed" });
    }),
  );
  void harnessSwitch.switchTo("claude", "/Users/leo/Projects");
  await settle();
  expect(harnessSwitch.view().intent?.phase).toBe("failed");
});
