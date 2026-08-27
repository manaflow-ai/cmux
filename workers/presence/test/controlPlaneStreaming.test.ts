// ControlPlaneCore fact streaming against mocked upstream fetch: snapshot
// ordering, the haveRev fast path, mint retry-once, publish_hint fan-out, the
// alarm-driven re-fetch broadcast, and failure/recovery behavior.

import { describe, expect, it } from "bun:test";
import {
  BEARER_PREFIX,
  CONTROL_REFRESH_INTERVAL_MS,
  ControlPlaneCore,
  DIR_KEY,
  HINT_CONFIRM_DELAY_MS,
  REV_KEY,
  SNAPSHOT_RETRY_DELAY_MS,
  directoryPayloadFromDiscovery,
  type CtlAttachment,
  type CtlSocket,
  type CtlUpstreamInit,
  type CtlUpstreamResult,
} from "../src/controlPlane";

const T0 = 1_800_000_000_000;
const T0_SECONDS = Math.floor(T0 / 1000);
const ENDPOINT_A = "a".repeat(64);
const ENDPOINT_B = "b".repeat(64);
const RELAY_1 = "https://usw1.relay.example/";
const RELAY_2 = "https://use4.relay.example/";

function discoveryResponse(
  revision: number,
  options: {
    homeRelayUrl?: string;
    extraBinding?: boolean;
  } = {},
): unknown {
  const bindings: unknown[] = [
    {
      binding_id: "611ffbbb-9f60-4601-ba39-4c241b900497",
      device_id: "77116c35-0000-4000-8000-000000000001",
      app_instance_id: "app-1",
      client_namespace: "irx",
      tag: "irx",
      platform: "mac",
      display_name: "Studio",
      endpoint_id: ENDPOINT_A,
      identity_generation: 1,
      pairing_enabled: true,
      capabilities: ["cmux.irx.v1"],
      path_hints: [
        {
          kind: "relay_url",
          value: options.homeRelayUrl ?? RELAY_1,
          source: "native",
          privacy_scope: "public_internet",
          observed_at: "2026-08-26T00:00:00Z",
          expires_at: "2026-08-26T00:30:00Z",
        },
      ],
      last_seen_at: "2026-08-26T00:00:00Z",
    },
  ];
  if (options.extraBinding) {
    bindings.push({
      binding_id: "e1b78ec4-7b2e-4077-88a4-ec4da794a9c6",
      device_id: "77116c35-0000-4000-8000-000000000002",
      client_namespace: "irx",
      tag: "irx",
      endpoint_id: ENDPOINT_B,
      path_hints: [],
      last_seen_at: "2026-08-26T00:05:00Z",
    });
  }
  return {
    route_contract_version: 1,
    revision,
    bindings,
    relay_fleet: [RELAY_1, RELAY_2],
    lan_rendezvous: { generation: 1, key: "unused" },
    grant_verification_keys: {
      version: 1,
      current_kid: "k1",
      keys: [{ kid: "k1", alg: "EdDSA", spki_der_base64: "MCowBQYDK2VwAyEA" }],
    },
  };
}

function mintResponse(endpointId: string): unknown {
  return {
    endpointId,
    relayCredentials: [
      {
        relayUrl: RELAY_1,
        token: "tok-1",
        expiresAt: T0_SECONDS + 300,
        refreshAfter: T0_SECONDS + 240,
        ttlSeconds: 300,
      },
      {
        relayUrl: RELAY_2,
        token: "tok-2",
        expiresAt: T0_SECONDS + 300,
        refreshAfter: T0_SECONDS + 240,
        ttlSeconds: 300,
      },
    ],
    policy: {},
    preference: {},
    preferenceRevision: 1,
  };
}

class FakeSocket implements CtlSocket {
  frames: Record<string, unknown>[] = [];
  closes: { code?: number; reason?: string }[] = [];
  private attachment: CtlAttachment | null = null;

  send(data: string): void {
    this.frames.push(JSON.parse(data) as Record<string, unknown>);
  }

  close(code?: number, reason?: string): void {
    this.closes.push({ ...(code !== undefined ? { code } : {}), ...(reason !== undefined ? { reason } : {}) });
  }

  getAttachment(): CtlAttachment | null {
    return this.attachment ? { ...this.attachment } : null;
  }

  setAttachment(attachment: CtlAttachment): void {
    this.attachment = { ...attachment };
  }

  types(): string[] {
    return this.frames.map((frame) => String(frame.type));
  }

  frame(type: string): Record<string, unknown> | undefined {
    return this.frames.find((frame) => frame.type === type);
  }

