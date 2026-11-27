import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import {
  clearBrowserDeviceIdentity,
  setBrowserDeviceEnrollment,
  connectBrowserDevice,
  prepareBrowserDevice,
} from "./browserDevice";
import { AcpWireLog } from "./wire";

const dom = new JSDOM("<!doctype html>", { url: "https://device.example/app/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterEach(clearBrowserDeviceIdentity);
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key] === undefined) delete scope[key];
    else scope[key] = saved[key];
});

const enroll = () =>
  setBrowserDeviceEnrollment({
    accessToken: "access-secret",
    publicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  });

async function fixture(options: { refuse?: string; holdHello?: boolean } = {}) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const calls: { id: number | string; method: string; params: Record<string, unknown> }[] = [];
  const sockets: WebSocket[] = [];
  let answerHello = () => {};
  let helloStarted = () => {};
  const helloSeen = new Promise<void>((resolve) => {
    helloStarted = resolve;
  });
  const wire = new AcpWireLog();
  const host = {
    ...mockHost,
    transport: "acpmux-websocket" as const,
    endpoint: "wss://device.example/",
    token: "listener-secret",
    browserDevice: true,
  };
  const connect = (override = {}) =>
    AcpmuxDirectClient.connect(
      { ...host, ...override },
      () => {},
      undefined,
      () => {
        const socket = new MockAcpmuxSocket(() => Promise.resolve());
        const send = socket.send.bind(socket);
        socket.send = (raw) => {
          const request = JSON.parse(raw);
          calls.push(request);
          const reply = (result: unknown) =>
            queueMicrotask(() => socket.onmessage?.({ data: JSON.stringify({ id: request.id, result }) }));
          if (request.method === "_acpmux/device_enroll") {
            if (options.refuse)
              queueMicrotask(() =>
                socket.onmessage?.({
                  data: JSON.stringify({
                    id: request.id,
                    error: { code: -32003, message: "Refused", data: { reason: options.refuse } },
                  }),
                }),
              );
            else reply({ credential: "cmm_device-secret", machineId: "web-device", userId: "owner" });
          } else if (request.method === "_acpmux/device_challenge") {
            reply({ machineId: "web-device", nonce: `nonce-${request.id}`, binding: "acpmux:conn-1" });
          } else if (request.method === "_acpmux/device_hello") {
            answerHello = () => reply({ auth: "webDevice" });
            helloStarted();
            if (!options.holdHello) answerHello();
          } else send(raw);
        };
        sockets.push(socket as unknown as WebSocket);
        return socket as unknown as WebSocket;
      },
      undefined,
      wire,
    );
  return { connect, calls, sockets, wire, helloSeen, releaseHello: () => answerHello() };
}

test("the real direct client enrolls and says hello before any reads; a fresh client presents hello again", async () => {
  enroll();
  const f = await fixture();
  const first = await f.connect();
  first.close();
  const split = f.calls.length;
  const second = await f.connect();
  try {
    expect(f.calls.slice(0, 4).map((call) => call.method)).toEqual([
      "_acpmux/device_enroll",
      "_acpmux/device_challenge",
      "_acpmux/device_hello",
      "initialize",
    ]);
    expect(f.calls[split]?.method).toBe("_acpmux/device_challenge");
    expect(f.calls[split + 1]?.method).toBe("_acpmux/device_hello");
    expect(f.calls.filter((call) => call.method === "_acpmux/device_enroll")).toHaveLength(1);
    // Each socket proves the device key anew: its own nonce, signed with the key enrolled once.
    const hello = f.calls[split + 1]!.params;
    expect(hello).toMatchObject({ credential: "cmm_device-secret", nonce: `nonce-${f.calls[split]!.id}` });
    const deviceKey = f.calls[0]!.params.deviceKey as string;
    expect(deviceKey).toMatch(/^[A-Za-z0-9_-]{87}$/);
    expect(hello.signature as string).toMatch(/^[A-Za-z0-9_-]{86}$/);
    const fromB64 = (value: string) => Uint8Array.from(Buffer.from(value, "base64url"));
    const key = await crypto.subtle.importKey(
      "raw",
      fromB64(deviceKey),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const message = (nonce: string) =>
      new TextEncoder().encode(`cmux-device-hello/v1\nweb-device\n${nonce}\nacpmux:conn-1`);
    const verify = (nonce: string) =>
      crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, fromB64(hello.signature as string), message(nonce));
    expect(await verify(hello.nonce as string)).toBe(true);
    expect(await verify("another-nonce")).toBe(false);
    const log = f.wire.exportJsonl();
    expect(log).not.toContain("access-secret");
    expect(log).not.toContain("cmm_device-secret");
    expect(log).not.toContain(hello.signature as string);
    expect(log).toContain("_acpmux/device_hello");
  } finally {
    second.close();
  }
});

test("no watch, list or attach escapes while hello is pending", async () => {
  enroll();
  const f = await fixture({ holdHello: true });
  const pending = f.connect();
  await f.helloSeen;
  expect(f.calls.map((call) => call.method)).toEqual([
    "_acpmux/device_enroll",
    "_acpmux/device_challenge",
    "_acpmux/device_hello",
  ]);
  f.releaseHello();
  const client = await pending;
  client.close();
});

