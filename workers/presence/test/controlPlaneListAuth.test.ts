// listv2 device-authorization overlay on the ControlPlaneCore: seeded overlay
// rows, confirm-on-hello, ack tracking with the alarm-driven retry ladder,
// account-owner revocation, and the freshness lease (issuedAt/ttlSeconds on
// directories; snapshot_complete.issuedAt playing the explicit-freshness
// "current" role on the haveRev fast path — the existing frame was extended
// instead of adding a new frame type, which keeps old clients decoding).

import { describe, expect, it } from "bun:test";
import {
  ACK_RETRY_LADDER_MS,
  ACK_RETRY_STEADY_MS,
  BEARER_PREFIX,
  CONTROL_SERVER_CAPABILITIES,
  ControlPlaneCore,
  DEV_PREFIX,
  DIR_KEY,
  DIRECTORY_TTL_SECONDS,
  REV_KEY,
  directoryPayloadFromDiscovery,
  parseRevocationRequest,
  type CtlAttachment,
  type CtlSocket,
  type CtlUpstreamInit,
  type CtlUpstreamResult,
  type DeviceOverlay,
} from "../src/controlPlane";

const T0 = 1_800_000_000_000;
const T0_SECONDS = Math.floor(T0 / 1000);
const ENDPOINT_A = "a".repeat(64);
const ENDPOINT_B = "b".repeat(64);
const RELAY_1 = "https://usw1.relay.example/";
const RELAY_2 = "https://use4.relay.example/";

function discoveryResponse(
  revision: number,
  options: { minimumSupportedVersion?: boolean } = {},
): unknown {
  return {
    route_contract_version: 1,
    revision,
    bindings: [
      {
        binding_id: "611ffbbb-9f60-4601-ba39-4c241b900497",
        device_id: "77116c35-0000-4000-8000-000000000001",
        client_namespace: "irx",
        tag: "irx",
        endpoint_id: ENDPOINT_A,
        path_hints: [
          {
            kind: "relay_url",
            value: RELAY_1,
            source: "native",
            privacy_scope: "public_internet",
            observed_at: "2026-08-26T00:00:00Z",
            expires_at: "2026-08-26T00:30:00Z",
          },
        ],
        last_seen_at: "2026-08-26T00:00:00Z",
      },
    ],
    relay_fleet: [RELAY_1, RELAY_2],
    grant_verification_keys: {
      version: 1,
      current_kid: "k1",
      keys: [{ kid: "k1", alg: "EdDSA", spki_der_base64: "MCowBQYDK2VwAyEA" }],
    },
    ...(options.minimumSupportedVersion
      ? { minimum_supported_version: { mac: "0.30.0", ios: "1.4.0" } }
      : {}),
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
    ],
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

  lastFrame(type: string): Record<string, unknown> | undefined {
    return [...this.frames].reverse().find((frame) => frame.type === type);
  }

  countOf(type: string): number {
    return this.frames.filter((frame) => frame.type === type).length;
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
      list: async <T>(options: { prefix: string }) => {
        const out = new Map<string, T>();
        for (const [key, value] of this.map) {
          if (key.startsWith(options.prefix)) out.set(key, value as T);
        }
        return out;
      },
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

  async connect(
    sessionId: string,
    options: { expiresInMs?: number; namespace?: string } = {},
  ): Promise<FakeSocket> {
    const socket = new FakeSocket();
    this.socketList.push(socket);
    await this.core.handleConnect(socket, {
      sessionId,
      expiresAt: this.now + (options.expiresInMs ?? 15 * 60_000),
      bearer: `token-${sessionId}`,
      ...(options.namespace !== undefined ? { namespace: options.namespace } : {}),
    });
    return socket;
  }

  async send(socket: FakeSocket, frame: unknown): Promise<void> {
    await this.core.handleMessage(socket, JSON.stringify(frame));
  }

  async hello(socket: FakeSocket, payload: Record<string, unknown>): Promise<void> {
    await this.send(socket, { v: 1, type: "hello", payload });
  }

  overlay(endpointId: string): DeviceOverlay | undefined {
    return this.map.get(DEV_PREFIX + endpointId) as DeviceOverlay | undefined;
  }
}

describe("listv2 seeded overlay", () => {
  it("creates a seeded overlay row on first directory and emits it in the bindings", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));

    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_B, haveRev: null, wantPasses: false });

    // The binding's first sighting materialized its overlay row in storage…
    expect(harness.overlay(ENDPOINT_A)).toEqual({ status: "seeded", revoked: false });
    // …and the emitted directory carries the join (revoked is REQUIRED).
    const directory = socket.frame("directory") as { payload: { bindings: Record<string, unknown>[] } };
    expect(directory.payload.bindings[0]).toMatchObject({
      endpointId: ENDPOINT_A,
      status: "seeded",
      revoked: false,
    });
  });

  it("stamps issuedAt + ttlSeconds on every outbound directory", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_B, haveRev: null, wantPasses: false });
    const payload = (socket.frame("directory") as { payload: Record<string, unknown> }).payload;
    expect(payload.issuedAt).toBe(new Date(T0).toISOString());
    expect(payload.ttlSeconds).toBe(DIRECTORY_TTL_SECONDS);
  });
});

