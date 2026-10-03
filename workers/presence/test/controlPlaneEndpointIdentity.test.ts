// Endpoint-id identity on the ControlPlaneCore: one iroh endpoint id names a
// 32-byte key, and the relay parses BOTH its 64-char hex spelling and its
// 52-char RFC 4648 base32 spelling (each case-insensitively) as the SAME key.
// Every trust decision in the control plane — revocation checks, overlay
// rows, socket ownership, credential minting, hint fan-out — must therefore
// collapse every accepted spelling to one canonical form, and must refuse
// spellings that are not an endpoint id at all.

import { describe, expect, it } from "bun:test";
import {
  BEARER_PREFIX,
  ControlPlaneCore,
  DEV_PREFIX,
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
// RFC 4648 base32 (no padding, lowercased) of the same 32 bytes ENDPOINT_A
// spells in hex: python3 base64.b32encode(bytes.fromhex("aa"*32)).
const ENDPOINT_A_BASE32 = `${"vk".repeat(25)}va`;
const RELAY_1 = "https://usw1.relay.example/";
const RELAY_2 = "https://use4.relay.example/";

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
    relay_fleet: [RELAY_1, RELAY_2],
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
    this.closes.push({
      ...(code !== undefined ? { code } : {}),
      ...(reason !== undefined ? { reason } : {}),
    });
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

/// Mirrors the Durable Object adapter, which recreates a fresh transport
/// wrapper every time the core enumerates hibernating sockets.
class FreshSocketView implements CtlSocket {
  constructor(private readonly base: FakeSocket) {}

  send(data: string): void {
    this.base.send(data);
  }

  close(code?: number, reason?: string): void {
    this.base.close(code, reason);
  }

  getAttachment(): CtlAttachment | null {
    return this.base.getAttachment();
  }

  setAttachment(attachment: CtlAttachment): void {
    this.base.setAttachment(attachment);
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
    sockets: () => this.socketList.map((socket) => new FreshSocketView(socket)),
  });

  serveDiscovery(response: () => unknown): void {
    this.routes.set("/api/devices/iroh", () => ({ status: 200, json: response() }));
  }

  serveMint(handler: UpstreamHandler): void {
    this.routes.set("/api/relay/token", handler);
  }

  mintCalls(): { path: string; init: CtlUpstreamInit }[] {
    return this.calls.filter((call) => call.path === "/api/relay/token");
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

  async send(socket: FakeSocket, frame: unknown): Promise<void> {
    await this.core.handleMessage(socket, JSON.stringify(frame));
  }

  async hello(socket: FakeSocket, payload: Record<string, unknown>): Promise<void> {
    await this.send(socket, { v: 1, type: "hello", payload });
  }

  async snapshotted(sessionId: string, endpointId: string): Promise<FakeSocket> {
    const socket = await this.connect(sessionId);
    await this.hello(socket, { endpointId, haveRev: null, wantPasses: false });
    socket.clearFrames();
    return socket;
  }

  overlay(endpointId: string): DeviceOverlay | undefined {
    return this.map.get(DEV_PREFIX + endpointId) as DeviceOverlay | undefined;
  }
}

describe("revocation holds across every accepted endpoint-id encoding", () => {
  it("refuses credentials for the base32 spelling of a revoked id", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    harness.serveMint(() => ({ status: 200, json: mintResponse(ENDPOINT_A) }));
    const mac = await harness.snapshotted("mac", ENDPOINT_A);

    await harness.core.handleRevocation({ endpointId: ENDPOINT_A, revoked: true });
    expect(mac.closes).toEqual([{ code: 1008, reason: "revoked" }]);

    // The revoked device re-presents itself entirely under the other
    // accepted encoding: hello AND mint both spell the id in base32.
    const back = await harness.connect("mac2");
    await harness.hello(back, { endpointId: ENDPOINT_A_BASE32, haveRev: null, wantPasses: false });
    back.clearFrames();
    await harness.send(back, {
      v: 1,
      type: "mint_request",
      payload: { endpointId: ENDPOINT_A_BASE32 },
    });
    expect(back.frame("error")?.payload).toMatchObject({
      code: "mint_revoked",
      retryable: false,
    });
    expect(back.frame("relay_passes")).toBeUndefined();
    expect(harness.mintCalls()).toHaveLength(0);
  });

  it("refuses the pre-hello mint for every spelling of a revoked id", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    harness.serveMint(() => ({ status: 200, json: mintResponse(ENDPOINT_A) }));
    await harness.core.handleRevocation({ endpointId: ENDPOINT_A, revoked: true });

    const spellings = [
      ENDPOINT_A.toUpperCase(),
      `  ${ENDPOINT_A}  `,
      ENDPOINT_A_BASE32,
      ENDPOINT_A_BASE32.toUpperCase(),
      ` ${ENDPOINT_A_BASE32.toUpperCase()} `,
    ];
    for (const [index, spelling] of spellings.entries()) {
      // No hello on this socket: the mint admission itself is the gate.
      const socket = await harness.connect(`fresh-${index}`);
      await harness.send(socket, {
        v: 1,
        type: "mint_request",
        payload: { endpointId: spelling },
      });
      expect(socket.frame("error")?.payload).toMatchObject({
        code: "mint_revoked",
        retryable: false,
      });
      expect(socket.frame("relay_passes")).toBeUndefined();
    }
    expect(harness.mintCalls()).toHaveLength(0);
  });

  it("closes the socket and purges the bearer of a device helloed under base32", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const mac = await harness.snapshotted("mac", ENDPOINT_A_BASE32);

    await harness.core.handleRevocation({ endpointId: ENDPOINT_A, revoked: true });

    expect(mac.closes).toEqual([{ code: 1008, reason: "revoked" }]);
    expect(harness.map.has(`${BEARER_PREFIX}mac`)).toBe(false);
  });

  it("keeps a variant-spelling hello from resurrecting an unrevoked row", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    await harness.core.handleRevocation({ endpointId: ENDPOINT_B, revoked: true });

    // The revoked device confirms itself under another spelling of its id.
    const device = await harness.connect("device");
    await harness.hello(device, {
      endpointId: ENDPOINT_B.toUpperCase(),
      haveRev: null,
      wantPasses: false,
      appVersion: "9.9.9",
    });

    // A peer's directory must show ONE row for that endpoint, still revoked.
    const peer = await harness.connect("peer");
    await harness.hello(peer, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    const directory = peer.frame("directory") as {
      payload: { bindings: { endpointId: string; revoked: boolean }[] };
    };
    const rows = directory.payload.bindings.filter(
      (binding) => binding.endpointId.toLowerCase() === ENDPOINT_B,
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ endpointId: ENDPOINT_B, revoked: true });
  });

  it("honors a revocation a legacy row stored under a variant spelling", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    harness.serveMint(() => ({ status: 200, json: mintResponse(ENDPOINT_A) }));
    // An older deploy stored the flag under the spelling it was given.
    harness.map.set(DEV_PREFIX + ENDPOINT_A.toUpperCase(), {
      status: "active",
      revoked: true,
      lastConfirmedAt: new Date(T0).toISOString(),
    } satisfies DeviceOverlay);

    const socket = await harness.connect("s1");
    await harness.send(socket, {
      v: 1,
      type: "mint_request",
      payload: { endpointId: ENDPOINT_A },
    });
    expect(socket.frame("error")?.payload).toMatchObject({
      code: "mint_revoked",
      retryable: false,
    });
    expect(harness.mintCalls()).toHaveLength(0);
  });
});