  clearFrames(): void {
    this.frames = [];
  }
}

type UpstreamHandler = (init: CtlUpstreamInit) => CtlUpstreamResult;

class Harness {
  now = T0;
  map = new Map<string, unknown>();
  alarms: number[] = [];
  socketList: FakeSocket[] = [];
  calls: { path: string; init: CtlUpstreamInit }[] = [];
  routes = new Map<string, UpstreamHandler>();
  core = new ControlPlaneCore({
    storage: {
      get: async <T>(key: string) => this.map.get(key) as T | undefined,
      put: async (key: string, value: unknown) => {
        this.map.set(key, value);
      },
      delete: async (key: string) => this.map.delete(key),
    },
    now: () => this.now,
    upstream: async (path, init) => {
      this.calls.push({ path, init });
      const handler = this.routes.get(path);
      if (!handler) throw new Error(`no upstream handler for ${path}`);
      return handler(init);
    },
    scheduleAlarmAt: async (atMs) => {
      this.alarms.push(atMs);
    },
    sockets: () => [...this.socketList],
  });

  serveDiscovery(response: () => unknown): void {
    this.routes.set("/api/devices/iroh", () => ({ status: 200, json: response() }));
  }

  serveMint(handler: UpstreamHandler): void {
    this.routes.set("/api/relay/token", handler);
  }

  async connect(sessionId: string, namespace?: string): Promise<FakeSocket> {
    const socket = new FakeSocket();
    this.socketList.push(socket);
    await this.core.handleConnect(socket, {
      sessionId,
      expiresAt: this.now + 15 * 60_000,
      bearer: `token-${sessionId}`,
      ...(namespace ? { namespace } : {}),
    });
    return socket;
  }

  async send(socket: FakeSocket, frame: unknown): Promise<void> {
    await this.core.handleMessage(socket, JSON.stringify(frame));
  }

  async hello(
    socket: FakeSocket,
    payload: { endpointId: string; haveRev?: number | null; wantPasses: boolean },
  ): Promise<void> {
    await this.send(socket, { v: 1, type: "hello", payload });
  }

  discoveryCalls(): { path: string; init: CtlUpstreamInit }[] {
    return this.calls.filter((call) => call.path === "/api/devices/iroh");
  }

  mintCalls(): { path: string; init: CtlUpstreamInit }[] {
    return this.calls.filter((call) => call.path === "/api/relay/token");
  }
}

