#!/usr/bin/env bun
import { createHash, randomBytes } from "node:crypto";
import WebSocket from "ws";
import { Sandbox } from "e2b";
import { Freestyle } from "freestyle";

type Provider = "e2b" | "freestyle";
type FreestyleVmRef = {
  exec(args: { command: string; timeoutMs?: number }): Promise<{
    stdout?: string | null;
    stderr?: string | null;
    statusCode?: number | null;
  }>;
};

const provider = argValue("--provider") as Provider | undefined;
if (provider !== "e2b" && provider !== "freestyle") {
  throw new Error("--provider must be e2b or freestyle");
}

const image = argValue("--image") ?? argValue("--template") ?? argValue("--snapshot");
if (!image) {
  throw new Error("--image is required");
}

const keep = hasFlag("--keep");
const ptyLeasePath = "/tmp/cmux/attach-pty-lease.json";
const legacyPtyLeasePath = "/tmp/cmux/attach-lease.json";
const freestyleTimeoutMs = 15 * 60 * 1000;

const result = provider === "e2b"
  ? await testE2B(image, keep)
  : await testFreestyle(image, keep);
console.log(JSON.stringify(result, null, 2));

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  if (index === -1) return undefined;
  return process.argv[index + 1];
}

function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

async function testE2B(template: string, keep: boolean): Promise<Record<string, unknown>> {
  if (!process.env.E2B_API_KEY) {
    throw new Error("E2B_API_KEY is required");
  }
  const sandbox = await Sandbox.create(template, {
    timeoutMs: 10 * 60 * 1000,
    network: { allowPublicTraffic: false },
  });
  const host = sandbox.getHost(7777);
  const httpURL = `https://${host}`;
  const wsURL = `wss://${host}/terminal`;
  const rpcURL = `wss://${host}/rpc`;
  const headers = { "e2b-traffic-access-token": sandbox.trafficAccessToken ?? "" };

  try {
    const noTrafficAuth = await fetch(`${httpURL}/healthz`);
    const trafficAuth = await fetch(`${httpURL}/healthz`, { headers });
    if (noTrafficAuth.status !== 403) {
      throw new Error(`expected E2B traffic gate to return 403 without token, got ${noTrafficAuth.status}`);
    }
    if (trafficAuth.status !== 200) {
      throw new Error(`expected healthz with E2B token to return 200, got ${trafficAuth.status}`);
    }
    const service = await readE2BWebSocketService(sandbox);
    if (!service.rpcLeasePath) {
      throw new Error("E2B cmuxd-ws service is missing --rpc-auth-lease-file; browser proxy cannot work");
    }

    await installLeaseE2B(sandbox, service.ptyLeasePath, "wrong-e2b", "sess-e2b", true);
    const wrongCmuxToken = await websocketAuthShouldFail(wsURL, headers, "wrong-token", "sess-e2b");
    const leaseStillThere = await e2bFileExists(sandbox, service.ptyLeasePath);
    if (!leaseStillThere) throw new Error("wrong cmux token consumed E2B lease");

    const token = await installLeaseE2B(sandbox, service.ptyLeasePath, "right-e2b", "sess-e2b", true);
    const terminalOutput = await websocketShellRoundTrip(wsURL, headers, token, "sess-e2b");
    const replay = await websocketAuthShouldFail(wsURL, headers, token, "sess-e2b");

    const rpcToken = await installLeaseE2B(sandbox, service.rpcLeasePath, "rpc-e2b", "sess-rpc-e2b", false);
    const rpcHello = await websocketRPCHello(rpcURL, headers, rpcToken, "sess-rpc-e2b");
    const rpcHelloReplay = await websocketRPCHello(rpcURL, headers, rpcToken, "sess-rpc-e2b");
    const rpcProxyHealthz = await websocketRPCProxyHTTPRoundTrip(
      rpcURL,
      headers,
      rpcToken,
      "sess-rpc-e2b",
      "127.0.0.1",
      7777,
      "/healthz",
    );

    return {
      provider: "e2b",
      sandboxId: sandbox.sandboxId,
      host,
      ptyLeasePath: service.ptyLeasePath,
      rpcLeasePath: service.rpcLeasePath,
      trafficGate: { withoutToken: noTrafficAuth.status, withToken: trafficAuth.status },
      unauthenticatedTransport: "covered by healthz 403 without e2b-traffic-access-token",
      wrongCmuxToken,
      terminalOutput,
      replay,
      rpcHello,
      rpcHelloReplay,
      rpcProxyHealthz,
      kept: keep,
    };
  } finally {
    if (!keep) {
      await Sandbox.kill(sandbox.sandboxId).catch(() => false);
    }
  }
}

