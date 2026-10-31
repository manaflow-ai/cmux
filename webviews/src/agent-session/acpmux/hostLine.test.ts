// The line above the composer never shows acpmux's own words, and never shows at all while a chat's
// machine is only reconnecting or slow (Leo, 2026-10-30: "it was literally just loading. Then it gave
// me that red message, like I could have fucking done something. But no, it was just a slow fucking
// connection.").
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { translate } from "./i18n";
import { AcpmuxRpcError } from "./handoff/protocol";
import { HOST_ERROR_DEADLINE_MS, hostErrorShows, hostIsReconnecting } from "./hostRetry";
import { PEER_LINK_DEADLINE_MS, hostLineText, isRawDaemonText, peerLinkFailure } from "./hostLine";

// acpmux's refusal for a request on a peer that is down, as the daemon words it (peer_link.rs
// `unreachable_error`) and as direct.ts hands it on (`reason` copied from `data.reason`).
const LEOS =
  "peer_unreachable: <host> (reconnecting, last seen 10s ago: WebSocket protocol error: Handshake not finished); the request was not sent; run `acpmux host ls` and retry after the peer reconnects";
const rpc = (message: string, data: Record<string, unknown>) =>
  Object.assign(new AcpmuxRpcError({ code: -32603, message, data }), { code: -32603, reason: data.reason });
const unreachable = (peerState: string) =>
  rpc(LEOS.replace("(reconnecting", `(${peerState}`), {
    reason: "peer_unreachable",
    retryable: true,
    try: "acpmux host ls",
    detail: "the request was not sent",
    peer: "<host>",
    peerState,
  });

// Every peer-link failure acpmux words today (peer_link.rs, peer.rs, redact.rs), and other daemon
// refusals in its CLI's words.
const DAEMON_WORDS = [
  LEOS,
  "peer_unreachable: the link to box took no new request for 30s; the request was not sent; run `acpmux host ls` and retry",
  "peer_unreachable: the request was not sent; retry later",
  "peer disconnected",
  "spawn.failed: the agent exited before it answered",
  'no peer "box"; run `acpmux host ls` and connect it',
];

test("a reconnecting, connecting, slow or restarting peer shows no line, however long it lasts", () => {
  for (const state of ["connecting", "degraded", "restarting"]) {
    expect(hostErrorShows(unreachable(state), 0)).toBe(false);
    expect(hostErrorShows(unreachable(state), 10 * PEER_LINK_DEADLINE_MS)).toBe(false);
  }
  for (const state of ["reconnecting", "offline"]) {
    // Leo's case: 10 s into a reconnect. Not past the old host deadline either.
    expect(hostErrorShows(unreachable(state), 10_000)).toBe(false);
    expect(hostErrorShows(unreachable(state), HOST_ERROR_DEADLINE_MS)).toBe(false);
    expect(hostIsReconnecting(unreachable(state))).toBe(true);
  }
  // The bridge that kept only the message, and a dropped link's request.
  expect(hostErrorShows(new Error(LEOS), 10_000)).toBe(false);
  expect(hostErrorShows(rpc("peer disconnected", { reason: "peer_disconnected", peer: "box" }), 10_000)).toBe(false);
});

test("a machine still unreachable past the deadline is said, once the person can act", () => {
  expect(hostErrorShows(unreachable("reconnecting"), PEER_LINK_DEADLINE_MS)).toBe(true);
  expect(hostErrorShows(unreachable("offline"), PEER_LINK_DEADLINE_MS)).toBe(true);
  expect(hostErrorShows(new Error(LEOS), PEER_LINK_DEADLINE_MS)).toBe(true);
});

test("the peer and its link state are read from the error's data, else from acpmux's message", () => {
  expect(peerLinkFailure(unreachable("degraded"))).toEqual({ peer: "<host>", peerState: "degraded" });
  expect(peerLinkFailure(new Error(LEOS))).toEqual({ peer: "<host>", peerState: "reconnecting" });
  expect(peerLinkFailure(new Error("peer_unreachable: the request was not sent; retry later"))).toEqual({});
  expect(peerLinkFailure(new Error("acpmux did not answer in time."))).toBeUndefined();
  expect(peerLinkFailure({ code: "host_unavailable", details: { reconnecting: true } })).toBeUndefined();
});

test("the line never carries a daemon code, protocol text or a CLI command; Details keeps them", () => {
  for (const words of DAEMON_WORDS) {
    const { line, detail } = hostLineText(new Error(words), words, translate, "box");
    expect(isRawDaemonText(line)).toBe(false);
    expect(line).not.toMatch(/[a-z]+_[a-z_]+:/);
    expect(line).not.toContain("`");
    expect(line).not.toContain("acpmux host");
    expect(line).not.toContain("WebSocket");
    expect(detail).toBe(words);
  }
  expect(hostLineText(unreachable("reconnecting"), LEOS, translate).line).toBe("Can't reach <host>.");
  expect(hostLineText(new Error("peer disconnected"), "peer disconnected", translate, "box").line).toBe(
    "Can't reach box.",
  );
  expect(
    hostLineText(new Error("peer_unreachable: retry later"), "peer_unreachable: retry later", translate).line,
  ).toBe("Can't reach this chat's machine.");
});

test("plain host words stay the line, with nothing behind Details", () => {
  for (const words of [
    "acpmux did not answer in time.",
    "acpmux belongs to cmux NIGHTLY, and this build may not use it. Quit that app, then try again.",
    "cmux cannot reach acpmux: it exited before it was ready. Its log is at /Users/someone/Library/Application Support/com.cmuxterm.app.next/acpmux/daemon.log.",
  ]) {
    expect(isRawDaemonText(words)).toBe(false);
    expect(hostLineText(new Error(words), words, translate)).toEqual({ line: words });
  }
});

// The lint: the one line above the composer takes its words from hostLineText, so no raw daemon
// text can reach it from a new call site.
test("every HostUnavailableLine in the pane is worded by hostLineText", () => {
  const source = readFileSync(join(import.meta.dir, "App.tsx"), "utf8");
  const uses = [...source.matchAll(/<HostUnavailableLine\b[\s\S]*?\/>/g)].map((match) => match[0]);
  expect(uses.length).toBeGreaterThan(0);
  for (const use of uses) {
    expect(use).toMatch(/message=\{hostWords\.line\}/);
    expect(use).toMatch(/detail=\{hostWords\.detail\}/);
  }
  expect(source).toMatch(/const hostWords = hostLineText\(/);
});