describe("hello fact streaming", () => {
  it("streams hello_ack -> directory -> relay_passes -> snapshot_complete in order", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    harness.serveMint(() => ({ status: 200, json: mintResponse(ENDPOINT_A) }));

    const socket = await harness.connect("s1", "irx");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: true });

    expect(socket.types()).toEqual(["hello_ack", "directory", "relay_passes", "snapshot_complete"]);
    expect(socket.frame("hello_ack")?.payload).toEqual({ sessionId: "s1", resumedFromRev: null });

    const directory = socket.frame("directory") as { rev: number; payload: Record<string, unknown> };
    expect(directory.rev).toBe(42);
    expect(directory.payload.routeContractVersion).toBe(1);
    expect(directory.payload.relayFleet).toEqual([RELAY_1, RELAY_2]);
    expect(directory.payload.grantVerificationKeys).toEqual([
      { keyId: "k1", alg: "EdDSA", publicKey: "MCowBQYDK2VwAyEA" },
    ]);
    expect(directory.payload.bindings).toEqual([
      {
        bindingId: "611ffbbb-9f60-4601-ba39-4c241b900497",
        endpointId: ENDPOINT_A,
        clientNamespace: "irx",
        deviceId: "77116c35-0000-4000-8000-000000000001",
        instanceTag: "irx",
        homeRelayUrl: RELAY_1,
        updatedAt: "2026-08-26T00:00:00Z",
      },
    ]);

    const passes = socket.frame("relay_passes") as {
      rev: number;
      payload: { endpointId: string; passes: Record<string, unknown>[] };
    };
    expect(passes.rev).toBe(42);
    expect(passes.payload.endpointId).toBe(ENDPOINT_A);
    expect(passes.payload.passes.map((pass) => pass.relayUrl)).toEqual([RELAY_1, RELAY_2]);
    expect(passes.payload.passes.every((pass) => pass.generation === 1)).toBe(true);

    expect(socket.frame("snapshot_complete")?.rev).toBe(42);

    // Upstream calls carried this socket's own bearer + namespace, and the
    // mint replicated the Swift client's exact request body.
    const discovery = harness.discoveryCalls();
    expect(discovery).toHaveLength(1);
    expect(discovery[0]?.init.headers.authorization).toBe("Bearer token-s1");
    expect(discovery[0]?.init.headers["x-cmux-app-namespace"]).toBe("irx");
    const mint = harness.mintCalls();
    expect(mint).toHaveLength(1);
    expect(mint[0]?.init.method).toBe("POST");
    expect(mint[0]?.init.body).toBe(JSON.stringify({ endpointId: ENDPOINT_A }));
    expect(mint[0]?.init.headers.authorization).toBe("Bearer token-s1");
  });

  it("skips the directory body on the haveRev fast path", async () => {
    const harness = new Harness();
    // Seed the DO cache as if a previous snapshot had run.
    const seeded = directoryPayloadFromDiscovery(discoveryResponse(42));
    harness.map.set(REV_KEY, 42);
    harness.map.set(DIR_KEY, seeded?.payload);

    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: 42, wantPasses: false });

    expect(socket.types()).toEqual(["hello_ack", "snapshot_complete"]);
    expect(socket.frame("hello_ack")?.payload).toEqual({ sessionId: "s1", resumedFromRev: 42 });
    expect(socket.frame("snapshot_complete")?.rev).toBe(42);
    expect(harness.discoveryCalls()).toHaveLength(0); // no upstream fetch at all
  });

  it("serves an error plus cached facts when the directory fetch fails with a cache", async () => {
    const harness = new Harness();
    const seeded = directoryPayloadFromDiscovery(discoveryResponse(42));
    harness.map.set(REV_KEY, 42);
    harness.map.set(DIR_KEY, seeded?.payload);
    harness.routes.set("/api/devices/iroh", () => {
      throw new Error("connection reset");
    });

    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: 41, wantPasses: false });

    expect(socket.types()).toEqual(["hello_ack", "error", "directory", "snapshot_complete"]);
    expect(socket.frame("error")?.payload).toMatchObject({
      code: "directory_unavailable",
      retryable: true,
    });
    expect(socket.frame("directory")?.rev).toBe(42); // cached facts still served
    expect(harness.discoveryCalls()).toHaveLength(2); // one immediate retry
  });

  it("marks the snapshot pending on fetch failure without a cache, then recovers on alarm", async () => {
    const harness = new Harness();
    harness.routes.set("/api/devices/iroh", () => {
      throw new Error("connection reset");
    });

    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });

    expect(socket.types()).toEqual(["hello_ack", "error"]);
    expect(socket.getAttachment()?.snapshotPending).toBe(true);
    expect(harness.alarms).toContain(T0 + SNAPSHOT_RETRY_DELAY_MS);

    // Upstream recovers; the alarm completes the snapshot.
    harness.serveDiscovery(() => discoveryResponse(42));
    await harness.core.handleAlarm();
    expect(socket.types()).toEqual(["hello_ack", "error", "directory", "snapshot_complete"]);
    expect(socket.frame("snapshot_complete")?.rev).toBe(42);
    expect(socket.getAttachment()?.snapshotPending).toBe(false);
  });

  it("ignores a duplicate hello (reconnect is the resync path)", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    const framesAfterFirst = socket.frames.length;
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    expect(socket.frames.length).toBe(framesAfterFirst);
    expect(harness.discoveryCalls()).toHaveLength(1);
  });
});

