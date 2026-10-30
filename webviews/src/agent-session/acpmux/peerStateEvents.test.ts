import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
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
async function fixture(origin: string | undefined, supported = true, holdPeers = false) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const requests: string[] = [];
  const snapshots: AcpmuxSnapshot[] = [];
  let peers: Peer[] = [{ name: "studio-mac", state: "connecting", lastSeen: null, error: null }];
  let status: Record<string, unknown>[] = [
    { name: "studio-mac", transport: "ssh", connected: true, state: "connected", lastSeen: 99 },
  ];
  // A held `_acpmux/peers` answers only once released (`releasePeers`).
  let held: (() => void) | undefined;
  const peersHeld = holdPeers ? new Promise<void>((resolve) => (held = resolve)) : undefined;
  let socket: InstanceType<typeof MockAcpmuxSocket>;
  let onSnapshot: ((snapshot: AcpmuxSnapshot) => void) | undefined;
  const openSocket = () => {
    socket = new MockAcpmuxSocket(() => Promise.resolve());
    const daemon = socket as unknown as { answer(method: string, params: Record<string, unknown>): Promise<unknown> };
    const answer = daemon.answer.bind(daemon);
    daemon.answer = async (method, params) => {
      requests.push(method);
      if (method === "initialize")
        return { protocolVersion: 1, _meta: { acpmux: { origin, features: supported ? ["peerStateEvents"] : [] } } };
      if (method === "_acpmux/status") return { peers: status };
      if (method === "_acpmux/peers") {
        await peersHeld;
        return { peers };
      }
      return answer(method, params);
    };
    return socket as unknown as WebSocket;
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      snapshots.push(snapshot);
      onSnapshot?.(snapshot);
    },
    undefined,
    openSocket,
  );
  const notify = (value: Record<string, unknown>) =>
    socket.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/peer_state_changed", params: value }),
    });
  const f = {
    client,
    socket: () => socket,
    waitForState: (state: string | undefined) =>
      new Promise<void>((resolve) => {
        if (snapshots.length > 0 && snapshots.at(-1)!.peerStates?.["studio-mac"] === state) return resolve();
        onSnapshot = (snapshot) => {
          if (snapshot.peerStates?.["studio-mac"] === state) {
            onSnapshot = undefined;
            resolve();
          }
        };
      }),
    requests,
    snapshots,
    notify,
    latest: () => snapshots.at(-1)!,
    peers: (value: Peer[]) => {
      peers = value;
    },
    status: (value: Record<string, unknown>[]) => {
      status = value;
    },
    releasePeers: () => held?.(),
  };
  // The initial snapshot lands after the first frame: settle it, unless the test holds it.
  if (origin === "local" && supported && !holdPeers) await f.waitForState("connecting");
  return f;
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

test("a status read in flight cannot erase a newer live state and never polls the event snapshot", async () => {
  const f = await fixture("local");
  try {
    const refreshed = f.client.refreshPeers();
    f.notify(note("offline", { error: "removed" }));
    await refreshed;
    expect(f.latest().peerStates?.["studio-mac"]).toBe("offline");
    await f.client.refreshPeers();
    expect(f.requests.filter((method) => method === "_acpmux/peers")).toHaveLength(1);
  } finally {
    f.client.close();
  }
});

test("a lag notice reads the peer snapshot again, so a dropped disconnect is not lost", async () => {
  const f = await fixture("local");
  try {
    f.notify(note("connected"));
    expect(f.latest().peerStates?.["studio-mac"]).toBe("connected");
    // The daemon dropped the offline notice and said so with `_acpmux/lagged`.
    f.peers([{ name: "studio-mac", state: "offline", lastSeen: 5, error: "lost" }]);
    const offline = f.waitForState("offline");
    f.socket().onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { dropped: 3 } }),
    });
    await offline;
    expect(f.latest().peerConnected?.["studio-mac"]).toBe(false);
    expect(f.requests.filter((method) => method === "_acpmux/peers")).toHaveLength(2);
  } finally {
    f.client.close();
  }
});

