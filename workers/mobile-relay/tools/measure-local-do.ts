/**
 * Measure the relay path with both endpoints on this computer.
 *
 * This does not use iOS, a PTY, or the cmux app. It opens one host socket and
 * one client socket, sends a one-byte frame through the deployed Worker and
 * HostRelay object, and has the host echo it back. Monotonic timestamps from
 * this one process let us measure each forwarding direction without clock
 * synchronization.
 *
 * Required environment:
 *   STACK_ACCESS          A Stack access token the target worker will accept.
 *                         Against the local emulator, run
 *                         `bun tools/local-stack-mock.ts` and start wrangler
 *                         dev with STACK_API_URL pointing at it; the mock
 *                         accepts any token.
 * Optional environment:
 *   RELAY_URL             wss://.../v1/connect (defaults to mr.cmux.dev)
 *   SAMPLES               Measured samples (default 50)
 *   WARMUP                Warm-up frames (default 5)
 *   TIMEOUT_MS            Per-operation timeout (default 5000)
 *
 * Run with:
 *   bun tools/measure-local-do.ts
 */

import {
  DEVICE_HEADER,
  encodeDataFrame,
  HOST_DEVICE_HEADER,
  ROLE_HEADER,
  STACK_ACCESS_HEADER,
} from "../src/protocol";

const relayURL = process.env.RELAY_URL ?? "wss://mr.cmux.dev/v1/connect";
const accessToken = process.env.STACK_ACCESS;
const samples = parsePositiveInt(process.env.SAMPLES, 50);
const warmup = parseNonNegativeInt(process.env.WARMUP, 5);
const timeoutMs = parsePositiveInt(process.env.TIMEOUT_MS, 5_000);

if (!accessToken) {
  throw new Error("STACK_ACCESS must be set to a token the target worker accepts");
}
const hostDeviceId = crypto.randomUUID();
const clientDeviceId = crypto.randomUUID();

type SocketMessage = string | ArrayBuffer | Blob;

interface Welcome {
  readonly t: "welcome";
  readonly sessionId: number;
  readonly hostPresent: boolean;
}

interface Stats {
  readonly name: string;
  readonly values: number[];
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isInteger(value) || value <= 0) throw new Error(`invalid positive integer: ${raw}`);
  return value;
}

function parseNonNegativeInt(raw: string | undefined, fallback: number): number {
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isInteger(value) || value < 0) throw new Error(`invalid non-negative integer: ${raw}`);
  return value;
}

function percentile(values: readonly number[], fraction: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1);
  return sorted[index] ?? 0;
}

function summarize(stats: Stats): void {
  const values = stats.values;
  console.log(
    `${stats.name}: n=${values.length} ` +
      `p50=${percentile(values, 0.5).toFixed(2)}ms ` +
      `p95=${percentile(values, 0.95).toFixed(2)}ms ` +
      `max=${Math.max(...values).toFixed(2)}ms`,
  );
}

function waitForOpen(socket: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("WebSocket open timeout")), timeoutMs);
    socket.addEventListener("open", () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
    socket.addEventListener("error", () => {
      clearTimeout(timer);
      reject(new Error("WebSocket open failed"));
    }, { once: true });
  });
}

function readWelcome(socket: WebSocket): Promise<Welcome> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("welcome timeout")), timeoutMs);
    const onMessage = (event: MessageEvent<SocketMessage>) => {
      if (typeof event.data !== "string") return;
      let value: unknown;
      try {
        value = JSON.parse(event.data);
      } catch {
        return;
      }
      const welcome = value as Partial<Welcome>;
      if (welcome.t !== "welcome" || typeof welcome.sessionId !== "number") return;
      clearTimeout(timer);
      socket.removeEventListener("message", onMessage);
      resolve({
        t: "welcome",
        sessionId: welcome.sessionId,
        hostPresent: welcome.hostPresent === true,
      });
    };
    socket.addEventListener("message", onMessage);
    socket.addEventListener("error", () => {
      clearTimeout(timer);
      reject(new Error("WebSocket error before welcome"));
    }, { once: true });
  });
}

async function openSocket(role: "host" | "client", deviceId: string): Promise<{ socket: WebSocket; welcome: Welcome; openMs: number }> {
  const started = performance.now();
  const socket = new WebSocket(relayURL, {
    headers: {
      [STACK_ACCESS_HEADER]: accessToken!,
      [ROLE_HEADER]: role,
      [HOST_DEVICE_HEADER]: hostDeviceId,
      [DEVICE_HEADER]: deviceId,
    },
  });
  await waitForOpen(socket);
  const welcome = await readWelcome(socket);
  return { socket, welcome, openMs: performance.now() - started };
}

function nextBinaryMessage(socket: WebSocket): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("binary frame timeout")), timeoutMs);
    const onMessage = async (event: MessageEvent<SocketMessage>) => {
      if (typeof event.data === "string") return;
      try {
        const buffer = event.data instanceof Blob ? await event.data.arrayBuffer() : event.data;
        clearTimeout(timer);
        socket.removeEventListener("message", onMessage);
        resolve(new Uint8Array(buffer));
      } catch (error) {
        clearTimeout(timer);
        reject(error);
      }
    };
    socket.addEventListener("message", onMessage);
  });
}

async function main(): Promise<void> {
  console.log(`relay=${relayURL}`);
  console.log(`samples=${samples} warmup=${warmup}`);
  const host = await openSocket("host", hostDeviceId);
  const client = await openSocket("client", clientDeviceId);
  if (!client.welcome.hostPresent) throw new Error("client connected before host was present");

  const hostToClient: number[] = [];
  const clientToHost: number[] = [];
  const roundTrip: number[] = [];
  let hostFrames = 0;

  host.socket.addEventListener("message", (event: MessageEvent<SocketMessage>) => {
    if (typeof event.data === "string") return;
    const receivedAt = performance.now();
    const bufferPromise = event.data instanceof Blob ? event.data.arrayBuffer() : Promise.resolve(event.data);
    void bufferPromise.then((buffer) => {
      hostFrames += 1;
      const payload = new Uint8Array(buffer);
      const sentAt = pending.get(payload[5] ?? -1);
      if (sentAt !== undefined) clientToHost.push(receivedAt - sentAt);
      host.socket.send(payload);
    });
  });

  const pending = new Map<number, number>();
  for (let index = 0; index < warmup + samples; index += 1) {
    const marker = index & 0xff;
    const frame = encodeDataFrame(client.welcome.sessionId, new Uint8Array([marker]));
    const sentAt = performance.now();
    pending.set(marker, sentAt);
    const echo = nextBinaryMessage(client.socket);
    client.socket.send(frame);
    await echo;
    const completedAt = performance.now();
    pending.delete(marker);
    if (index >= warmup) {
      roundTrip.push(completedAt - sentAt);
      const oneWay = clientToHost[clientToHost.length - 1];
      if (oneWay !== undefined) hostToClient.push(completedAt - sentAt - oneWay);
    }
  }

  console.log(`host_connect: ${host.openMs.toFixed(2)}ms`);
  console.log(`client_connect: ${client.openMs.toFixed(2)}ms`);
  console.log(`host_frames: ${hostFrames}`);
  summarize({ name: "client_to_host", values: clientToHost.slice(-samples) });
  summarize({ name: "host_to_client", values: hostToClient.slice(-samples) });
  summarize({ name: "round_trip", values: roundTrip });
  console.log("These numbers include the local WebSocket client and Internet path, but no iOS, PTY, or terminal rendering.");

  host.socket.close();
  client.socket.close();
}

await main();
