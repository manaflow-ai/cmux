// Behavior tests for the HostRelay Durable Object's forwarding plane, pinned
// so the zero-copy fast path stays provably behavior-neutral: session-id
// stamping, verbatim host->client routing, malformed/oversized frame
// rejection, close semantics, and cache correctness across a simulated
// hibernation wake (a fresh instance over the same accepted sockets).
//
// The DO runs against in-memory fakes of the Workers runtime pieces it
// touches (DurableObject base, WebSocketPair, socket attachments, storage).
// Typechecked by tsconfig.worker-test.json (workers + bun types); excluded
// from tsconfig.test.json, whose bun-only types cannot see the runtime.

import { describe, expect, mock, test } from "bun:test";
import {
  BYE_EXPIRED,
  BYE_HOST_CLOSED,
  BYE_PROTOCOL_ERROR,
  BYE_SUPERSEDED,
  DATA_HEADER_BYTES,
  encodeDataFrame,
  MAX_CLIENTS,
  MAX_DATA_FRAME_BYTES,
} from "../src/protocol";

mock.module("cloudflare:workers", () => ({
  DurableObject: class {
    protected ctx: unknown;
    protected env: unknown;
    constructor(ctx: unknown, env: unknown) {
      this.ctx = ctx;
      this.env = env;
    }
  },
}));

class FakeWebSocket {
  readonly sent: (string | ArrayBuffer)[] = [];
  readonly closes: { code: number; reason?: string }[] = [];
  private attachmentValue: unknown;

  serializeAttachment(value: unknown): void {
    this.attachmentValue = structuredClone(value);
  }

  deserializeAttachment(): unknown {
    return structuredClone(this.attachmentValue);
  }

  send(data: string | ArrayBuffer): void {
    this.sent.push(data);
  }

  close(code: number, reason?: string): void {
    this.closes.push({ code, reason });
  }

  /** Text frames sent by the relay, JSON-parsed. */
  controlMessages(): { t: string; [key: string]: unknown }[] {
    return this.sent
      .filter((entry): entry is string => typeof entry === "string")
      .map((entry) => JSON.parse(entry) as { t: string });
  }

  binaryFrames(): Uint8Array[] {
    return this.sent
      .filter((entry): entry is ArrayBuffer => typeof entry !== "string")
      .map((entry) => new Uint8Array(entry));
  }
}

class FakeWebSocketPair {
  0 = new FakeWebSocket();
  1 = new FakeWebSocket();
}

class FakeWebSocketRequestResponsePair {
  constructor(
    readonly request: string,
    readonly response: string,
  ) {}
}

(globalThis as Record<string, unknown>).WebSocketPair = FakeWebSocketPair;
(globalThis as Record<string, unknown>).WebSocketRequestResponsePair =
  FakeWebSocketRequestResponsePair;

class FakeState {
  private sockets: { ws: FakeWebSocket; tags: string[] }[] = [];
  readonly storage = {
    data: new Map<string, unknown>(),
    alarms: [] as number[],
    async get(key: string): Promise<unknown> {
      return this.data.get(key);
    },
    async put(key: string, value: unknown): Promise<void> {
      this.data.set(key, value);
    },
    async setAlarm(time: number): Promise<void> {
      this.alarms.push(time);
    },
  };

  acceptWebSocket(ws: FakeWebSocket, tags?: string[]): void {
    this.sockets.push({ ws, tags: tags ?? [] });
  }

  getWebSockets(tag?: string): FakeWebSocket[] {
    return this.sockets
      .filter((entry) => tag === undefined || entry.tags.includes(tag))
      .map((entry) => entry.ws);
  }

  setWebSocketAutoResponse(_pair: unknown): void {}

  /** The runtime removing a closed socket from the accepted list. */
  drop(ws: FakeWebSocket): void {
    this.sockets = this.sockets.filter((entry) => entry.ws !== ws);
  }
}