describe("endpoint-id grammar is enforced at every ingress", () => {
  it("never forwards a malformed mint id upstream", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    harness.serveMint(() => ({ status: 200, json: mintResponse(ENDPOINT_A) }));
    const socket = await harness.snapshotted("s1", ENDPOINT_A);

    for (const bad of [
      "not-an-endpoint-id",
      "g".repeat(64), // not hex
      "a".repeat(63), // wrong hex length
      `${"vk".repeat(25)}vb`, // base32 with non-zero trailing bits
      `${ENDPOINT_A_BASE32}====`, // padded base32
    ]) {
      await harness.send(socket, { v: 1, type: "mint_request", payload: { endpointId: bad } });
      expect(socket.frame("relay_passes")).toBeUndefined();
      socket.clearFrames();
    }
    expect(harness.mintCalls()).toHaveLength(0);
  });

  it("rejects a hello that does not carry an endpoint id", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const socket = await harness.connect("s1");
    await harness.hello(socket, { endpointId: "device-7", haveRev: null, wantPasses: false });
    expect(socket.frame("hello_ack")).toBeUndefined();
    // The socket is not consumed: a well-formed hello still completes.
    socket.clearFrames();
    await harness.hello(socket, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    expect(socket.types()).toEqual(["hello_ack", "directory", "snapshot_complete"]);
  });

  it("rejects malformed revocation ids", () => {
    expect(parseRevocationRequest({ endpointId: "device-7", revoked: true })).toBeNull();
    expect(parseRevocationRequest({ endpointId: "g".repeat(64), revoked: true })).toBeNull();
    expect(
      parseRevocationRequest({ endpointId: `${"vk".repeat(25)}vb`, revoked: true }),
    ).toBeNull();
  });
});