test("a restarting peer in the snapshot stays restarting, so the picker never offers it as ready", async () => {
  const { environmentReady, knownMachines } = await import("./environments");
  const f = await fixture("local");
  try {
    f.notify(note("connected"));
    f.peers([{ name: "studio-mac", state: "restarting", lastSeen: 5, error: null }]);
    const restarting = f.waitForState("restarting");
    f.socket().onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { dropped: 1 } }),
    });
    await restarting;
    const latest = f.latest();
    expect(latest.peerConnected?.["studio-mac"]).toBe(false);
    const peers = {
      kinds: { "studio-mac": "ssh" as const },
      connected: latest.peerConnected,
      states: latest.peerStates,
    };
    const [machine] = knownMachines(["studio-mac"], [], peers.kinds, [], peers.connected, peers.states);
    expect(machine).toMatchObject({ state: "restarting", connected: false });
    expect(environmentReady(machine!)).toBe(false);
  } finally {
    f.client.close();
  }
});

test("a peer the status lists but the snapshot omits is not offered as ready", async () => {
  const { environmentReady, knownMachines } = await import("./environments");
  const f = await fixture("local");
  try {
    f.notify(note("offline", { lastSeen: 42, error: "lost" }));
    // Removed between the `_acpmux/status` read and the `_acpmux/peers` read (or an invalid row).
    f.peers([]);
    const omitted = f.waitForState(undefined);
    f.socket().onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { dropped: 1 } }),
    });
    await omitted;
    const latest = f.latest();
    expect(latest.peerConnected?.["studio-mac"]).toBe(false);
    const peers = {
      kinds: { "studio-mac": "ssh" as const },
      connected: latest.peerConnected,
      states: latest.peerStates,
    };
    const [machine] = knownMachines(["studio-mac"], [], peers.kinds, [], peers.connected, peers.states);
    expect(environmentReady(machine!)).toBe(false);
    // The offline banner (chatUnavailable) still reads what the status read last said of it.
    const status = (f.client as unknown as { peerStatus: Record<string, unknown> }).peerStatus["studio-mac"];
    expect(status).toMatchObject({ connected: false, lastSeen: 42, error: "lost" });
    expect(status).not.toHaveProperty("state");
  } finally {
    f.client.close();
  }
});

test("the first frame does not wait on the peer snapshot", async () => {
  // A held `_acpmux/peers` would hold `connect` if the snapshot sat on the first frame's path,
  // after the one round trip #27755 keeps it to.
  const f = await fixture("local", true, true);
  try {
    expect(f.requests).toContain("_acpmux/peers");
    expect(f.latest().peerStates?.["studio-mac"]).toBe("connected");
    const snapshot = f.waitForState("connecting");
    f.releasePeers();
    await snapshot;
  } finally {
    f.client.close();
  }
});

test("a later status read replaces a restarting state no note has updated since", async () => {
  // A failed restart goes restarting -> reconnecting, both `reconnecting` on the wire, so the daemon
  // sends no note; the next `_acpmux/status` read is what says so.
  const f = await fixture("local");
  try {
    f.peers([{ name: "studio-mac", state: "restarting", lastSeen: 5, error: null }]);
    const restarting = f.waitForState("restarting");
    f.socket().onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { dropped: 1 } }),
    });
    await restarting;
    f.status([
      { name: "studio-mac", transport: "ssh", connected: false, state: "reconnecting", lastSeen: 5, attempts: 1 },
    ]);
    await f.client.refreshPeers();
    expect(f.latest().peerStates?.["studio-mac"]).toBe("reconnecting");
    expect(f.latest().peerConnected?.["studio-mac"]).toBe(false);
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

test("reconnect reads a fresh snapshot and ignores late notifications from the old socket", async () => {
  const f = await fixture("local");
  let reconnect: (() => void) | undefined;
  const timer = spyOn(dom.window, "setTimeout").mockImplementation((run) => {
    if (typeof run === "function") reconnect = () => run();
    return 1;
  });
  try {
    const old = f.socket();
    f.notify(note("offline", { error: "removed" }));
    f.peers([{ name: "studio-mac", state: "connected", lastSeen: null, error: null }]);
    old.onclose?.();
    const connected = f.waitForState("connected");
    expect(reconnect).toBeDefined();
    reconnect!();
    await connected;
    expect(f.requests.filter((method) => method === "_acpmux/peers")).toHaveLength(2);
    const emitted = f.snapshots.length;
    old.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/peer_state_changed", params: note("offline") }),
    });
    expect(f.latest().peerStates?.["studio-mac"]).toBe("connected");
    expect(f.snapshots).toHaveLength(emitted);
  } finally {
    timer.mockRestore();
    f.client.close();
  }
});