describe("confirm-on-hello", () => {
  it("flips seeded -> active, records version/track/capabilities, bumps rev, and broadcasts", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));

    const viewer = await harness.connect("viewer");
    await harness.hello(viewer, { endpointId: ENDPOINT_B, haveRev: null, wantPasses: false });
    expect(harness.overlay(ENDPOINT_A)?.status).toBe("seeded");
    viewer.clearFrames();

    const mac = await harness.connect("mac");
    await harness.hello(mac, {
      endpointId: ENDPOINT_A,
      haveRev: null,
      wantPasses: false,
      deviceId: "77116c35-0000-4000-8000-000000000001",
      platform: "mac",
      appVersion: "1.2.3",
      releaseTrack: "internal",
      capabilities: ["cmux.irx.v1"],
    });

    // Overlay recorded the confirmation.
    expect(harness.overlay(ENDPOINT_A)).toEqual({
      status: "active",
      revoked: false,
      appVersion: "1.2.3",
      releaseTrack: "internal",
      capabilities: ["cmux.irx.v1"],
      lastConfirmedAt: new Date(T0).toISOString(),
      deviceId: "77116c35-0000-4000-8000-000000000001",
    });

    // The overlay change is revision-bearing: 42 (broker) -> 43 (local bump).
    expect(harness.map.get(REV_KEY)).toBe(43);

    // The peer got the broadcast with the now-active binding…
    expect(viewer.types()).toEqual(["directory"]);
    const broadcast = viewer.frame("directory") as { rev: number; payload: { bindings: Record<string, unknown>[] } };
    expect(broadcast.rev).toBe(43);
    expect(broadcast.payload.bindings[0]).toMatchObject({
      endpointId: ENDPOINT_A,
      status: "active",
      revoked: false,
      appVersion: "1.2.3",
      releaseTrack: "internal",
      capabilities: ["cmux.irx.v1"],
    });

    // …while the confirming socket saw exactly ONE directory (its snapshot,
    // already reflecting its own confirmation at the bumped rev).
    expect(mac.countOf("directory")).toBe(1);
    const snapshot = mac.frame("directory") as { rev: number; payload: { bindings: Record<string, unknown>[] } };
    expect(snapshot.rev).toBe(43);
    expect(snapshot.payload.bindings[0]).toMatchObject({ status: "active" });
  });

  it("skips the confirmation (not the hello) on oversized client info", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const socket = await harness.connect("s1");
    await harness.hello(socket, {
      endpointId: ENDPOINT_A,
      haveRev: null,
      wantPasses: false,
      appVersion: "x".repeat(65), // over MAX_APP_VERSION_CHARS
    });
    expect(socket.types()).toEqual(["hello_ack", "directory", "snapshot_complete"]);
    expect(harness.overlay(ENDPOINT_A)?.status).toBe("seeded");
    expect(harness.map.get(REV_KEY)).toBe(42); // no bump
  });

  it("emits a confirmed device the upstream view omits (synthesized), until the TTL lapses", async () => {
    const harness = new Harness();
    // Upstream only ever lists ENDPOINT_A; ENDPOINT_B exists solely through
    // its own confirmed hello (namespace-filtered upstream views, upstream
    // registration lag, caller self-exclusion all look like this).
    harness.serveDiscovery(() => discoveryResponse(42));

    const socket = await harness.connect("s1", { namespace: "dev.cmux.ios.lsta" });
    await harness.hello(socket, {
      endpointId: ENDPOINT_B,
      haveRev: null,
      wantPasses: false,
      deviceId: "device-b",
      platform: "ios",
      appVersion: "1.2+34",
    });

    const directory = socket.frame("directory") as {
      payload: { bindings: Record<string, unknown>[] };
    };
    const synthesized = directory.payload.bindings.find(
      (binding) => binding.endpointId === ENDPOINT_B,
    );
    expect(synthesized).toMatchObject({
      bindingId: `ctl-hello:${ENDPOINT_B}`,
      clientNamespace: "dev.cmux.ios.lsta",
      deviceId: "device-b",
      status: "active",
      revoked: false,
      appVersion: "1.2+34",
    });

    // Past the directory TTL with no re-confirmation the synthesized entry
    // drops back out: an upstream deletion cannot outlive the trust lease.
    harness.now = T0 + DIRECTORY_TTL_SECONDS * 1000 + 60_000;
    const later = await harness.connect("s2");
    await harness.hello(later, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    const laterDirectory = later.frame("directory") as {
      payload: { bindings: Record<string, unknown>[] };
    };
    expect(
      laterDirectory.payload.bindings.some((binding) => binding.endpointId === ENDPOINT_B),
    ).toBe(false);
  });
});

