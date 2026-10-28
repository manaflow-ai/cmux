import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = new Map(["window", "document"].map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)]));
beforeAll(() => Object.assign(scope, { window: dom.window, document: dom.window.document }));
afterAll(() => {
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
  dom.window.close();
});

type Peer = { name: string; state: string; lastSeen?: number | null; error?: string | null };
async function fixture(origin: string | undefined, supported = true) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const requests: string[] = [];
  const snapshots: AcpmuxSnapshot[] = [];
  let peers: Peer[] = [{ name: "studio-mac", state: "connecting", lastSeen: null, error: null }];
  let duringRead: (() => void) | undefined;
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as { answer(method: string, params: Record<string, unknown>): Promise<unknown> };
  const answer = daemon.answer.bind(daemon);
  daemon.answer = async (method, params) => {
    requests.push(method);
    if (method === "initialize")
      return { protocolVersion: 1, _meta: { acpmux: { origin, features: supported ? ["peerStateEvents"] : [] } } };
    if (method === "_acpmux/status")
      return { peers: [{ name: "studio-mac", transport: "ssh", connected: true, state: "connected", lastSeen: 99 }] };
    if (method === "_acpmux/peers") {
      const result = { peers };
      const run = duringRead;
      duringRead = undefined;
      run?.();
      return result;
    }
    return answer(method, params);
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => snapshots.push(snapshot),
    undefined,
    () => socket as unknown as WebSocket,
  );
  const notify = (value: Record<string, unknown>) =>
    socket.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/peer_state_changed", params: value }),
    });
  return {
    client,
    requests,
    snapshots,
    notify,
    latest: () => snapshots.at(-1)!,
    peers: (value: Peer[]) => {
      peers = value;
    },
    duringRead: (run: () => void) => {
      duringRead = run;
    },
  };
}

const note = (state: string, extra: Record<string, unknown> = {}) => ({
  peer: "studio-mac",
  state,
  lastSeen: null,
  error: null,
  at: 1,
  ...extra,
});

test("a local app snapshots after watch, then closed controls receive the daemon's exact states", async () => {
  const f = await fixture("local");
  try {
    expect(f.requests.indexOf("_acpmux/peers")).toBeGreaterThan(f.requests.indexOf("_acpmux/watch"));
    expect(f.latest().peerStates?.["studio-mac"]).toBe("connecting");
    for (const state of ["degraded", "connected", "reconnecting", "offline"]) {
      f.notify(note(state));
      expect(f.latest().peerStates?.["studio-mac"]).toBe(state);
      expect(f.latest().peerConnected?.["studio-mac"]).toBe(state === "connected");
    }
    f.notify(note("offline", { error: "removed" }));
    expect(f.latest().peerStates?.["studio-mac"]).toBe("offline");
  } finally {
    f.client.close();
  }
});

test("identical lag replay is idempotent and the next state still reaches the client", async () => {
  const f = await fixture("local");
  try {
    const offline = note("offline", { lastSeen: 10, error: "lost" });
    f.notify(offline);
    expect(f.latest().peerStates?.["studio-mac"]).toBe("offline");
    const emitted = f.snapshots.length;
    f.notify({ ...offline, at: 2 });
    expect(f.snapshots).toHaveLength(emitted);
    f.notify(note("connected"));
    expect(f.latest().peerStates?.["studio-mac"]).toBe("connected");
  } finally {
    f.client.close();
  }
});

test("an event during a snapshot wins; an empty later snapshot clears removed peer state", async () => {
  const f = await fixture("local");
  try {
    f.peers([{ name: "studio-mac", state: "connected", lastSeen: 20 }]);
    f.duringRead(() => f.notify(note("offline", { error: "removed" })));
    await f.client.refreshPeers();
    expect(f.latest().peerStates?.["studio-mac"]).toBe("offline");
    f.peers([]);
    await f.client.refreshPeers();
    expect(f.latest().peerStates?.["studio-mac"]).toBeUndefined();
  } finally {
    f.client.close();
  }
});

for (const [origin, supported] of [
  ["peer", true],
  ["remote", true],
  [undefined, true],
  ["local", false],
] as const)
  test(`origin=${origin}, feature=${supported} retains its status snapshot without a peer-event subscription`, async () => {
    const f = await fixture(origin, supported);
    try {
      f.notify(note("offline"));
      expect(f.latest().peerStates?.["studio-mac"]).toBe("connected");
      expect(f.requests).not.toContain("_acpmux/peers");
    } finally {
      f.client.close();
    }
  });
