// l10n-allow-file: test fixtures, not shipped UI.
// The page lifecycle may let a hidden New Tab page go. A chip pick there starts a chat
// behind the page that no prompt went to yet; only the page knows it, so `pane.wakeState` reports it
// (`pendingChat`, from `holdsDeferred`) and the host keeps the page instead of losing the pick.
import { expect, test } from "bun:test";
import { HarnessSwitch } from "../src/agent-session/acpmux/harnessSwitch";

function connected(turnRunning = false) {
  const store = new HarnessSwitch();
  store.connect({
    turnRunning: () => turnRunning,
    shown: () => undefined,
    create: () => new Promise<string | undefined>(() => undefined),
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async () => undefined,
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as never);
  return store;
}

test("a pick on the New Tab page holds a deferred chat until the page closes", () => {
  const store = connected();
  expect(store.holdsDeferred).toBe(false);
  void store.switchTo("claude", "/Users/dev", { deferred: true, model: "claude-haiku-5-5" });
  expect(store.holdsDeferred).toBe(true);
  store.cancelDeferred();
  expect(store.holdsDeferred).toBe(false);
});

test("a switch the pane shows at once is the chat's own, not a deferred one", () => {
  const store = connected();
  void store.switchTo("claude", "/Users/dev");
  expect(store.view().intent?.shown).toBe(true);
  expect(store.holdsDeferred).toBe(false);
});