describe("ack tracking and the alarm retry ladder", () => {
  it("resends the latest directory at 5s/30s/2m/10m then hourly until acked, and stands down on ack", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const socket = await harness.connect("s1", { expiresInMs: 48 * 3_600_000 });
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });

    expect(socket.countOf("directory")).toBe(1);
    expect(socket.getAttachment()?.ackRetry).toEqual({
      rev: 42,
      attempt: 0,
      nextAt: T0 + (ACK_RETRY_LADDER_MS[0] ?? 0),
    });
    // The first rung pulled the alarm forward.
    expect(harness.alarms).toContain(T0 + (ACK_RETRY_LADDER_MS[0] ?? 0));

    // Not due yet: no resend.
    harness.now = T0 + 4_999;
    await harness.core.handleAlarm();
    expect(socket.countOf("directory")).toBe(1);

    // Climb the ladder: 5s, +30s, +2m, +10m, then hourly (twice to prove the
    // steady state repeats). Each retry resends the LATEST directory, never a
    // historical delta.
    const rungs = [
      ACK_RETRY_LADDER_MS[0] ?? 0,
      ACK_RETRY_LADDER_MS[1] ?? 0,
      ACK_RETRY_LADDER_MS[2] ?? 0,
      ACK_RETRY_LADDER_MS[3] ?? 0,
      ACK_RETRY_STEADY_MS,
      ACK_RETRY_STEADY_MS,
    ];
    let at = T0;
    for (const [index, delay] of rungs.entries()) {
      at += delay;
      harness.now = at;
      await harness.core.handleAlarm();
      expect(socket.countOf("directory")).toBe(2 + index);
      const expectedNext = at + (ACK_RETRY_LADDER_MS[index + 1] ?? ACK_RETRY_STEADY_MS);
      expect(socket.getAttachment()?.ackRetry).toEqual({
        rev: 42,
        attempt: index + 1,
        nextAt: expectedNext,
      });
      const resent = socket.lastFrame("directory") as { rev: number; payload: Record<string, unknown> };
      expect(resent.rev).toBe(42);
      expect(resent.payload.issuedAt).toBe(new Date(at).toISOString()); // fresh stamp per resend
    }

    // Ack clears the ladder and mirrors into the device overlay.
    await harness.send(socket, { v: 1, type: "ack", rev: 42, payload: {} });
    expect(socket.getAttachment()?.ackRetry).toBeUndefined();
    expect(socket.getAttachment()?.lastAckedRev).toBe(42);
    expect(harness.overlay(ENDPOINT_A)?.lastAckedRev).toBe(42);

    const sent = socket.countOf("directory");
    harness.now = at + ACK_RETRY_STEADY_MS;
    await harness.core.handleAlarm();
    expect(socket.countOf("directory")).toBe(sent); // no more resends

    // Stale acks are fine and ignored below the watermark.
    await harness.send(socket, { v: 1, type: "ack", rev: 41, payload: {} });
    expect(socket.getAttachment()?.lastAckedRev).toBe(42);
  });

  it("does not arm ack tracking on the haveRev fast path (nothing new was delivered)", async () => {
    const harness = new Harness();
    const seeded = directoryPayloadFromDiscovery(discoveryResponse(42));
    harness.map.set(REV_KEY, 42);
    harness.map.set(DIR_KEY, seeded?.payload);
    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: 42, wantPasses: false });
    expect(socket.types()).toEqual(["hello_ack", "snapshot_complete"]);
    expect(socket.getAttachment()?.ackRetry).toBeUndefined();
  });
});

