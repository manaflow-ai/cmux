// l10n-allow-file: test fixture machine names, not shipped UI.
//
// acpmux owns the machine link state (`_acpmux/peer_state_changed` `link`); the composer's machine row
// only renders it. Every state acpmux sends draws exactly one of the sidebar's dots, with the same
// mapping as the sidebar (`cmux-layout-reducer` `sidebar_bridge::link::peer_link`), and the row says the
// cause when acpmux knows it.
import { expect, test } from "bun:test";
import { linkWords } from "./MachineLinkStatus";
import { translate } from "./i18n";
import { ACPMUX_LINKS, readPeerLinkDetail, type AcpmuxLink } from "./linkState";
import { PEER_LINKS, peerLink } from "./peerLink";
import { PeerStateEvents } from "./peerStateEvents";

const t = (key: Parameters<typeof translate>[0]) => translate(key, {}, "en");

/// Each acpmux state: the dot the row draws (null: the peer copy banner's), its words, and whether it
/// offers Reconnect. The dots are the sidebar rule's (`peer_link`'s table test).
const ROWS: [AcpmuxLink, string | null, string, boolean][] = [
  ["connected", "connected", "Connected", false],
  ["connecting", "connecting", "Connecting…", false],
  ["reconnecting", "connecting", "Reconnecting…", false],
  ["restarting", "connecting", "Reconnecting…", false],
  ["degraded", "connecting", "Reconnecting…", false],
  ["offline", "offline", "Offline", true],
  ["authFailed", "offline", "Sign-in needed", false],
  ["updateRequired", "offline", "Update required", false],
  ["paused", null, "", false],
];

test("the renderer draws every acpmux link state, one dot each", () => {
  expect(ROWS.map(([state]) => state as string).sort()).toEqual([...ACPMUX_LINKS].sort());
  expect(Object.keys(PEER_LINKS).sort()).toEqual([...ACPMUX_LINKS].sort());
  for (const [state, dot, words, reconnects] of ROWS) {
    const link = peerLink({ summary: { peer: "walk-remote" }, peerLinks: { "walk-remote": { link: state } } });
    expect(link?.link ?? null, state).toBe(dot as never);
    if (!link) continue;
    expect(linkWords(link, t), state).toBe(words);
    expect(link.link === "offline" && !link.stuck, state).toBe(reconnects);
  }
});

test("the row says this Mac's network is down when acpmux says so", () => {
  const link = peerLink({
    summary: { peer: "walk-remote" },
    peerLinks: { "walk-remote": { link: "reconnecting", cause: "localNetwork", nextRetryAt: 5 } },
  });
  expect(link).toEqual({ machine: "walk-remote", link: "connecting", reconnecting: true, why: "localNetwork" });
  expect(linkWords(link!, t)).toBe("This Mac is offline");
  const peerDown = peerLink({
    summary: { peer: "walk-remote" },
    peerLinks: { "walk-remote": { link: "offline", cause: "peerDown" } },
  });
  expect(linkWords(peerDown!, t)).toBe("Offline");
});

test("an older daemon's state word still draws, and its whole state wins when sent", () => {
  expect(peerLink({ summary: { peer: "a" }, peerStates: { a: "reconnecting" } })?.link).toBe("connecting");
  expect(
    peerLink({ summary: { peer: "a" }, peerStates: { a: "offline" }, peerLinks: { a: { link: "authFailed" } } }),
  ).toEqual({ machine: "a", link: "offline", why: "authFailed", stuck: true });
});

test("a note's whole state is read field by field, and a word acpmux never sends is none", () => {
  expect(
    readPeerLinkDetail({
      state: "reconnecting",
      link: "restarting",
      carrier: "ssh",
      cause: "peerDown",
      since: 3,
      nextRetryAt: 9,
    }),
  ).toEqual({ link: "restarting", carrier: "ssh", cause: "peerDown", since: 3, nextRetryAt: 9 });
  expect(readPeerLinkDetail({ state: "connected" })).toEqual({ link: "connected" });
  expect(readPeerLinkDetail({ link: "sideways", carrier: "pigeon" })).toBeUndefined();

  const events = new PeerStateEvents();
  events.configure({ _meta: { acpmux: { origin: "local", features: ["peerStateEvents"] } } });
  expect(events.changed({ peer: "b", state: "reconnecting", link: "restarting", since: 1, at: 2 })).toBe(true);
  // Only `nextRetryAt` moved: still news, the row may count down to it.
  expect(
    events.changed({ peer: "b", state: "reconnecting", link: "restarting", since: 1, nextRetryAt: 7, at: 3 }),
  ).toBe(true);
  const [[, link]] = [...events.entries()];
  expect(link.state).toBe("reconnecting");
  expect(link.detail).toEqual({ link: "restarting", since: 1, nextRetryAt: 7 });
});