const { HostRelay } = await import("../src/do");

type Relay = InstanceType<typeof HostRelay>;

function makeRelay(state?: FakeState): { relay: Relay; state: FakeState } {
  const backing = state ?? new FakeState();
  const relay = new HostRelay(
    backing as unknown as DurableObjectState,
    {} as never,
  );
  return { relay, state: backing };
}

function asWS(fake: FakeWebSocket): WebSocket {
  return fake as unknown as WebSocket;
}

async function connect(
  relay: Relay,
  state: FakeState,
  role: "host" | "client",
  deviceId: string,
): Promise<{ socket: FakeWebSocket; status: number }> {
  const before = new Set(state.getWebSockets());
  const response = await relay.fetch(
    new Request("https://relay.test/v1/connect", {
      headers: {
        upgrade: "websocket",
        "x-relay-role": role,
        "x-relay-user-id": "user-1",
        "x-relay-host-device-id": "device-host",
        "x-relay-device-id": deviceId,
      },
    }),
  );
  const added = state.getWebSockets().find((ws) => !before.has(ws));
  return { socket: added ?? new FakeWebSocket(), status: response.status };
}

function frameBytes(sessionId: number, payload: number[]): ArrayBuffer {
  const frame = encodeDataFrame(sessionId, new Uint8Array(payload));
  return frame.buffer as ArrayBuffer;
}