describe("device revocation", () => {
  async function snapshotted(
    harness: Harness,
    sessionId: string,
    endpointId: string,
  ): Promise<FakeSocket> {
    const socket = await harness.connect(sessionId);
    await harness.hello(socket, { endpointId, haveRev: null, wantPasses: false });
    socket.clearFrames();
    return socket;
  }

  it("broadcasts the revoked directory, closes the device's sockets, refuses mint, and un-revokes", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    harness.serveMint(() => ({ status: 200, json: mintResponse(ENDPOINT_A) }));

    const mac = await snapshotted(harness, "mac", ENDPOINT_A);
    const phone = await snapshotted(harness, "phone", ENDPOINT_B);

    // Pre-revocation mint works.
    await harness.send(mac, { v: 1, type: "mint_request", payload: { endpointId: ENDPOINT_A } });
    expect(mac.types()).toEqual(["relay_passes"]);
    mac.clearFrames();

    const result = await harness.core.handleRevocation({ endpointId: ENDPOINT_A, revoked: true });
    expect(result).toEqual({ rev: 43, changed: true, revoked: true });

    // Immediate broadcast: the peer sees the revoked row at the bumped rev.
    const broadcast = phone.frame("directory") as { rev: number; payload: { bindings: Record<string, unknown>[] } };
    expect(broadcast.rev).toBe(43);
    expect(broadcast.payload.bindings[0]).toMatchObject({ endpointId: ENDPOINT_A, revoked: true });

    // The revoked device's socket was closed 1008 "revoked" and its bearer
    // deleted; the peer's socket stayed open.
    expect(mac.closes).toEqual([{ code: 1008, reason: "revoked" }]);
    expect(harness.map.has(`${BEARER_PREFIX}mac`)).toBe(false);
    expect(phone.closes).toHaveLength(0);

    // A reconnecting revoked device is accepted and may see the list, but its
    // mint is refused (non-retryable) — here via hello wantPasses.
    const back = await harness.connect("mac2");
    await harness.hello(back, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: true });
    expect(back.types()).toEqual(["hello_ack", "directory", "error", "snapshot_complete"]);
    const refusal = back.frame("error") as { payload: Record<string, unknown> };
    expect(refusal.payload).toEqual({
      code: "mint_revoked",
      message: "device revoked for this account",
      retryable: false,
    });
    const seen = back.frame("directory") as { payload: { bindings: Record<string, unknown>[] } };
    expect(seen.payload.bindings[0]).toMatchObject({ endpointId: ENDPOINT_A, revoked: true });
    // Ack tracking armed normally for the delivered snapshot.
    expect(back.getAttachment()?.ackRetry).toMatchObject({ rev: 43 });
    back.clearFrames();

    // Explicit mint_request is refused too.
    await harness.send(back, { v: 1, type: "mint_request", payload: { endpointId: ENDPOINT_A } });
    expect(back.frame("error")?.payload).toMatchObject({ code: "mint_revoked", retryable: false });
    back.clearFrames();

    // Revoking again is idempotent: no bump, no broadcast.
    phone.clearFrames();
    const repeat = await harness.core.handleRevocation({ endpointId: ENDPOINT_A, revoked: true });
    expect(repeat).toEqual({ rev: 43, changed: false, revoked: true });
    expect(phone.frames).toHaveLength(0);

    // Un-revoke: bump + broadcast, and minting works again.
    const restore = await harness.core.handleRevocation({ endpointId: ENDPOINT_A, revoked: false });
    expect(restore).toEqual({ rev: 44, changed: true, revoked: false });
    expect((phone.frame("directory") as { rev: number }).rev).toBe(44);
    expect(
      (phone.frame("directory") as { payload: { bindings: Record<string, unknown>[] } })
        .payload.bindings[0],
    ).toMatchObject({ revoked: false, status: "seeded" }); // status untouched by revocation (orthogonal)
    back.clearFrames();
    await harness.send(back, { v: 1, type: "mint_request", payload: { endpointId: ENDPOINT_A } });
    expect(back.types()).toEqual(["relay_passes"]);
  });

  it("revoking a never-seen endpoint materializes a seeded row so the flag sticks", async () => {
    const harness = new Harness();
    const result = await harness.core.handleRevocation({ endpointId: ENDPOINT_B, revoked: true });
    expect(result.changed).toBe(true);
    expect(harness.overlay(ENDPOINT_B)).toEqual({ status: "seeded", revoked: true });
  });

  it("parseRevocationRequest is strict", () => {
    expect(parseRevocationRequest({ endpointId: ENDPOINT_A, revoked: true }))
      .toEqual({ endpointId: ENDPOINT_A, revoked: true });
    expect(parseRevocationRequest({ endpointId: ENDPOINT_A, revoked: false }))
      .toEqual({ endpointId: ENDPOINT_A, revoked: false });
    expect(parseRevocationRequest(null)).toBeNull();
    expect(parseRevocationRequest({ endpointId: ENDPOINT_A })).toBeNull();
    expect(parseRevocationRequest({ endpointId: ENDPOINT_A, revoked: "true" })).toBeNull();
    expect(parseRevocationRequest({ endpointId: "", revoked: true })).toBeNull();
    expect(parseRevocationRequest({ endpointId: "x".repeat(129), revoked: true })).toBeNull();
    expect(parseRevocationRequest({ endpointId: ENDPOINT_A, revoked: true, accountId: "evil" }))
      .toBeNull();
  });
});