async function testFreestyle(snapshotId: string, keep: boolean): Promise<Record<string, unknown>> {
  if (!process.env.FREESTYLE_API_KEY) {
    throw new Error("FREESTYLE_API_KEY is required");
  }
  const fs = freestyleClient();
  const created = await fs.vms.create({
    snapshotId,
    ports: [{ port: 443, targetPort: 7777 }],
    readySignalTimeoutSeconds: 600,
  });
  const vmId = created.vmId;
  const vm = fs.vms.ref({ vmId });

  try {
    const domain = (created as { domains?: string[] }).domains?.[0] ?? `${vmId}.vm.freestyle.sh`;
    const httpURL = `https://${domain}`;
    const wsURL = `wss://${domain}/terminal`;
    const rpcURL = `wss://${domain}/rpc`;

    const health = await fetch(`${httpURL}/healthz`);
    if (health.status !== 200) {
      throw new Error(`expected Freestyle healthz 200, got ${health.status}`);
    }
    const service = await readFreestyleWebSocketService(vm);
    if (!service.rpcLeasePath) {
      throw new Error("Freestyle cmuxd-ws service is missing --rpc-auth-lease-file; browser proxy cannot work");
    }

    await installLeaseFreestyle(vm, service.ptyLeasePath, "wrong-freestyle", "sess-fs", true);
    const wrongCmuxToken = await websocketAuthShouldFail(wsURL, {}, "wrong-token", "sess-fs");
    const leaseStillThere = await freestyleFileExists(vm, service.ptyLeasePath);
    if (!leaseStillThere) throw new Error("wrong cmux token consumed Freestyle lease");

    const token = await installLeaseFreestyle(vm, service.ptyLeasePath, "right-freestyle", "sess-fs", true);
    const terminalOutput = await websocketShellRoundTrip(wsURL, {}, token, "sess-fs");
    const replay = await websocketAuthShouldFail(wsURL, {}, token, "sess-fs");

    const rpcToken = await installLeaseFreestyle(vm, service.rpcLeasePath, "rpc-freestyle", "sess-rpc-fs", false);
    const rpcHello = await websocketRPCHello(rpcURL, {}, rpcToken, "sess-rpc-fs");
    const rpcHelloReplay = await websocketRPCHello(rpcURL, {}, rpcToken, "sess-rpc-fs");
    const rpcProxyHealthz = await websocketRPCProxyHTTPRoundTrip(
      rpcURL,
      {},
      rpcToken,
      "sess-rpc-fs",
      "127.0.0.1",
      7777,
      "/healthz",
    );

    return {
      provider: "freestyle",
      vmId,
      domain,
      ptyLeasePath: service.ptyLeasePath,
      rpcLeasePath: service.rpcLeasePath,
      health: health.status,
      wrongCmuxToken,
      terminalOutput,
      replay,
      rpcHello,
      rpcHelloReplay,
      rpcProxyHealthz,
      kept: keep,
    };
  } finally {
    if (!keep) {
      await fs.vms.delete({ vmId }).catch(() => undefined);
    }
  }
}

function freestyleClient(timeoutMs = freestyleTimeoutMs): Freestyle {
  const longFetch: typeof fetch = (input, init) =>
    fetch(input as Request, { ...(init ?? {}), signal: AbortSignal.timeout(timeoutMs) });
  return new Freestyle({ fetch: longFetch });
}

