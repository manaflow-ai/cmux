// l10n-allow-file: test fixture machine names, not shipped UI.
// Why a tab's chat is not listed (chatUnavailable.ts): deleted, its machine not connected (with when
// it was last seen), or its machine still connecting, which the pane shows as loading.
import { describe, expect, test } from "bun:test";
import {
  CONNECTING_GRACE_MS,
  chatUnavailable,
  peerStatusFromStatus,
} from "../src/agent-session/acpmux/chatUnavailable";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ChatUnavailableState } from "../src/agent-session/acpmux/ChatUnavailableState";

describe("chatUnavailable", () => {
  test("no machine down: a chat the pane saw leave the list was deleted; one never seen is not found", () => {
    expect(chatUnavailable({ peers: {}, waitedMs: 0, seenListed: true })).toEqual({ reason: "deleted" });
    expect(
      chatUnavailable({ peers: { box: { connected: true, state: "connected" } }, waitedMs: 0, seenListed: true }),
    ).toEqual({ reason: "deleted" });
    // Never listed here (a tab this acpmux does not hold, such as a Chief home's own chat): the pane
    // cannot say it was deleted.
    expect(chatUnavailable({ peers: {}, waitedMs: 0 })).toEqual({ reason: "notFound" });
    expect(chatUnavailable({ peers: { box: { connected: true, state: "connected" } }, waitedMs: 0 })).toEqual({
      reason: "notFound",
    });
    // The chat's own machine is connected: another machine being down does not matter.
    expect(
      chatUnavailable({
        peer: "box",
        peers: { box: { connected: true }, other: { connected: false, state: "offline" } },
        waitedMs: 0,
      }),
    ).toEqual({ reason: "deleted", machine: "box" });
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
    // Past the grace a handshake that has not read that machine's chats is offline, never deleted:
    // acpmux sets `lastSeen` when the socket opens, before it has the list.
    expect(chatUnavailable({ peers: handshake, waitedMs: CONNECTING_GRACE_MS, seenListed: true })).toEqual({
      reason: "offline",
      machine: "box",
      lastSeen: 5,
    });
    // An older daemon that says no state: `connected` settles it.
    expect(chatUnavailable({ peer: "box", peers: { box: { connected: true } }, waitedMs: 0 }).reason).toBe("deleted");
    // A restarted daemon that has not tried a saved peer yet.
    expect(
      chatUnavailable({ peers: { box: { connected: false, state: "reconnecting", attempts: 0 } }, waitedMs: 0 }).reason,
    ).toBe("connecting");
    // A peer whose daemon announced a restart (acpmux peer_link.rs `Restarting`) is on its way back.
    expect(
      chatUnavailable({ peers: { box: { connected: false, state: "restarting", attempts: 0 } }, waitedMs: 0 }).reason,
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
    // The chat's machine is not known, and the one down was reached before: it may still hold the
    // chat (its socket can open, setting `lastSeen`, and fail before acpmux read its chats), so the
    // chat is not called deleted while it is down.
    expect(
      chatUnavailable({
        peers: { box: { connected: false, state: "reconnecting", attempts: 3, lastSeen } },
        waitedMs: 0,
        seenListed: true,
      }),
    ).toEqual({ reason: "offline", machine: "box", lastSeen });
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

describe("ChatUnavailableState", () => {
  const session = "01a1201b-d3c3-7be1-8c40-1f1cbc87b8dc";
  const none = () => {};
  const render = (unavailable: Parameters<typeof ChatUnavailableState>[0]["unavailable"], machine?: string) =>
    renderToStaticMarkup(
      createElement(ChatUnavailableState, {
        unavailable,
        session,
        ...(machine ? { machine } : {}),
        onRemove: none,
        onReconnect: none,
        onResume: none,
        onClose: none,
      }),
    );

  test("a deleted chat names the machine it was on, not the tab's", () => {
    const html = render({ reason: "deleted", machine: "build-box" }, "Studio");
    expect(html).toContain("It&#x27;s no longer on build-box.");
    expect(html).not.toContain("Studio");
    expect(render({ reason: "deleted" }, "Studio")).toContain("It&#x27;s no longer on Studio.");
  });

  test("a chat never seen here is not found, never deleted", () => {
    const html = render({ reason: "notFound" }, "Studio");
    expect(html).toContain("Can&#x27;t find this chat");
    expect(html).toContain("Studio doesn&#x27;t have it.");
    expect(html).not.toMatch(/was deleted|Remove from Sidebar/);
    expect(html).toContain("Close Tab");
  });

  test("every case keeps the session id and Resume; Close Tab on all but deleted (Remove from Sidebar)", () => {
    const cases = [
      { reason: "deleted" as const },
      { reason: "notFound" as const },
      { reason: "offline" as const, machine: "box" },
    ];
    for (const unavailable of cases) {
      const html = render(unavailable, "Studio");
      expect(html).toContain("Session 01a1201b-d3c3");
      expect(html).not.toContain(session);
      expect(html).toContain("Resume from Transcript…");
      expect(html.includes("Close Tab")).toBe(unavailable.reason !== "deleted");
      expect(html.includes("Remove from Sidebar")).toBe(unavailable.reason === "deleted");
    }
  });

  test("a chat still loading shows nothing: no session id, text or buttons", () => {
    // Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD". Past the grace it is offline (above).
    const html = render({ reason: "connecting", machine: "box" }, "Studio");
    expect(html).toBe(
      '<div class="acpmux-empty acpmux-unavailable" data-unavailable="connecting" aria-busy="true"></div>',
    );
  });
});
