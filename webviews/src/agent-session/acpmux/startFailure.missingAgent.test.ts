// A person without Claude Code or Codex installed who starts a chat gets one plain sentence and
// Install, never a dead end (Leo, 2026-11-11: "didn't have Claude or Codex installed, ran into
// bullshit, and then there was no recovery mechanism"). acpmux's spawn error names only the io
// error, the same for a missing CLI and a gone folder (cmux-tui acpmux recovery.rs `spawn_failed`);
// its typed `recovery` says which, and the start-failed card reads it.
import { expect, test } from "bun:test";
import { HarnessSwitch, type SwitchPort } from "./harnessSwitch";
import { startFailureView } from "./startFailure";
import type { Translate } from "./i18n";

const t: Translate = ((key: string, params?: Record<string, string>) =>
  `${key}${params ? JSON.stringify(params) : ""}`) as Translate;

/// The RPC error direct.ts builds from acpmux's `spawn.failed` reply.
function spawnFailed(recovery: string): Error {
  return Object.assign(
    new Error(
      "could not start the claude agent (claude-agent-acp in /Users/me/proj): No such file or directory (os error 2)",
    ),
    {
      code: -32603,
      errorKind: "spawn.failed",
      recovery,
      details: { binary: "claude-agent-acp", cwd: "/Users/me/proj" },
    },
  );
}

function failingPort(error: Error): SwitchPort {
  return {
    turnRunning: () => false,
    shown: () => undefined,
    create: async () => {
      throw error;
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

async function failedStart(error: Error) {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(failingPort(error));
  void harnessSwitch.switchTo("claude", "/Users/me/proj");
  for (let i = 0; i < 5; i++) await Promise.resolve();
  const intent = harnessSwitch.view().intent;
  expect(intent?.phase).toBe("failed");
  return startFailureView(t, { harness: "claude", name: "Claude Code", error: intent?.error, code: intent?.code });
}

test("a missing agent CLI reads as not installed and offers Install", async () => {
  const view = await failedStart(
    spawnFailed(
      "claude-agent-acp is not installed or not on the daemon's PATH. Install it, or fix the claude harness's command; `acpmux harness doctor claude` checks it step by step. Then send again.",
    ),
  );
  expect(view.sentence).toStartWith("switch.notInstalled");
  expect(view.install).toBeTruthy();
  expect(view.detail).toContain("os error 2");
});

test("a gone folder is not a missing agent: no Install", async () => {
  const view = await failedStart(
    spawnFailed("The folder /Users/me/proj is gone; restore it, or start the chat in another folder."),
  );
  expect(view.sentence).not.toStartWith("switch.notInstalled");
  expect(view.install).toBeUndefined();
});