describe("mint_request proxying", () => {
  async function snapshotted(harness: Harness, sessionId: string): Promise<FakeSocket> {
    const socket = await harness.connect(sessionId);
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: 42, wantPasses: false });
    socket.clearFrames();
    return socket;
  }

  function seed(harness: Harness): void {
    const seeded = directoryPayloadFromDiscovery(discoveryResponse(42));
    harness.map.set(REV_KEY, 42);
    harness.map.set(DIR_KEY, seeded?.payload);
  }

  it("retries exactly once on connection-level failure, then succeeds", async () => {
    const harness = new Harness();
    seed(harness);
    let attempts = 0;
    harness.serveMint(() => {
      attempts += 1;
      if (attempts === 1) throw new Error("connection reset");
      return { status: 200, json: mintResponse(ENDPOINT_A) };
    });

    const socket = await snapshotted(harness, "s1");
    await harness.send(socket, {
      v: 1,
      type: "mint_request",
      payload: { endpointId: ENDPOINT_A },
    });

    expect(attempts).toBe(2);
    expect(socket.types()).toEqual(["relay_passes"]);
    expect((socket.frame("relay_passes") as { rev: number }).rev).toBe(42);
  });

  it("reports a retryable error after the single retry also fails, without crashing the socket", async () => {
    const harness = new Harness();
    seed(harness);
    let attempts = 0;
    harness.serveMint(() => {
      attempts += 1;
      throw new Error("connection reset");
    });

    const socket = await snapshotted(harness, "s1");
    await harness.send(socket, {
      v: 1,
      type: "mint_request",
      payload: { endpointId: ENDPOINT_A },
    });

    expect(attempts).toBe(2); // once + ONE immediate retry, never more
    expect(socket.types()).toEqual(["error"]);
    expect(socket.frame("error")?.payload).toEqual({
      code: "mint_upstream_unavailable",
      message: "relay token mint failed upstream",
      retryable: true,
    });
    expect(socket.closes).toHaveLength(0);

    // The socket keeps working: upstream heals, the next mint succeeds.
    harness.serveMint(() => ({ status: 200, json: mintResponse(ENDPOINT_A) }));
    await harness.send(socket, {
      v: 1,
      type: "mint_request",
      payload: { endpointId: ENDPOINT_A },
    });
    expect(socket.types()).toEqual(["error", "relay_passes"]);
  });

  it("does not retry HTTP-level failures and maps status classes to retryability", async () => {
    const harness = new Harness();
    seed(harness);
    let attempts = 0;
    harness.serveMint(() => {
      attempts += 1;
      return { status: 503, json: { error: "iroh_service_unavailable" } };
    });
    const socket = await snapshotted(harness, "s1");
    await harness.send(socket, { v: 1, type: "mint_request", payload: { endpointId: ENDPOINT_A } });
    expect(attempts).toBe(1); // an HTTP response is never retried
    expect(socket.frame("error")?.payload).toMatchObject({
      code: "mint_upstream_unavailable",
      retryable: true,
    });

    socket.clearFrames();
    harness.serveMint(() => ({ status: 403, json: { error: "invalid_binding_request_proof" } }));
    await harness.send(socket, { v: 1, type: "mint_request", payload: { endpointId: ENDPOINT_A } });
    expect(socket.frame("error")?.payload).toMatchObject({ code: "mint_rejected", retryable: false });
  });

  it("uses each socket's own bearer, never another socket's", async () => {
    const harness = new Harness();
    seed(harness);
    harness.serveMint(() => ({ status: 200, json: mintResponse(ENDPOINT_B) }));

    await snapshotted(harness, "s1");
    const other = await snapshotted(harness, "s2");
    await harness.send(other, { v: 1, type: "mint_request", payload: { endpointId: ENDPOINT_B } });

    const mint = harness.mintCalls();
    expect(mint).toHaveLength(1);
    expect(mint[0]?.init.headers.authorization).toBe("Bearer token-s2");
  });

  it("bumps the per-endpoint generation on every successful mint", async () => {
    const harness = new Harness();
    seed(harness);
    harness.serveMint(() => ({ status: 200, json: mintResponse(ENDPOINT_A) }));
    const socket = await snapshotted(harness, "s1");
    await harness.send(socket, { v: 1, type: "mint_request", payload: { endpointId: ENDPOINT_A } });
    await harness.send(socket, { v: 1, type: "mint_request", payload: { endpointId: ENDPOINT_A } });
    const generations = socket.frames
      .filter((frame) => frame.type === "relay_passes")
      .map((frame) => ((frame.payload as { passes: { generation: number }[] }).passes[0]?.generation));
    expect(generations).toEqual([1, 2]);
  });
});

describe("publish_hint announcements", () => {
  it("fans out hint_update to the account's other snapshotted sockets and schedules the confirm pass", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));

    const mac = await harness.connect("mac");
    await harness.hello(mac, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    const phone = await harness.connect("phone");
    await harness.hello(phone, { endpointId: ENDPOINT_B, haveRev: 42, wantPasses: false });
    const preHello = await harness.connect("quiet"); // never sent hello
    mac.clearFrames();
    phone.clearFrames();
    harness.alarms = [];

    await harness.send(mac, {
      v: 1,
      type: "publish_hint",
      payload: { endpointId: ENDPOINT_A, homeRelayUrl: RELAY_2 },
    });

    // The announcer hears nothing back; the peer gets the hint immediately.
    expect(mac.frames).toHaveLength(0);
    expect(phone.types()).toEqual(["hint_update"]);
    const update = phone.frame("hint_update") as { rev: number; payload: Record<string, unknown> };
    expect(update.rev).toBe(42);
    expect(update.payload.endpointId).toBe(ENDPOINT_A);
    expect(update.payload.homeRelayUrl).toBe(RELAY_2);
    expect(typeof update.payload.updatedAt).toBe("string");
    // A socket that never helloed has no snapshot baseline and is skipped.
    expect(preHello.frames).toHaveLength(0);
    // Confirm-against-broker-truth pass is scheduled a few seconds out.
    expect(harness.alarms).toEqual([T0 + HINT_CONFIRM_DELAY_MS]);
    // Phase A never writes hints upstream; the Mac's own signed registration does.
    expect(harness.calls.filter((call) => call.init.method !== "GET")).toHaveLength(0);
  });

  it("rejects an implausible relay URL with a non-retryable error", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const mac = await harness.connect("mac");
    await harness.hello(mac, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    mac.clearFrames();

    await harness.send(mac, {
      v: 1,
      type: "publish_hint",
      payload: { endpointId: ENDPOINT_A, homeRelayUrl: "not-a-url" },
    });
    expect(mac.frame("error")?.payload).toMatchObject({ code: "invalid_hint", retryable: false });
  });
});