test("the same client's reconnect authenticates its replacement socket before reading", async () => {
  enroll();
  const f = await fixture();
  const client = await f.connect();
  const split = f.calls.length;
  // Exercise the same open path the reconnect timer invokes, without waiting for backoff.
  const old = f.sockets[0]!;
  old.onclose = null;
  old.close();
  try {
    await (client as any).open();
    expect(f.sockets).toHaveLength(2);
    expect(f.calls[split]?.method).toBe("_acpmux/device_challenge");
    expect(f.calls[split + 1]?.method).toBe("_acpmux/device_hello");
    expect(f.calls[split + 2]?.method).toBe("initialize");
    expect(f.calls.filter((call) => call.method === "_acpmux/device_enroll")).toHaveLength(1);
  } finally {
    client.close();
  }
});

test("sign-out during hello cannot release reads or repopulate the identity", async () => {
  enroll();
  const f = await fixture({ holdHello: true });
  const pending = f.connect();
  await f.helloSeen;
  clearBrowserDeviceIdentity();
  f.releaseHello();
  await expect(pending).rejects.toMatchObject({ reason: "device.identity_required" });
  await expect(f.connect()).rejects.toMatchObject({ reason: "device.identity_required" });
  expect(f.calls.map((call) => call.method)).toEqual([
    "_acpmux/device_enroll",
    "_acpmux/device_challenge",
    "_acpmux/device_hello",
  ]);
});

test("missing identity and cross-origin or downgraded endpoints send no listener token or socket", async () => {
  const f = await fixture();
  await expect(f.connect()).rejects.toMatchObject({ reason: "device.identity_required" });
  enroll();
  for (const endpoint of [
    "wss://other.example/",
    "ws://device.example/",
    "wss://device.example/?token=secret",
    "wss://user:pass@device.example/",
  ])
    await expect(f.connect({ endpoint })).rejects.toMatchObject({ reason: "device.origin_mismatch" });
  expect(f.sockets).toHaveLength(0);
});

test("denied enrollment stops reads and does not enroll on reconnect", async () => {
  enroll();
  const f = await fixture({ refuse: "device.enroll_refused" });
  await expect(f.connect()).rejects.toMatchObject({ reason: "device.enroll_refused" });
  await expect(f.connect()).rejects.toMatchObject({ reason: "device.identity_required" });
  expect(f.calls.map((call) => call.method)).toEqual(["_acpmux/device_enroll"]);
});

test("revocation discovered by a later request drops identity and blocks the next connection", async () => {
  enroll();
  const f = await fixture();
  const client = await f.connect();
  const direct = client as any;
  const pending = direct.expectReply(99999, "_acpmux/status", 1_000);
  direct.receive(
    JSON.stringify({ id: 99999, error: { code: -32003, message: "Revoked", data: { reason: "device.revoked" } } }),
  );
  await expect(pending).rejects.toMatchObject({ reason: "device.revoked" });
  await expect(f.connect()).rejects.toMatchObject({ reason: "device.identity_required" });
  client.close();
});

test("native and existing development connections do not enroll", async () => {
  const f = await fixture();
  for (const transport of ["acpmux-bridge", "acpmux-websocket"]) {
    const client = await f.connect({ browserDevice: undefined, transport });
    client.close();
  }
  expect(f.calls.some((call) => call.method.startsWith("_acpmux/device_"))).toBe(false);
});

test("a lost hello retains the enrolled credential for the next socket", async () => {
  enroll();
  const device = prepareBrowserDevice(new URL("wss://device.example/"));
  const calls: string[] = [];
  await expect(
    connectBrowserDevice(device, async (method) => {
      calls.push(method);
      if (method === "_acpmux/device_enroll") return { credential: "cmm_retained" };
      throw Object.assign(new Error("Disconnected"), { code: "native.not_connected" });
    }),
  ).rejects.toMatchObject({ code: "native.not_connected" });
  await connectBrowserDevice(prepareBrowserDevice(new URL("wss://device.example/")), async (method, params) => {
    calls.push(method);
    expect(params).toMatchObject({ credential: "cmm_retained" });
    if (method === "_acpmux/device_challenge") return { machineId: "m", nonce: "n", binding: "acpmux:c" };
    expect(params).toMatchObject({ nonce: "n" });
    return { auth: "webDevice" };
  });
  expect(calls).toEqual([
    "_acpmux/device_enroll",
    "_acpmux/device_challenge",
    "_acpmux/device_challenge",
    "_acpmux/device_hello",
  ]);
});

test("a daemon from before the proof (no challenge method) keeps the bearer hello", async () => {
  enroll();
  const device = prepareBrowserDevice(new URL("wss://device.example/"));
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  await connectBrowserDevice(device, async (method, params) => {
    calls.push({ method, params });
    if (method === "_acpmux/device_enroll") return { credential: "cmm_old_daemon" };
    if (method === "_acpmux/device_challenge") throw Object.assign(new Error("Method not found"), { code: -32601 });
    return { auth: "webDevice" };
  });
  expect(calls.map((call) => call.method)).toEqual([
    "_acpmux/device_enroll",
    "_acpmux/device_challenge",
    "_acpmux/device_hello",
  ]);
  expect(calls[2]!.params).toEqual({ credential: "cmm_old_daemon" });
});

test("a hello acknowledgement for another connection kind never releases the browser", async () => {
  enroll();
  const device = prepareBrowserDevice(new URL("wss://device.example/"));
  await expect(
    connectBrowserDevice(device, async (method) =>
      method === "_acpmux/device_enroll" ? { credential: "cmm_device" } : { auth: "listenerToken" },
    ),
  ).rejects.toMatchObject({ reason: "device.unauthorized" });
  expect(() => prepareBrowserDevice(new URL("wss://device.example/"))).toThrow("device.identity_required");
});
