// Dashboard read model + retire on the ControlPlaneCore: the account device
// list as cmux.com reads it (status, revoked, version/track, ack watermarks,
// connected state, head revision), the read-only contract (a GET never
// creates overlay rows), and the retire lifecycle flip (cleanup, not a
// security action; un-retires on the device's next confirm-on-hello).

import { describe, expect, it } from "bun:test";
import {
  ControlPlaneCore,
  DEV_PREFIX,
  DIR_KEY,
  DIRECTORY_TTL_SECONDS,
  REV_KEY,
  parseRetireRequest,
  type BrokerDirectoryPayload,
  type CtlAttachment,
  type CtlSocket,
  type CtlUpstreamInit,
  type CtlUpstreamResult,
  type DashboardSnapshot,
  type DeviceOverlay,
} from "../src/controlPlane";

const T0 = 1_800_000_000_000;
const ENDPOINT_A = "a".repeat(64);
const ENDPOINT_B = "b".repeat(64);
const ENDPOINT_C = "c".repeat(64);
const RELAY_1 = "https://usw1.relay.example/";

function discoveryResponse(revision: number): unknown {
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
    relay_fleet: [RELAY_1],
    grant_verification_keys: {
      version: 1,
      current_kid: "k1",
      keys: [{ kid: "k1", alg: "EdDSA", spki_der_base64: "MCowBQYDK2VwAyEA" }],
    },
    minimum_supported_version: { mac: "0.30.0", ios: "1.4.0" },
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

  countOf(type: string): number {
    return this.frames.filter((frame) => frame.type === type).length;
  }
}

type UpstreamHandler = (init: CtlUpstreamInit) => CtlUpstreamResult;

class Harness {
  now = T0;
  map = new Map<string, unknown>();
  alarms: number[] = [];
  socketList: FakeSocket[] = [];
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

  async connect(sessionId: string): Promise<FakeSocket> {
    const socket = new FakeSocket();
    this.socketList.push(socket);
    await this.core.handleConnect(socket, {
      sessionId,
      expiresAt: this.now + 15 * 60_000,
      bearer: `token-${sessionId}`,
    });
    return socket;
  }

  async hello(socket: FakeSocket, payload: Record<string, unknown>): Promise<void> {
    await this.core.handleMessage(socket, JSON.stringify({ v: 1, type: "hello", payload }));
  }

  overlay(endpointId: string): DeviceOverlay | undefined {
    return this.map.get(DEV_PREFIX + endpointId) as DeviceOverlay | undefined;
  }

  overlayKeys(): string[] {
    return [...this.map.keys()].filter((key) => key.startsWith(DEV_PREFIX));
  }
}

describe("dashboardSnapshot", () => {
  it("joins the overlay onto broker bindings with connected + ack state", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));

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
    // Ack the delivered snapshot revision so the watermark is visible.
    // (First hello: the confirm bump precedes the broker fetch, so head lands
    // at the broker's own revision.)
    await harness.core.handleMessage(mac, JSON.stringify({ v: 1, type: "ack", rev: 42, payload: {} }));

    const snapshot = await harness.core.dashboardSnapshot();
    expect(snapshot.rev).toBe(42);
    expect(snapshot.ttlSeconds).toBe(DIRECTORY_TTL_SECONDS);
    expect(snapshot.minimumSupportedVersion).toEqual({ mac: "0.30.0", ios: "1.4.0" });
    expect(snapshot.devices).toHaveLength(1);
    expect(snapshot.devices[0]).toMatchObject({
      endpointId: ENDPOINT_A,
      listed: true,
      deviceId: "77116c35-0000-4000-8000-000000000001",
      clientNamespace: "irx",
      status: "active",
      revoked: false,
      appVersion: "1.2.3",
      releaseTrack: "internal",
      capabilities: ["cmux.irx.v1"],
      lastAckedRev: 42,
      connected: true,
    });
  });

  it("is read-only: never creates overlay rows for unseen bindings", async () => {
    const harness = new Harness();
    const broker: BrokerDirectoryPayload = {
      routeContractVersion: 1,
      bindings: [
        { bindingId: "b-1", endpointId: ENDPOINT_A, clientNamespace: "irx" },
      ],
      relayFleet: [RELAY_1],
      grantVerificationKeys: [],
    };
    harness.map.set(DIR_KEY, broker);
    harness.map.set(REV_KEY, 7);

    const snapshot = await harness.core.dashboardSnapshot();
    expect(snapshot.rev).toBe(7);
    expect(snapshot.devices).toHaveLength(1);
    // The row is served with seeded defaults…
    expect(snapshot.devices[0]).toMatchObject({
      endpointId: ENDPOINT_A,
      listed: true,
      status: "seeded",
      revoked: false,
      connected: false,
    });
    // …but nothing was materialized in storage by the read.
    expect(harness.overlayKeys()).toEqual([]);
  });

  it("keeps overlay-only rows visible as listed=false so revocation survives a binding flap", async () => {
    const harness = new Harness();
    harness.map.set(REV_KEY, 9);
    const overlay: DeviceOverlay = {
      status: "active",
      revoked: true,
      deviceId: "dead-device",
      clientNamespace: "irx",
      appVersion: "0.9.9",
      releaseTrack: "beta",
    };
    harness.map.set(DEV_PREFIX + ENDPOINT_C, overlay);

    const snapshot: DashboardSnapshot = await harness.core.dashboardSnapshot();
    expect(snapshot.devices).toHaveLength(1);
    expect(snapshot.devices[0]).toMatchObject({
      endpointId: ENDPOINT_C,
      listed: false,
      bindingId: null,
      deviceId: "dead-device",
      status: "active",
      revoked: true,
      appVersion: "0.9.9",
      releaseTrack: "beta",
      connected: false,
    });
  });
});

