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
async function fixture(origin: string | undefined, supported = true) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const requests: string[] = [];
  const snapshots: AcpmuxSnapshot[] = [];
  let peers: Peer[] = [{ name: "studio-mac", state: "connecting", lastSeen: null, error: null }];
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
      if (method === "_acpmux/status")
        return { peers: [{ name: "studio-mac", transport: "ssh", connected: true, state: "connected", lastSeen: 99 }] };
      if (method === "_acpmux/peers") {
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
  return {
    client,
    socket: () => socket,
    waitForState: (state: string) =>
      new Promise<void>((resolve) => {
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

test("a later status refresh cannot erase a newer live state and never polls the event snapshot", async () => {
  const f = await fixture("local");
  try {
    f.notify(note("offline", { error: "removed" }));
    await f.client.refreshPeers();
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