async function installLeaseE2B(
  sandbox: Sandbox,
  path: string,
  label: string,
  sessionId: string,
  singleUse: boolean,
): Promise<string> {
  const { token, lease } = makeLease(label, sessionId, singleUse);
  const encoded = Buffer.from(JSON.stringify(lease)).toString("base64");
  await sandbox.commands.run(
    `install -d -m 0700 ${shellQuote(parentDirectory(path))} && printf '%s' '${encoded}' | base64 -d > ${shellQuote(path)} && chmod 600 ${shellQuote(path)}`,
    { timeoutMs: 30_000 },
  );
  return token;
}

async function readE2BWebSocketService(sandbox: Sandbox): Promise<{
  ptyLeasePath: string;
  rpcLeasePath: string | null;
}> {
  const result = await sandbox.commands.run(
    "ps auxww | grep cmuxd-remote | grep -v grep || true",
    { timeoutMs: 30_000 },
  );
  const stdout = result.stdout ?? "";
  return {
    ptyLeasePath:
      shellArgValue(stdout, "--auth-lease-file")
      ?? (stdout.includes(legacyPtyLeasePath) ? legacyPtyLeasePath : ptyLeasePath),
    rpcLeasePath: shellArgValue(stdout, "--rpc-auth-lease-file"),
  };
}

async function installLeaseFreestyle(
  vm: FreestyleVmRef,
  path: string,
  label: string,
  sessionId: string,
  singleUse: boolean,
): Promise<string> {
  const { token, lease } = makeLease(label, sessionId, singleUse);
  const encoded = Buffer.from(JSON.stringify(lease)).toString("base64");
  await vm.exec({
    command: `install -d -m 0700 ${shellQuote(parentDirectory(path))} && printf '%s' '${encoded}' | base64 -d > ${shellQuote(path)} && chmod 600 ${shellQuote(path)}`,
    timeoutMs: 30_000,
  });
  return token;
}

function makeLease(label: string, sessionId: string, singleUse: boolean): { token: string; lease: unknown } {
  const token = `cmux-${label}-${randomBytes(24).toString("hex")}`;
  const hash = createHash("sha256").update(token).digest("hex");
  return {
    token,
    lease: {
      version: 1,
      token_sha256: hash,
      expires_at_unix: Math.floor(Date.now() / 1000) + 120,
      session_id: sessionId,
      single_use: singleUse,
    },
  };
}

async function e2bFileExists(sandbox: Sandbox, path: string): Promise<boolean> {
  const result = await sandbox.commands.run(`test -f ${shellQuote(path)} && echo yes || echo no`, { timeoutMs: 30_000 });
  return result.stdout.trim() === "yes";
}

async function freestyleFileExists(vm: FreestyleVmRef, path: string): Promise<boolean> {
  const result = await vm.exec({
    command: `test -f ${shellQuote(path)} && echo yes || echo no`,
    timeoutMs: 30_000,
  });
  return (result.stdout ?? "").trim() === "yes";
}

async function readFreestyleWebSocketService(vm: FreestyleVmRef): Promise<{
  ptyLeasePath: string;
  rpcLeasePath: string | null;
}> {
  const result = await vm.exec({
    command: "systemctl cat cmuxd-ws 2>/dev/null || true; ps auxww | grep cmuxd-remote | grep -v grep || true",
    timeoutMs: 30_000,
  });
  const stdout = result.stdout ?? "";
  return {
    ptyLeasePath:
      shellArgValue(stdout, "--auth-lease-file")
      ?? (stdout.includes(legacyPtyLeasePath) ? legacyPtyLeasePath : ptyLeasePath),
    rpcLeasePath: shellArgValue(stdout, "--rpc-auth-lease-file"),
  };
}

async function websocketAuthShouldFail(
  url: string,
  headers: Record<string, string>,
  token: string,
  sessionId: string,
): Promise<{ closeCode: number; closeReason: string }> {
  const ws = await openWebSocket(url, headers);
  ws.send(JSON.stringify({ type: "auth", token, session_id: sessionId, cols: 80, rows: 24 }));
  return await waitForClose(ws);
}

