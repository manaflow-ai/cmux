// A chat open while the app restarts acpmux (an update's relaunch, Restart agent service) loses its
// socket, and the pane connects again to the new daemon. That daemon can be newer and name
// capabilities the old one did not: the 2026-11-12 nightly's restart brought `settled-attach-v1`,
// the page asked `_acpmux/attach {settled: true}`, and the cmux host refused the whole attach as
// `transport.intent_invalid` because its params rule did not know `settled` (cmux#42185). In the
// app every open chat showed empty history and "Something went wrong, so that didn't go through"
// though the new daemon held every chat.
//
// The page's own fallback (direct.ts `settledAttachFailed`) now retries a refused settled attach
// plain, so a chat opens even through a host that refuses it. What this test holds is the host's
// side: the settled ask goes through to acpmux unrefused, and the chat draws its rows again.
//
// The socket here stands in for the app's bridge (AgentPaneTransport): it applies the host's pane
// policy as data (cmux-agent-pane-policy policy.json, which tests/swift.rs keeps equal to
// AcpmuxPaneMethods.swift) and answers a refused request with the host's own refusal frame
// (AcpmuxPaneMethods.refusal). Behind it is the mock daemon; a restart closes the socket as the
// bridge does when the daemon goes, and the next socket reaches a new daemon over the same chats.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { AcpmuxSnapshot } from "./model";
import { resetKeptTailsForTests } from "./tailCache";

type Policy = {
  initialize: string;
  requests: string[];
  notifications: string[];
  known_params: Record<string, { params: string[] }>;
};
const policy = JSON.parse(
  readFileSync(path.resolve(import.meta.dir, "../../../../cmux-tui/crates/cmux-agent-pane-policy/policy.json"), "utf8"),
) as Policy;

type Frame = { id?: number | string; method?: string; params?: Record<string, unknown> };
type Daemon = {
  readyState: number;
  onopen: (() => void) | null;
  onmessage: ((message: { data: string }) => void) | null;
  send(raw: string): void;
  close?(): void;
};

/// What the host refuses before the daemon sees it: a method off the list, or a top-level param the
/// method's schema lacks (the params rule, P1). `_meta` keys are the host's other rules, not this one.
function hostRefuses({ method, params }: Frame): boolean {
  if (!method || method === policy.initialize) return false;
  const known = policy.known_params[method];
  if (!known) return !policy.requests.includes(method) && !policy.notifications.includes(method);
  return Object.keys(params ?? {}).some((key) => !known.params.includes(key));
}

class HostSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event?: { code: number; reason: string; wasClean: boolean }) => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  constructor(
    private readonly daemon: Daemon,
    private readonly log: { refused: string[]; attaches: Record<string, unknown>[] },
  ) {
    daemon.onopen = () => {
      this.readyState = 1;
      this.onopen?.();
    };
    daemon.onmessage = (message) => {
      if (this.readyState === 1) this.onmessage?.(message);
    };
  }
  send(raw: string): void {
    const frame = JSON.parse(raw) as Frame;
    if (hostRefuses(frame)) {
      this.log.refused.push(`${frame.method} ${Object.keys(frame.params ?? {}).join(",")}`);
      if (frame.id === undefined) return;
      const data = { code: "transport.intent_invalid", origin: "native", method: frame.method };
      const error = { code: -32601, message: "Refused by the cmux host", data };
      queueMicrotask(() => {
        if (this.readyState === 1) this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: frame.id, error }) });
      });
      return;
    }
    if (frame.method === "_acpmux/attach") this.log.attaches.push(frame.params ?? {});
    this.daemon.send(raw);
  }
  /// The daemon stopped under an open socket: the bridge pushes `closed` to the page.
  daemonStopped(): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.daemon.close?.();
    queueMicrotask(() => this.onclose?.({ code: 1006, reason: "acpmux stopped", wasClean: false }));
  }
  close(): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.daemon.close?.();
    queueMicrotask(() => this.onclose?.({ code: 1000, reason: "", wasClean: true }));
  }
}

type Globals = { cmuxAcpmuxMockCapabilities?: string[] };
// The mock's one chat id: a tail another file's client kept of it, or this test's lost path keeps,
// must not stand in front of the next open (bun shares one module cache across files).
beforeEach(() => resetKeptTailsForTests());
afterEach(() => {
  delete (globalThis as Globals).cmuxAcpmuxMockCapabilities;
  resetKeptTailsForTests();
});

test("after acpmux restarts with a newer daemon, the open chat reconnects and draws its history again", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const log = { refused: [] as string[], attaches: [] as Record<string, unknown>[] };
  const sockets: HostSocket[] = [];
  const open = () => {
    const socket = new HostSocket(new MockAcpmuxSocket(() => Promise.resolve()) as unknown as Daemon, log);
    sockets.push(socket);
    return socket as unknown as WebSocket;
  };
  // What the pane draws: the newest snapshot the client handed its listener (App.tsx draws it).
  let drawn: AcpmuxSnapshot | undefined;
  const draw = (snapshot: AcpmuxSnapshot) => {
    drawn = snapshot;
  };
  const shown = (client: { snapshot(): void }) => {
    client.snapshot();
    return drawn;
  };

  // The daemon before the update names no settled view.
  let lost!: () => void;
  const lostOnce = new Promise<void>((resolve) => (lost = resolve));
  const first = await AcpmuxDirectClient.connect(mockHost, draw, lost, open);
  const before = shown(first);
  expect(before?.sessionId).toBe(mockHost.sessionId);
  const rows = before?.rows.map((row) => row.id) ?? [];
  expect(rows.length).toBeGreaterThan(0);

  // The app stops it and starts the new one, which keeps every chat and names `settled-attach-v1`.
  (globalThis as Globals).cmuxAcpmuxMockCapabilities = ["settled-attach-v1"];
  sockets[0]!.daemonStopped();
  await lostOnce;
  // Between the sockets the pane holds nothing new; the next connect must draw the chat again.
  drawn = undefined;

  // The pane's lost path: a fresh handshake and a new client on the same chat (App.tsx connectHost).
  const second = await AcpmuxDirectClient.connect(mockHost, draw, undefined, open);
  try {
    const after = shown(second);
    // History is back in place, from the new daemon, with no refusal on the way: the cold open's
    // settled attach went through the host to acpmux.
    expect(log.refused).toEqual([]);
    expect(log.attaches.at(-1)).toMatchObject({ sessionId: mockHost.sessionId, settled: true });
    expect(after?.sessionId).toBe(mockHost.sessionId);
    expect(after?.rows.map((row) => row.id)).toEqual(rows);
  } finally {
    second.close();
    first.close();
  }
});