describe("HostRelay forwarding", () => {
  test("welcome and peer_joined bookkeeping", async () => {
    const { relay, state } = makeRelay();
    const host = (await connect(relay, state, "host", "device-host")).socket;
    const client = (await connect(relay, state, "client", "phone-1")).socket;

    const hostWelcome = host.controlMessages()[0]!;
    expect(hostWelcome.t).toBe("welcome");
    expect(hostWelcome.sessionId).toBe(0);
    const clientWelcome = client.controlMessages()[0]!;
    expect(clientWelcome.t).toBe("welcome");
    expect(clientWelcome.sessionId).toBe(1);
    expect(clientWelcome.hostPresent).toBe(true);
    expect(host.controlMessages()[1]).toMatchObject({
      t: "peer_joined",
      sessionId: 1,
      deviceId: "phone-1",
    });
  });

  test("client frames reach the host with the session id stamped", async () => {
    const { relay, state } = makeRelay();
    const host = (await connect(relay, state, "host", "device-host")).socket;
    const client = (await connect(relay, state, "client", "phone-1")).socket;

    // Wire carries a forged session id; the relay must overwrite it.
    await relay.webSocketMessage(asWS(client), frameBytes(0xdead, [7, 8, 9]));

    const forwarded = host.binaryFrames();
    expect(forwarded.length).toBe(1);
    expect(Array.from(forwarded[0]!)).toEqual([1, 0, 0, 0, 1, 7, 8, 9]);
    expect(client.closes.length).toBe(0);
  });

  test("host frames route to the addressed client verbatim", async () => {
    const { relay, state } = makeRelay();
    const host = (await connect(relay, state, "host", "device-host")).socket;
    const clientA = (await connect(relay, state, "client", "phone-a")).socket;
    const clientB = (await connect(relay, state, "client", "phone-b")).socket;

    await relay.webSocketMessage(asWS(host), frameBytes(2, [42]));

    expect(clientA.binaryFrames().length).toBe(0);
    const received = clientB.binaryFrames();
    expect(received.length).toBe(1);
    expect(Array.from(received[0]!)).toEqual([1, 0, 0, 0, 2, 42]);
  });

  test("host frames to an unknown session are dropped without closing", async () => {
    const { relay, state } = makeRelay();
    const host = (await connect(relay, state, "host", "device-host")).socket;
    const client = (await connect(relay, state, "client", "phone-1")).socket;

    await relay.webSocketMessage(asWS(host), frameBytes(99, [1]));

    expect(client.binaryFrames().length).toBe(0);
    expect(host.closes.length).toBe(0);
  });

  test("client frames with no host are dropped without closing", async () => {
    const { relay, state } = makeRelay();
    const client = (await connect(relay, state, "client", "phone-1")).socket;

    await relay.webSocketMessage(asWS(client), frameBytes(1, [1]));

    expect(client.closes.length).toBe(0);
    expect(client.binaryFrames().length).toBe(0);
  });

  test("forwarding still works on a fresh instance over the same sockets", async () => {
    // A hibernation wake constructs a new object; the attachment caches and
    // session index must rebuild from the accepted sockets.
    const { relay, state } = makeRelay();
    const host = (await connect(relay, state, "host", "device-host")).socket;
    const client = (await connect(relay, state, "client", "phone-1")).socket;

    const { relay: woken } = makeRelay(state);
    await woken.webSocketMessage(asWS(client), frameBytes(0, [5]));
    await woken.webSocketMessage(asWS(host), frameBytes(1, [6]));

    expect(Array.from(host.binaryFrames()[0]!)).toEqual([1, 0, 0, 0, 1, 5]);
    expect(Array.from(client.binaryFrames()[0]!)).toEqual([1, 0, 0, 0, 1, 6]);
  });

  test("session ids are never reused across instances", async () => {
    const { relay, state } = makeRelay();
    await connect(relay, state, "client", "phone-1");
    const { relay: woken } = makeRelay(state);
    const second = await connect(woken, state, "client", "phone-2");
    expect(second.socket.controlMessages()[0]!.sessionId).toBe(2);
  });

  test("oversized frames close the sender with protocol_error", async () => {
    const { relay, state } = makeRelay();
    const host = (await connect(relay, state, "host", "device-host")).socket;
    const client = (await connect(relay, state, "client", "phone-1")).socket;

    const oversized = new Uint8Array(MAX_DATA_FRAME_BYTES + 1);
    oversized[0] = 1;
    await relay.webSocketMessage(asWS(client), oversized.buffer as ArrayBuffer);

    const bye = client.controlMessages().find((message) => message.t === "bye");
    expect(bye).toMatchObject({ t: "bye", code: BYE_PROTOCOL_ERROR });
    expect(client.closes).toEqual([{ code: 1000, reason: BYE_PROTOCOL_ERROR }]);
    expect(host.controlMessages().at(-1)).toMatchObject({
      t: "peer_left",
      sessionId: 1,
      reason: BYE_PROTOCOL_ERROR,
    });
    expect(host.binaryFrames().length).toBe(0);
  });

  test("truncated and mistyped frames are protocol errors", async () => {
    const { relay, state } = makeRelay();
    await connect(relay, state, "host", "device-host");
    const client = (await connect(relay, state, "client", "phone-1")).socket;
    const truncated = new Uint8Array(DATA_HEADER_BYTES - 1);
    truncated[0] = 1;
    await relay.webSocketMessage(asWS(client), truncated.buffer as ArrayBuffer);
    expect(client.closes).toEqual([{ code: 1000, reason: BYE_PROTOCOL_ERROR }]);

    const { relay: second, state: secondState } = makeRelay();
    await connect(second, secondState, "host", "device-host");
    const mistyped = (await connect(second, secondState, "client", "phone-2")).socket;
    const wrongType = encodeDataFrame(1, new Uint8Array([1]));
    wrongType[0] = 9;
    await second.webSocketMessage(asWS(mistyped), wrongType.buffer as ArrayBuffer);
    expect(mistyped.closes).toEqual([{ code: 1000, reason: BYE_PROTOCOL_ERROR }]);
  });

  test("client close notifies the host; host close notifies every client", async () => {
    const { relay, state } = makeRelay();
    const host = (await connect(relay, state, "host", "device-host")).socket;
    const clientA = (await connect(relay, state, "client", "phone-a")).socket;
    const clientB = (await connect(relay, state, "client", "phone-b")).socket;

    await relay.webSocketClose(asWS(clientA));
    state.drop(clientA);
    expect(host.controlMessages().at(-1)).toMatchObject({
      t: "peer_left",
      sessionId: 1,
      reason: "closed",
    });

    // A frame addressed to the departed session drops after the close.
    await relay.webSocketMessage(asWS(host), frameBytes(1, [1]));
    expect(clientA.binaryFrames().length).toBe(0);

    await relay.webSocketClose(asWS(host));
    state.drop(host);
    expect(clientB.controlMessages().at(-1)).toMatchObject({
      t: "peer_left",
      sessionId: 0,
      reason: "closed",
    });
  });

  test("close_session from the host closes the client with host_closed", async () => {
    const { relay, state } = makeRelay();
    const host = (await connect(relay, state, "host", "device-host")).socket;
    const client = (await connect(relay, state, "client", "phone-1")).socket;

    await relay.webSocketMessage(
      asWS(host),
      JSON.stringify({ t: "close_session", sessionId: 1 }),
    );

    const bye = client.controlMessages().find((message) => message.t === "bye");
    expect(bye).toMatchObject({ t: "bye", code: BYE_HOST_CLOSED });
    expect(client.closes).toEqual([{ code: 1000, reason: BYE_HOST_CLOSED }]);
    expect(host.controlMessages().at(-1)).toMatchObject({
      t: "peer_left",
      sessionId: 1,
      reason: BYE_HOST_CLOSED,
    });
  });

  test("close_session from a client is ignored", async () => {
    const { relay, state } = makeRelay();
    await connect(relay, state, "host", "device-host");
    const clientA = (await connect(relay, state, "client", "phone-a")).socket;
    const clientB = (await connect(relay, state, "client", "phone-b")).socket;

    await relay.webSocketMessage(
      asWS(clientA),
      JSON.stringify({ t: "close_session", sessionId: 2 }),
    );

    expect(clientB.closes.length).toBe(0);
    expect(clientA.closes.length).toBe(0);
  });

  test("a reconnecting host supersedes the previous host socket", async () => {
    const { relay, state } = makeRelay();
    const first = (await connect(relay, state, "host", "device-host")).socket;
    const second = (await connect(relay, state, "host", "device-host")).socket;

    expect(first.controlMessages().at(-1)).toMatchObject({
      t: "bye",
      code: BYE_SUPERSEDED,
    });
    expect(first.closes).toEqual([{ code: 1000, reason: BYE_SUPERSEDED }]);
    expect(second.closes.length).toBe(0);
  });

  test("client connects beyond capacity are refused", async () => {
    const { relay, state } = makeRelay();
    await connect(relay, state, "host", "device-host");
    for (let index = 0; index < MAX_CLIENTS; index += 1) {
      expect((await connect(relay, state, "client", `phone-${index}`)).status).toBe(101);
    }
    expect((await connect(relay, state, "client", "phone-overflow")).status).toBe(429);
  });

  test("messages after the deadline close the socket with expired", async () => {
    const { relay, state } = makeRelay();
    const host = (await connect(relay, state, "host", "device-host")).socket;
    const client = (await connect(relay, state, "client", "phone-1")).socket;

    // Force the persisted deadline into the past, then wake a fresh instance
    // so no cached copy can mask it.
    const stale = client.deserializeAttachment() as { deadline: number };
    client.serializeAttachment({ ...stale, deadline: Date.now() - 1 });
    const { relay: woken } = makeRelay(state);
    await woken.webSocketMessage(asWS(client), frameBytes(1, [1]));

    expect(client.controlMessages().find((message) => message.t === "bye")).toMatchObject({
      t: "bye",
      code: BYE_EXPIRED,
    });
    expect(client.closes).toEqual([{ code: 1000, reason: BYE_EXPIRED }]);
    expect(host.binaryFrames().length).toBe(0);
  });
});