describe("alarm-driven refresh", () => {
  async function snapshottedPair(harness: Harness): Promise<[FakeSocket, FakeSocket]> {
    harness.serveDiscovery(() => discoveryResponse(42));
    const first = await harness.connect("s1");
    await harness.hello(first, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    const second = await harness.connect("s2");
    await harness.hello(second, { endpointId: ENDPOINT_B, haveRev: 42, wantPasses: false });
    first.clearFrames();
    second.clearFrames();
    harness.calls = [];
    harness.alarms = [];
    return [first, second];
  }

  it("broadcasts hint_update to every socket when only a home relay moved", async () => {
    const harness = new Harness();
    const [first, second] = await snapshottedPair(harness);

    harness.serveDiscovery(() => discoveryResponse(43, { homeRelayUrl: RELAY_2 }));
    await harness.core.handleAlarm();

    for (const socket of [first, second]) {
      expect(socket.types()).toEqual(["hint_update"]);
      const update = socket.frame("hint_update") as { rev: number; payload: Record<string, unknown> };
      expect(update.rev).toBe(43);
      expect(update.payload.homeRelayUrl).toBe(RELAY_2);
    }
    expect(harness.map.get(REV_KEY)).toBe(43);
    // Cadence continues while sockets are connected.
    expect(harness.alarms).toContain(T0 + CONTROL_REFRESH_INTERVAL_MS);
  });

  it("broadcasts the full directory when the binding set changed", async () => {
    const harness = new Harness();
    const [first, second] = await snapshottedPair(harness);

    harness.serveDiscovery(() => discoveryResponse(44, { extraBinding: true }));
    await harness.core.handleAlarm();

    for (const socket of [first, second]) {
      expect(socket.types()).toEqual(["directory"]);
      const directory = socket.frame("directory") as { rev: number; payload: { bindings: unknown[] } };
      expect(directory.rev).toBe(44);
      expect(directory.payload.bindings).toHaveLength(2);
    }
  });

  it("broadcasts nothing when the revision did not move", async () => {
    const harness = new Harness();
    const [first, second] = await snapshottedPair(harness);
    await harness.core.handleAlarm();
    expect(first.frames).toHaveLength(0);
    expect(second.frames).toHaveLength(0);
    expect(harness.discoveryCalls()).toHaveLength(1); // it did re-fetch
  });

  it("falls back to a storage revision counter when upstream omits revision", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => {
      const response = discoveryResponse(1) as Record<string, unknown>;
      delete response.revision;
      return response;
    });
    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    expect(socket.frame("directory")?.rev).toBe(1); // 0 -> content changed -> 1
    socket.clearFrames();

    harness.serveDiscovery(() => {
      const response = discoveryResponse(1, { homeRelayUrl: RELAY_2 }) as Record<string, unknown>;
      delete response.revision;
      return response;
    });
    await harness.core.handleAlarm();
    expect((socket.frame("hint_update") as { rev: number }).rev).toBe(2);
  });

  it("closes expired sockets, deletes their bearers, and stops the cadence when idle", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    expect(harness.map.has(`${BEARER_PREFIX}s1`)).toBe(true);

    harness.now = T0 + 16 * 60_000; // past the 15-minute deadline
    harness.alarms = [];
    await harness.core.handleAlarm();

    expect(socket.closes).toHaveLength(1);
    expect(harness.map.has(`${BEARER_PREFIX}s1`)).toBe(false);
    expect(harness.alarms).toHaveLength(0); // idle account: no reschedule
  });
});
