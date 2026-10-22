// l10n-allow-file: test fixture machine names, not shipped UI.
// Why a tab's chat is not listed (chatUnavailable.ts): deleted, its machine not connected (with when
// it was last seen), or its machine still connecting, which the pane shows as loading.
import { describe, expect, test } from "bun:test";
import {
  CONNECTING_GRACE_MS,
  chatUnavailable,
  peerStatusFromStatus,
} from "../src/agent-session/acpmux/chatUnavailable";

describe("chatUnavailable", () => {
  test("no machine down: the chat was deleted", () => {
    expect(chatUnavailable({ peers: {}, waitedMs: 0 })).toEqual({ reason: "deleted" });
    expect(chatUnavailable({ peers: { box: { connected: true, state: "connected" } }, waitedMs: 0 })).toEqual({
      reason: "deleted",
    });
    // The chat's own machine is connected: another machine being down does not matter.
    expect(
      chatUnavailable({
        peer: "box",
        peers: { box: { connected: true }, other: { connected: false, state: "offline" } },
        waitedMs: 0,
      }),
    ).toEqual({ reason: "deleted" });
  });

  test("a machine still on its first attempts is loading until the grace ends", () => {
    const peers = { box: { connected: false, state: "connecting", attempts: 0 } };
    expect(chatUnavailable({ peers, waitedMs: 1_000 })).toEqual({ reason: "connecting", machine: "box" });
    expect(chatUnavailable({ peers, waitedMs: CONNECTING_GRACE_MS })).toEqual({ reason: "offline", machine: "box" });
    // The socket is open but acpmux is still in its handshake (peer.rs `serve` says `connected`
    // before it has read that machine's chats): loading, by the chat's machine or any machine.
    const handshake = { box: { connected: true, state: "degraded", attempts: 0, lastSeen: 5 } };
    expect(chatUnavailable({ peer: "box", peers: handshake, waitedMs: 1_000 })).toEqual({
      reason: "connecting",
      machine: "box",
    });
    expect(chatUnavailable({ peers: handshake, waitedMs: 1_000 })).toEqual({ reason: "connecting", machine: "box" });
    // An older daemon that says no state: `connected` settles it.
    expect(chatUnavailable({ peer: "box", peers: { box: { connected: true } }, waitedMs: 0 }).reason).toBe("deleted");
    // A restarted daemon that has not tried a saved peer yet.
    expect(
      chatUnavailable({ peers: { box: { connected: false, state: "reconnecting", attempts: 0 } }, waitedMs: 0 }).reason,
    ).toBe("connecting");
  });

  test("a machine that is down names itself and when it was last seen", () => {
    const lastSeen = Date.UTC(2026, 9, 21, 8, 0, 0);
    // The chat was on `box`, which is down.
    expect(
      chatUnavailable({
        peer: "box",
        peers: { box: { connected: false, state: "reconnecting", attempts: 3, lastSeen } },
        waitedMs: 0,
      }),
    ).toEqual({ reason: "offline", machine: "box", lastSeen });
    // The chat's machine is not known, and the one down was reached before: acpmux still lists that
    // machine's chats (stale), so a chat it does not list was deleted.
    expect(
      chatUnavailable({
        peers: { box: { connected: false, state: "reconnecting", attempts: 3, lastSeen } },
        waitedMs: 0,
      }),
    ).toEqual({ reason: "deleted" });
    // A machine acpmux never reached could hold it.
    expect(
      chatUnavailable({ peers: { box: { connected: false, state: "offline", attempts: 6 } }, waitedMs: 0 }),
    ).toEqual({ reason: "offline", machine: "box" });
    // The chat's machine is known and acpmux no longer lists it: offline, by that name.
    expect(chatUnavailable({ peer: "gone-box", peers: {}, waitedMs: 0 })).toEqual({
      reason: "offline",
      machine: "gone-box",
    });
    // Two machines down and the chat's is not known: offline, naming neither.
    expect(
      chatUnavailable({
        peers: { a: { connected: false, state: "offline" }, b: { connected: false, state: "offline" } },
        waitedMs: 0,
      }),
    ).toEqual({ reason: "offline" });
  });

  test("peer status keeps only well-typed fields", () => {
    expect(
      peerStatusFromStatus({
        peers: [
          { name: "box", connected: false, state: "reconnecting", lastSeen: 5, attempts: 2, url: "ssh://x" },
          { name: "odd", connected: "no", state: 3, lastSeen: "yesterday", attempts: null },
          { connected: true },
        ],
      }),
    ).toEqual({ box: { connected: false, state: "reconnecting", lastSeen: 5, attempts: 2 }, odd: {} });
    expect(peerStatusFromStatus(undefined)).toEqual({});
  });
});
