// l10n-allow-file: test fixtures, not shipped UI.
// A send the composer holds for its files binds its Enter at once only when it goes to the chat
// open now (heldSendBinding.ts). The host keeps one grant per key press or click: a start that runs
// between the Enter and the send (a harness switch deferred behind a running remote turn, a new
// chat, a Cloud start or wake, a sandbox run) needs that grant itself, and binding it early left the
// start refused with `transport.gesture_required` (review of #37031).
import { expect, test } from "bun:test";
import { HarnessSwitch } from "../src/agent-session/acpmux/harnessSwitch";
import { bindsHeldSendNow, type HeldSendRoute } from "../src/agent-session/acpmux/heldSendBinding";

/// The host's one grant per key press or click (AgentPaneUserGestures).
function host() {
  let grant = false;
  return {
    press: () => void (grant = true),
    spend: () => {
      const had = grant;
      grant = false;
      return had;
    },
  };
}

const open: HeldSendRoute = {
  openChat: "chat-1",
  switchPending: false,
  startsChat: false,
  cloudStart: false,
  cloudWake: false,
  sandbox: false,
};

test("a held send binds its Enter at once only when it goes to the chat open now", () => {
  expect(bindsHeldSendNow(open)).toBe(true);
  expect(bindsHeldSendNow({ ...open, openChat: undefined })).toBe(false);
  expect(bindsHeldSendNow({ ...open, switchPending: true })).toBe(false);
  expect(bindsHeldSendNow({ ...open, startsChat: true })).toBe(false);
  expect(bindsHeldSendNow({ ...open, cloudStart: true })).toBe(false);
  expect(bindsHeldSendNow({ ...open, cloudWake: true })).toBe(false);
  expect(bindsHeldSendNow({ ...open, sandbox: true })).toBe(false);
});

test("a deferred remote switch with files still pending keeps the Enter for its start", async () => {
  const gestures = host();
  const store = new HarnessSwitch();
  const sent: { promptId: string; ticket?: string }[] = [];
  let started = 0;
  store.setHandlers({ gesture: async () => (gestures.spend() ? "ticket-late" : undefined) });
  store.connect({
    // The old chat's remote turn runs: the switch waits behind it (deferred).
    turnRunning: () => true,
    shown: () => undefined,
    // A remote session/new needs the person's grant.
    create: async () => {
      if (!gestures.spend()) throw Object.assign(new Error("gesture"), { code: "transport.gesture_required" });
      started += 1;
      return "s-new";
    },
    leave: () => undefined,
    open: async (sessionId: string) => sessionId,
    send: async (_text: string, _attachments: unknown, promptId: string, ticket?: string) => {
      sent.push({ promptId, ...(ticket ? { ticket } : {}) });
    },
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
    startsOnSend: () => true,
  } as never);
  void store.switchTo("codex", "/Users/dev", { deferred: true });
  expect(store.view().intent).toBeDefined();
  // Enter with a pasted PDF still uploading: the composer asks whether to bind now. The old chat is
  // still the one selected, but the switch will start a chat first.
  gestures.press();
  const route: HeldSendRoute = { ...open, switchPending: store.view().intent !== undefined };
  const bound = bindsHeldSendNow(route) ? { promptId: "held-1", ticket: Promise.resolve("ticket-enter") } : undefined;
  if (bound) gestures.spend();
  // The file is ready: the held send goes through the switch, whose remote start takes the grant.
  await store.send("with the spec", [], undefined, bound?.promptId, true, bound?.ticket);
  expect(started).toBe(1);
  expect(sent).toHaveLength(1);
});