describe("freshness lease and the snapshot_complete 'current' role", () => {
  it("re-stamps issuedAt through snapshot_complete on the haveRev fast path", async () => {
    const harness = new Harness();
    const seeded = directoryPayloadFromDiscovery(discoveryResponse(42, { minimumSupportedVersion: true }));
    harness.map.set(REV_KEY, 42);
    harness.map.set(DIR_KEY, seeded?.payload);

    harness.now = T0 + 12 * 3_600_000; // reconnect much later
    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: 42, wantPasses: false });

    // No directory body — the freshness re-stamp alone re-arms the lease.
    // (Design note: the spec's `current` frame rides the existing
    // snapshot_complete envelope, extended with issuedAt, because the protocol
    // already expressed "your haveRev is head" this way — less invasive than a
    // new frame type.)
    expect(socket.types()).toEqual(["hello_ack", "snapshot_complete"]);
    const complete = socket.frame("snapshot_complete") as { rev: number; payload: Record<string, unknown> };
    expect(complete.rev).toBe(42);
    expect(complete.payload.issuedAt).toBe(new Date(harness.now).toISOString());

    // hello_ack advertises server capabilities and echoes the version floors
    // from the cached directory, so the client holds them pre-body.
    expect(socket.frame("hello_ack")?.payload).toEqual({
      sessionId: "s1",
      resumedFromRev: 42,
      serverCapabilities: [...CONTROL_SERVER_CAPABILITIES],
      minimumSupportedVersion: { mac: "0.30.0", ios: "1.4.0" },
    });
  });

  it("carries minimumSupportedVersion inside the directory when the broker publishes it", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42, { minimumSupportedVersion: true }));
    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    const payload = (socket.frame("directory") as { payload: Record<string, unknown> }).payload;
    expect(payload.minimumSupportedVersion).toEqual({ mac: "0.30.0", ios: "1.4.0" });
  });
});
