// l10n-allow-file: test fixtures, not shipped UI.
// Tester on a company-managed Mac (Oct 2026): the third chip in the New Tab composer (the access
// mode) "does not work". On a New Tab the mode pick is held until acpmux starts the chat, and a
// mode the agent then refuses (managed Claude Code settings can disable bypass mode) was dropped
// in silence: the chat ran on another mode and nothing said why. The refusal is now a notice.
import { expect, test } from "bun:test";
import { HarnessSwitch } from "../src/agent-session/acpmux/harnessSwitch";

test("a held mode the agent refuses when the new chat starts says so", async () => {
  const store = new HarnessSwitch();
  const notices: string[] = [];
  store.setHandlers({ notice: (text: string) => notices.push(text) } as never);
  const sent: string[] = [];
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    create: async () => "s1",
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async (text: string) => {
      sent.push(text);
    },
    setModel: async () => undefined,
    setMode: async () => {
      throw new Error("bypassPermissions is disabled by your organization's managed settings");
    },
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as never);
  const opened = store.switchTo("claude", "/Users/dev");
  expect(store.pickMode("bypassPermissions")).toBe(true);
  expect(await opened).toBe("s1");
  expect(notices).toHaveLength(1);
  expect(notices[0]).toContain("bypassPermissions");
  expect(notices[0]).toContain("managed settings");
});

test("a held mode the agent takes shows no notice", async () => {
  const store = new HarnessSwitch();
  const notices: string[] = [];
  store.setHandlers({ notice: (text: string) => notices.push(text) } as never);
  const modes: string[] = [];
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    create: async () => "s1",
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async () => undefined,
    setModel: async () => undefined,
    setMode: async (modeId: string) => {
      modes.push(modeId);
    },
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as never);
  const opened = store.switchTo("claude", "/Users/dev");
  store.pickMode("acceptEdits");
  expect(await opened).toBe("s1");
  expect(modes).toEqual(["acceptEdits"]);
  expect(notices).toEqual([]);
});