async function websocketShellRoundTrip(
  url: string,
  headers: Record<string, string>,
  token: string,
  sessionId: string,
): Promise<string> {
  const ws = await openWebSocket(url, headers);
  ws.send(JSON.stringify({ type: "auth", token, session_id: sessionId, cols: 80, rows: 24 }));
  const ready = await waitForMessage(ws, (data, isBinary) => !isBinary && data.toString().includes('"ready"'));
  if (!ready.toString().includes('"ready"')) {
    throw new Error(`expected ready frame, got ${ready.toString()}`);
  }
  ws.send(Buffer.from("printf '%b\\n' '\\103\\115\\125\\130\\137\\103\\114\\117\\125\\104\\137\\127\\123\\137\\117\\113'; exit\r"));
  const output = await waitForMessage(ws, (data, isBinary) => isBinary && data.toString().includes("CMUX_CLOUD_WS_OK"));
  ws.close();
  return output.toString();
}

async function websocketRPCHello(
  url: string,
  headers: Record<string, string>,
  token: string,
  sessionId: string,
): Promise<unknown> {
  const ws = await openWebSocket(url, headers);
  ws.send(JSON.stringify({ type: "auth", token, session_id: sessionId }));
  const ready = await waitForMessage(ws, (data, isBinary) => !isBinary && data.toString().includes('"ready"'));
  if (!ready.toString().includes('"ready"')) {
    throw new Error(`expected rpc ready frame, got ${ready.toString()}`);
  }
  ws.send(JSON.stringify({ id: 1, method: "hello", params: {} }));
  const response = await waitForMessage(ws, (data, isBinary) => !isBinary && data.toString().includes('"id":1'));
  ws.close();
  return JSON.parse(response.toString());
}

async function websocketRPCProxyHTTPRoundTrip(
  url: string,
  headers: Record<string, string>,
  token: string,
  sessionId: string,
  host: string,
  port: number,
  path: string,
): Promise<{ streamId: string; response: string }> {
  const ws = await openWebSocket(url, headers);
  const frames = new WebSocketTextFrameQueue(ws);
  try {
    ws.send(JSON.stringify({ type: "auth", token, session_id: sessionId }));
    const ready = JSON.parse(await frames.nextMatching((frame) => frame.type === "ready"));
    if (ready.type !== "ready") {
      throw new Error(`expected rpc ready frame, got ${JSON.stringify(ready)}`);
    }

    ws.send(JSON.stringify({ id: 1, method: "proxy.open", params: { host, port } }));
    const open = JSON.parse(await frames.nextMatching((frame) => frame.id === 1));
    const streamId = open?.result?.stream_id;
    if (typeof streamId !== "string" || streamId.length === 0) {
      throw new Error(`proxy.open missing stream_id: ${JSON.stringify(open)}`);
    }

    ws.send(JSON.stringify({ id: 2, method: "proxy.stream.subscribe", params: { stream_id: streamId } }));
    const subscribe = JSON.parse(await frames.nextMatching((frame) => frame.id === 2));
    if (subscribe.ok !== true) {
      throw new Error(`proxy.stream.subscribe failed: ${JSON.stringify(subscribe)}`);
    }

    const request = `GET ${path} HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`;
    ws.send(JSON.stringify({
      id: 3,
      method: "proxy.write",
      params: {
        stream_id: streamId,
        data_base64: Buffer.from(request).toString("base64"),
      },
    }));

    let sawWriteOK = false;
    const chunks: string[] = [];
    while (true) {
      const frame = JSON.parse(await frames.nextMatching(() => true));
      if (frame.id === 3) {
        if (frame.ok !== true) {
          throw new Error(`proxy.write failed: ${JSON.stringify(frame)}`);
        }
        sawWriteOK = true;
        continue;
      }
      if (frame.event === "proxy.stream.data" || frame.event === "proxy.stream.eof") {
        const chunk = Buffer.from(frame.data_base64 ?? "", "base64").toString();
        chunks.push(chunk);
        if (frame.event === "proxy.stream.eof") {
          const response = chunks.join("");
          if (!sawWriteOK) {
            throw new Error(`proxy.write response missing before eof: ${response}`);
          }
          if (!response.includes("\"ok\":true")) {
            throw new Error(`unexpected proxied healthz response: ${response}`);
          }
          return { streamId, response };
        }
        continue;
      }
      if (frame.event === "proxy.stream.error") {
        throw new Error(`proxy.stream.error: ${JSON.stringify(frame)}`);
      }
    }
  } finally {
    ws.close();
  }
}

