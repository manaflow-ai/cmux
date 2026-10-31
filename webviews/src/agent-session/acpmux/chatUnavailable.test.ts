import { expect, test } from "bun:test";
import { CONNECTING_GRACE_MS, chatUnavailable } from "./chatUnavailable";

// Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD". A machine whose daemon announced its
// restart is still on its way up (acpmux reconnects at once): its chat is loading, which the pane
// shows as nothing, until the grace ends. Before, it was offline at once: a spinner and
// "Reconnecting…" on every remote daemon restart.
test("a machine whose daemon is restarting is loading within the grace, offline past it", () => {
  const peers = { box: { connected: false, state: "restarting", attempts: 0, lastSeen: 5 } };
  expect(chatUnavailable({ peer: "box", peers, waitedMs: 0 })).toEqual({ reason: "connecting", machine: "box" });
  expect(chatUnavailable({ peers, waitedMs: CONNECTING_GRACE_MS - 1 })).toEqual({
    reason: "connecting",
    machine: "box",
  });
  expect(chatUnavailable({ peer: "box", peers, waitedMs: CONNECTING_GRACE_MS })).toEqual({
    reason: "offline",
    machine: "box",
    lastSeen: 5,
  });
});