describe("parseRetireRequest", () => {
  it("accepts exactly {endpointId}", () => {
    expect(parseRetireRequest({ endpointId: ENDPOINT_A })).toEqual({ endpointId: ENDPOINT_A });
  });

  it("rejects extra keys, empty, oversized, and non-string ids", () => {
    expect(parseRetireRequest({ endpointId: ENDPOINT_A, revoked: true })).toBeNull();
    expect(parseRetireRequest({ endpointId: "" })).toBeNull();
    expect(parseRetireRequest({ endpointId: "x".repeat(129) })).toBeNull();
    expect(parseRetireRequest({ endpointId: 42 })).toBeNull();
    expect(parseRetireRequest("not-an-object")).toBeNull();
    expect(parseRetireRequest({})).toBeNull();
  });
});

describe("handleRetire", () => {
  it("flips status to retired, bumps the revision, and broadcasts", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));

    const viewer = await harness.connect("viewer");
    await harness.hello(viewer, { endpointId: ENDPOINT_B, haveRev: null, wantPasses: false });
    const before = viewer.countOf("directory");

    const result = await harness.core.handleRetire({ endpointId: ENDPOINT_A });
    expect(result).toEqual({ rev: 43, changed: true, status: "retired" });
    expect(harness.overlay(ENDPOINT_A)?.status).toBe("retired");
    // revoked is orthogonal and untouched by retire.
    expect(harness.overlay(ENDPOINT_A)?.revoked).toBe(false);
    expect(viewer.countOf("directory")).toBe(before + 1);

    // Idempotent: a second retire is a no-op at the same revision.
    const again = await harness.core.handleRetire({ endpointId: ENDPOINT_A });
    expect(again).toEqual({ rev: 43, changed: false, status: "retired" });
    expect(viewer.countOf("directory")).toBe(before + 1);
  });

  it("un-retires on the device's next confirm-on-hello", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));

    const viewer = await harness.connect("viewer");
    await harness.hello(viewer, { endpointId: ENDPOINT_B, haveRev: null, wantPasses: false });
    await harness.core.handleRetire({ endpointId: ENDPOINT_A });
    expect(harness.overlay(ENDPOINT_A)?.status).toBe("retired");

    const mac = await harness.connect("mac");
    await harness.hello(mac, {
      endpointId: ENDPOINT_A,
      haveRev: null,
      wantPasses: false,
      deviceId: "77116c35-0000-4000-8000-000000000001",
      platform: "mac",
      appVersion: "1.2.4",
      releaseTrack: "internal",
    });
    expect(harness.overlay(ENDPOINT_A)?.status).toBe("active");

    const snapshot = await harness.core.dashboardSnapshot();
    const row = snapshot.devices.find((device) => device.endpointId === ENDPOINT_A);
    expect(row?.status).toBe("active");
    expect(row?.connected).toBe(true);
  });
});