class WebSocketTextFrameQueue {
  private readonly pending: string[] = [];
  private readonly waiters: Array<(frame: string) => void> = [];
  private readonly errors: Error[] = [];

  constructor(ws: WebSocket) {
    ws.on("message", (data, isBinary) => {
      if (isBinary) return;
      const frame = Buffer.isBuffer(data) ? data.toString() : Buffer.from(data as ArrayBuffer).toString();
      const waiter = this.waiters.shift();
      if (waiter) {
        waiter(frame);
        return;
      }
      this.pending.push(frame);
    });
    ws.on("error", (error) => {
      this.errors.push(error);
      while (this.waiters.length > 0) {
        const waiter = this.waiters.shift();
        waiter?.("__CMUX_QUEUE_ERROR__");
      }
    });
    ws.on("close", (code, reason) => {
      this.errors.push(new Error(`websocket closed: ${code} ${reason.toString()}`));
      while (this.waiters.length > 0) {
        const waiter = this.waiters.shift();
        waiter?.("__CMUX_QUEUE_ERROR__");
      }
    });
  }

  async nextMatching(predicate: (frame: Record<string, unknown>) => boolean): Promise<string> {
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const next = await this.nextTextFrame(deadline - Date.now());
      const parsed = JSON.parse(next) as Record<string, unknown>;
      if (predicate(parsed)) return next;
    }
    throw new Error("timeout waiting for matching websocket text frame");
  }

  private nextTextFrame(timeoutMs: number): Promise<string> {
    const queued = this.pending.shift();
    if (queued !== undefined) {
      return Promise.resolve(queued);
    }
    if (this.errors.length > 0) {
      return Promise.reject(this.errors[0]);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timeout waiting for websocket text frame")), timeoutMs);
      this.waiters.push((frame) => {
        clearTimeout(timer);
        if (frame === "__CMUX_QUEUE_ERROR__") {
          reject(this.errors[0] ?? new Error("websocket failed"));
          return;
        }
        resolve(frame);
      });
    });
  }
}

function openWebSocket(url: string, headers: Record<string, string>): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers });
    const timer = setTimeout(() => {
      ws.terminate();
      reject(new Error(`timeout opening ${url}`));
    }, 15_000);
    ws.once("open", () => {
      clearTimeout(timer);
      resolve(ws);
    });
    ws.once("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function waitForClose(ws: WebSocket): Promise<{ closeCode: number; closeReason: string }> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout waiting for close")), 15_000);
    ws.once("close", (code, reason) => {
      clearTimeout(timer);
      resolve({ closeCode: code, closeReason: reason.toString() });
    });
    ws.once("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function waitForMessage(
  ws: WebSocket,
  predicate: (data: Buffer, isBinary: boolean) => boolean,
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout waiting for message")), 30_000);
    ws.on("message", onMessage);
    ws.once("close", onClose);
    ws.once("error", onError);
    function cleanup() {
      clearTimeout(timer);
      ws.off("message", onMessage);
      ws.off("close", onClose);
      ws.off("error", onError);
    }
    function onMessage(data: WebSocket.RawData, isBinary: boolean) {
      const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data as ArrayBuffer);
      if (!predicate(buffer, isBinary)) return;
      cleanup();
      resolve(buffer);
    }
    function onClose(code: number, reason: Buffer) {
      cleanup();
      reject(new Error(`closed before expected message: ${code} ${reason.toString()}`));
    }
    function onError(err: Error) {
      cleanup();
      reject(err);
    }
  });
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function shellArgValue(text: string, argName: string): string | null {
  const escaped = argName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = text.match(new RegExp(`(?:^|\\s)${escaped}(?:=|\\s+)(?:"([^"]+)"|'([^']+)'|(\\S+))`));
  return match?.[1] ?? match?.[2] ?? match?.[3] ?? null;
}

function parentDirectory(path: string): string {
  const index = path.lastIndexOf("/");
  return index > 0 ? path.slice(0, index) : ".";
}
