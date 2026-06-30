type JsonObject = Record<string, unknown>;

const relayURL = normalizeRelayURL(process.env.CMUX_COLLABORATION_RELAY_URL ?? process.argv[2] ?? "https://collaboration.cmux.dev");
const timeoutMs = Number(process.env.CMUX_COLLABORATION_SMOKE_TIMEOUT_MS ?? "15000");

function normalizeRelayURL(value: string): URL {
  const url = new URL(value);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(`relay URL must use http or https, got ${url.protocol}`);
  }
  url.pathname = url.pathname.replace(/\/+$/, "");
  url.search = "";
  url.hash = "";
  return url;
}

function withPath(base: URL, path: string): URL {
  const next = new URL(base);
    const basePath = base.pathname === "/" ? "" : base.pathname.replace(/\/+$/, "");
    next.pathname = `${basePath}${path}`;
  return next;
}

function webSocketURL(base: URL, sessionCode: string, token: string, peerID: string): URL {
  const url = withPath(base, `/v1/collaboration/sessions/${sessionCode}/connect`);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.searchParams.set("token", token);
  url.searchParams.set("peerID", peerID);
  url.searchParams.set("displayName", `smoke-${peerID}`);
  url.searchParams.set("color", peerID === "peer-a" ? "#ff0000" : "#0000ff");
  return url;
}

function fail(message: string): never {
  throw new Error(message);
}

function parseJSON(data: unknown): JsonObject {
  const text = typeof data === "string" ? data : String(data);
  const parsed = JSON.parse(text);
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    fail(`expected JSON object frame, got ${text}`);
  }
  return parsed as JsonObject;
}

class SmokePeer {
  private socket: WebSocket;
  private frames: JsonObject[] = [];
  private waiters: Array<{
    predicate: (frame: JsonObject) => boolean;
    resolve: (frame: JsonObject) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];

  constructor(url: URL) {
    this.socket = new WebSocket(url.href);
    this.socket.addEventListener("message", (event) => {
      const frame = parseJSON(event.data);
      this.frames.push(frame);
      for (const waiter of [...this.waiters]) {
        if (!waiter.predicate(frame)) continue;
        clearTimeout(waiter.timer);
        this.waiters = this.waiters.filter((candidate) => candidate !== waiter);
        waiter.resolve(frame);
      }
    });
    this.socket.addEventListener("error", () => {
      this.rejectWaiters(new Error(`websocket error for ${url.href}`));
    });
    this.socket.addEventListener("close", (event) => {
      if (event.code === 1000 || event.code === 1005) return;
      this.rejectWaiters(new Error(`websocket closed unexpectedly: ${event.code} ${event.reason}`));
    });
  }

  async open(): Promise<void> {
    if (this.socket.readyState === WebSocket.OPEN) return;
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timed out waiting for websocket open")), timeoutMs);
      this.socket.addEventListener("open", () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
      this.socket.addEventListener("error", () => {
        clearTimeout(timer);
        reject(new Error("websocket failed before open"));
      }, { once: true });
    });
  }

  send(frame: JsonObject): void {
    this.socket.send(JSON.stringify(frame));
  }

  async waitFor(predicate: (frame: JsonObject) => boolean, description: string): Promise<JsonObject> {
    const existing = this.frames.find(predicate);
    if (existing) return existing;
    return new Promise<JsonObject>((resolve, reject) => {
      const waiter = {
        predicate,
        resolve,
        reject,
        timer: setTimeout(() => {
          this.waiters = this.waiters.filter((candidate) => candidate !== waiter);
          reject(new Error(`timed out waiting for ${description}`));
        }, timeoutMs),
      };
      this.waiters.push(waiter);
    });
  }

  frameCount(type: string): number {
    return this.frames.filter((frame) => frame.type === type).length;
  }

  close(): void {
    this.socket.close(1000, "smoke complete");
    this.rejectWaiters(new Error("smoke peer closed"));
  }

  private rejectWaiters(error: Error): void {
    for (const waiter of this.waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.waiters = [];
  }
}

async function main(): Promise<void> {
  const healthResponse = await fetch(withPath(relayURL, "/healthz"));
  if (!healthResponse.ok) {
    fail(`healthz failed: ${healthResponse.status} ${await healthResponse.text()}`);
  }
  const health = await healthResponse.json() as JsonObject;
  if (health.ok !== true || health.service !== "cmux-collaboration") {
    fail(`unexpected healthz body: ${JSON.stringify(health)}`);
  }

  const createResponse = await fetch(withPath(relayURL, "/v1/collaboration/sessions"), { method: "POST" });
  if (createResponse.status !== 201) {
    fail(`session create failed: ${createResponse.status} ${await createResponse.text()}`);
  }
  const created = await createResponse.json() as { sessionCode?: string; token?: string };
  if (!created.sessionCode || !created.token) {
    fail(`session create returned incomplete invite: ${JSON.stringify(created)}`);
  }

  const first = new SmokePeer(webSocketURL(relayURL, created.sessionCode, created.token, "peer-a"));
  let second: SmokePeer | null = null;
  try {
    await first.open();
    await first.waitFor((frame) => frame.type === "session.joined", "first session.joined");
    second = new SmokePeer(webSocketURL(relayURL, created.sessionCode, created.token, "peer-b"));
    await second.open();

    const secondJoined = await second.waitFor((frame) => frame.type === "session.joined", "second session.joined");
    const peers = secondJoined.peers;
    if (!Array.isArray(peers) || peers.length !== 2) {
      fail(`second peer did not see both peers: ${JSON.stringify(secondJoined)}`);
    }
    await first.waitFor((frame) => frame.type === "peer.joined" && (frame.peer as JsonObject | undefined)?.peerID === "peer-b", "peer-a peer.joined");

    first.send({ type: "peer.heartbeat" });
    await Bun.sleep(250);
    if (second.frameCount("peer.heartbeat") !== 0) {
      fail("heartbeat frame was forwarded to another peer");
    }

    first.send({ type: "document.update", documentID: "smoke-doc", updateID: "smoke-update", operations: [] });
    const forwarded = await second.waitFor((frame) => frame.type === "document.update", "document update forwarding");
    if (forwarded.documentID !== "smoke-doc" || forwarded.fromPeerID !== "peer-a") {
      fail(`unexpected forwarded frame: ${JSON.stringify(forwarded)}`);
    }

    console.log(`collaboration relay smoke OK: ${relayURL.href} session ${created.sessionCode}`);
  } finally {
    first.close();
    second?.close();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