describe("one canonical identity behind every spelling", () => {
  it("stores the confirm-on-hello overlay under the canonical spelling", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const socket = await harness.connect("s1");
    await harness.hello(socket, {
      endpointId: ENDPOINT_B.toUpperCase(),
      haveRev: null,
      wantPasses: false,
      appVersion: "1.2.3",
    });
    expect(harness.overlay(ENDPOINT_B)).toMatchObject({ status: "active" });
    expect(harness.overlay(ENDPOINT_B.toUpperCase())).toBeUndefined();
  });

  it("binds passes and the generation counter to the canonical id", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    harness.serveMint((init) => ({
      status: 200,
      json: mintResponse((JSON.parse(init.body ?? "{}") as { endpointId: string }).endpointId),
    }));
    const socket = await harness.snapshotted("s1", ENDPOINT_A);

    await harness.send(socket, {
      v: 1,
      type: "mint_request",
      payload: { endpointId: ENDPOINT_A },
    });
    await harness.send(socket, {
      v: 1,
      type: "mint_request",
      payload: { endpointId: ENDPOINT_A_BASE32 },
    });

    const passes = harness.mintCalls().map((call) =>
      (JSON.parse(call.init.body ?? "{}") as { endpointId: string }).endpointId,
    );
    // Both spellings reach upstream as the one canonical id…
    expect(passes).toEqual([ENDPOINT_A, ENDPOINT_A]);
    // …and the generation counter advances as one endpoint, not two.
    const frames = socket.frames.filter((frame) => frame.type === "relay_passes") as {
      payload: { endpointId: string; passes: { generation: number }[] };
    }[];
    expect(frames.map((frame) => frame.payload.endpointId))
      .toEqual([ENDPOINT_A, ENDPOINT_A]);
    expect(frames.map((frame) => frame.payload.passes[0]?.generation)).toEqual([1, 2]);
  });

  it("supersedes the older socket when the same endpoint hellos under base32", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const first = await harness.connect("first");
    await harness.hello(first, { endpointId: ENDPOINT_A, haveRev: null, wantPasses: false });
    const replacement = await harness.connect("replacement");
    await harness.hello(replacement, {
      endpointId: ENDPOINT_A_BASE32,
      haveRev: null,
      wantPasses: false,
    });
    expect(first.closes).toEqual([{ code: 1000, reason: "superseded" }]);
    expect(harness.map.has(`${BEARER_PREFIX}first`)).toBe(false);
  });

  it("fans out hints under the canonical id whatever the announcer spelled", async () => {
    const harness = new Harness();
    harness.serveDiscovery(() => discoveryResponse(42));
    const mac = await harness.snapshotted("mac", ENDPOINT_A);
    const phone = await harness.snapshotted("phone", ENDPOINT_B);

    await harness.send(mac, {
      v: 1,
      type: "publish_hint",
      payload: { endpointId: ENDPOINT_A_BASE32.toUpperCase(), homeRelayUrl: RELAY_2 },
    });
    const update = phone.frame("hint_update") as { payload: Record<string, unknown> };
    expect(update.payload.endpointId).toBe(ENDPOINT_A);
    expect(update.payload.homeRelayUrl).toBe(RELAY_2);
  });
});
