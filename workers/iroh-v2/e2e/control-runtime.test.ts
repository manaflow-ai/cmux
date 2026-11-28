import { expect, test, afterAll, beforeAll } from "bun:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { join } from "node:path";
import NodeWebSocket from "ws";
import { accountRequestSigningInput, encodeBase64URL, issueTicket, requestSigningInput } from "../src/crypto";
import { issueDashboardTicket } from "../src/dashboard-auth";
import { objectName } from "../src/routing";
import { V2DashboardController } from "../../../web/dashboard-app/screens/mobile-devices/v2-dashboard-controller";

let mf: Miniflare;
let descriptor: any;
let signingKey: CryptoKey;
let ticket = "";
let dashboardTicketKey = "";
let ticketSigningKey = "";
let fixturePublicKey = "";
let workerRoot = "";
let persistencePath = "";
let fixtureTeamMember = true;
const environment = "test";
const projectId = "iroh-v2-test";
const teamId = "team-control";
const userId = "control-user";

const json = async (request: RequestInfo, init?: RequestInit) => {
  const response = await mf.dispatchFetch(request, init);
  return { response, body: await response.json() as any };
};

const setupFor = async (requestId: string, input: unknown, device = descriptor) => {
  const plainSetup = { schemaId: "session.open.v1", requestId, device };
  const nonce = encodeBase64URL(crypto.getRandomValues(new Uint8Array(16)));
  const issuedAt = Math.floor(Date.now() / 1000);
  const body = input === undefined ? plainSetup : { setup: plainSetup, request: input };
  const value = await crypto.subtle.sign("Ed25519", signingKey, new TextEncoder().encode(
    requestSigningInput(device, requestId, issuedAt, body, nonce),
  ));
  return {
    ...plainSetup,
    proof: { requestId, nonce, issuedAt, signature: encodeBase64URL(new Uint8Array(value)) },
  };
};

const setupHeader = (setup: unknown) => encodeBase64URL(new TextEncoder().encode(JSON.stringify(setup)));

beforeAll(async () => {
  const keyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  signingKey = keyPair.privateKey;
  const rawPublic = await crypto.subtle.exportKey("raw", keyPair.publicKey);
  fixturePublicKey = Array.from(new Uint8Array(rawPublic), byte => byte.toString(16).padStart(2, "0")).join("");
  descriptor = {
    identity: { environment, projectId, teamId, userId, deviceId: "control-device", appNamespace: "cmux", buildTag: "test" },
    endpointId: fixturePublicKey,
    identityGeneration: 0,
    metadata: { platform: "mac", displayName: "Control fixture", appVersion: "1", pairingEnabled: true, capabilities: ["directory", "relay"], relayURLs: ["https://relay.test"] },
  };
  const ticketKeyBytes = crypto.getRandomValues(new Uint8Array(32));
  const ticketKey = encodeBase64URL(ticketKeyBytes);
  dashboardTicketKey = ticketKey;
  ticketSigningKey = ticketKey;
  const relayKey = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const relayPkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", relayKey.privateKey));
  const relayPem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...relayPkcs8)).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----`;
  ticket = (await issueTicket(descriptor, "k1", ticketKey, Math.floor(Date.now() / 1000))).token;

  const outputDir = `/tmp/iroh-v2-control-worker-build-${Date.now()}`;
  workerRoot = outputDir;
  persistencePath = `/tmp/iroh-v2-control-persist-${Date.now()}`;
  const build = Bun.spawnSync({
    cmd: ["bunx", "wrangler", "deploy", "--config", join(import.meta.dir, "control-wrangler.jsonc"), "--dry-run", "--outdir", outputDir],
    cwd: process.cwd(), stdout: "pipe", stderr: "pipe",
  });
  if (build.exitCode !== 0) throw new Error(new TextDecoder().decode(build.stderr));
  mf = new Miniflare({ ...convertV4MiniflareOptions({
    rootPath: workerRoot,
    resourcePersistencePath: persistencePath,
    scriptPath: "control-worker.js",
    modules: true,
    durableObjects: {
      TEAM_CONTROL: { className: "TestTeamControl", useSQLite: true },
      USER_USAGE: { className: "TestUserUsage", useSQLite: true },
      ACCOUNT_CONTROL: { className: "AccountControl", useSQLite: true },
    },
    compatibilityDate: "2026-09-10",
    compatibilityFlags: ["nodejs_compat"],
    bindings: {
      ENVIRONMENT: environment,
      STACK_PROJECT_ID: projectId,
      STACK_API_URL: "https://stack.test",
      STACK_PUBLISHABLE_KEY: "pk_test",
      STACK_SERVER_KEY: "sk_test",
      API_TICKET_KEYS: JSON.stringify({ k1: ticketKey }),
      API_TICKET_CURRENT_KEY_ID: "k1",
      RELAY_SIGNING_KEY: relayPem,
      RELAY_KEY_ID: "relay-test",
      RELAY_URLS: JSON.stringify(["https://relay.test"]),
      PLANETSCALE_DATABASE_URL: "postgresql://fixture:fixture@fixture.psdb.cloud/control",
      FIXTURE_ENDPOINT_ID: fixturePublicKey,
    },
    outboundService: async (request: Request) => {
      const path = new URL(request.url).pathname;
      if (path === "/api/v1/users/me") return Response.json({ id: userId });
      if (path === "/api/v1/teams") return Response.json({ items: fixtureTeamMember ? [{ id: teamId }] : [] });
      if (path === "/api/v1/team-permissions") return Response.json({ items: [{ id: "$update_team", team_id: teamId, user_id: userId }] });
      return new Response(null, { status: 404 });
    },
  }), verbose: true });
  await mf.ready;
}, 60_000);

afterAll(async () => { await mf?.dispose(); });

test("the unauthenticated health route names the deployed revision and the rules the Worker implements", async () => {
  const { response, body } = await json("https://iroh.test/v2/health");
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(body.schemaId).toBe("health.v1");
  expect(body.environment).toBe(environment);
  expect(body.sourceRevision).toMatch(/^(?:[0-9a-f]{7,64}|unknown)$/);
  expect(body.rules).toContain("cmux.mac-peer-inbound.v1");
  expect((await mf.dispatchFetch("https://iroh.test/v2/health", { method: "POST" })).status).toBe(405);
  expect((await mf.dispatchFetch("https://iroh.test/v2/health?x=1")).status).toBe(404);
});

test("browser dashboard upgrade survives the Worker-to-Durable-Object boundary", async () => {
  const { token } = await issueDashboardTicket({
    authority: { environment, projectId, teamId, userId, verifiedAt: Math.floor(Date.now() / 1000) },
    origin: "https://cmux.com", clientInstanceId: "browser-dashboard", canManageTeam: false,
  }, "k1", dashboardTicketKey);
  const response = await mf.dispatchFetch("https://iroh.test/v2/dashboard/socket", {
    headers: { origin: "https://cmux.com", upgrade: "websocket", "sec-websocket-protocol": `cmux-v2-dashboard, ticket.${token}` },
  });
  const socket = response.webSocket;
  try {
    expect(response.status).toBe(101);
    expect(response.headers.get("sec-websocket-protocol")).toBe("cmux-v2-dashboard");
    expect(socket).not.toBeNull();
    const connected = new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("No dashboard connected frame")), 2000);
      socket!.addEventListener("message", event => { clearTimeout(timer); resolve(JSON.parse(String(event.data))); }, { once: true });
    });
    socket!.accept();
    expect((await connected).schemaId).toBe("dashboard.connected.v1");
    const directory = new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("No dashboard directory")), 2000);
      socket!.addEventListener("message", event => { clearTimeout(timer); resolve(JSON.parse(String(event.data))); }, { once: true });
    });
    socket!.send(JSON.stringify({ schemaId: "directory.request.v1", requestId: "browser-directory" }));
    const frame = await directory;
    expect(frame.schemaId).toBe("dashboard.directory.v1");
    expect(frame.directory.devices[0].descriptor.metadata.displayName).toBe("Control fixture");
  } finally { socket?.close(); }
});

test("browser socket admission still rejects foreign origins and expired tickets", async () => {
  for (const origin of ["https://evil.example", "https://cmux.com"]) {
    const { token } = await issueDashboardTicket({
      authority: { environment, projectId, teamId, userId, verifiedAt: 1000 },
      origin: "https://cmux.com", clientInstanceId: "expired-browser", canManageTeam: false,
    }, "k1", dashboardTicketKey);
    const response = await mf.dispatchFetch("https://iroh.test/v2/dashboard/socket", {
      headers: { origin, upgrade: "websocket", "sec-websocket-protocol": `cmux-v2-dashboard, ticket.${token}` },
    });
    expect(response.status).toBe(origin === "https://cmux.com" ? 401 : 403);
    expect(response.webSocket).toBeNull();
  }
});

test("dashboard closes an existing socket when membership is removed", async () => {
  const { token } = await issueDashboardTicket({
    authority: { environment, projectId, teamId, userId, verifiedAt: Math.floor(Date.now() / 1000) },
    origin: "https://cmux.com", clientInstanceId: "revocation-browser", canManageTeam: false,
  }, "k1", dashboardTicketKey);
  const response = await mf.dispatchFetch("https://iroh.test/v2/dashboard/socket", {
    headers: { origin: "https://cmux.com", upgrade: "websocket", "sec-websocket-protocol": `cmux-v2-dashboard, ticket.${token}` },
  });
  const socket = response.webSocket!;
  try {
    expect(response.status).toBe(101);
    const connected = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("No dashboard connected frame")), 2000);
      socket.addEventListener("message", event => {
        clearTimeout(timer);
        expect((JSON.parse(String(event.data)) as any).schemaId).toBe("dashboard.connected.v1");
        resolve();
      }, { once: true });
    });
    socket.accept();
    await connected;
    fixtureTeamMember = false;
    const closed = new Promise<CloseEvent>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Dashboard socket did not close after membership removal")), 2000);
      socket.addEventListener("close", event => { clearTimeout(timer); resolve(event); }, { once: true });
    });
    const denied = new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("No dashboard revocation error")), 2000);
      socket.addEventListener("message", event => { clearTimeout(timer); resolve(JSON.parse(String(event.data))); }, { once: true });
    });
    socket.send(JSON.stringify({ schemaId: "directory.request.v1", requestId: "removed-member" }));
    expect((await denied).code).toBe("team_access_revoked");
    expect((await closed).code).toBe(1008);
  } finally {
    fixtureTeamMember = true;
    socket.close();
  }
});

test("the web controller loads the directory over a real dashboard socket", async () => {
  const originalFetch = globalThis.fetch, originalSocket = globalThis.WebSocket;
  const ready = await mf.ready;
  const fixtureURL = new URL("/v2/dashboard/socket", ready);
  fixtureURL.protocol = "ws:";
  let sessionRequests = 0;
  globalThis.fetch = (async (input, init) => {
    const request = new Request(input, init);
    expect(request.url).toBe("https://cmux-v2.debussy.workers.dev/v2/dashboard/session");
    expect(request.headers.get("authorization")).toBe("Bearer fixture-access");
    const setup = await request.json() as any;
    const ticket = await issueDashboardTicket({
      authority: { environment, projectId, teamId, userId, verifiedAt: Math.floor(Date.now() / 1000) },
      origin: "https://cmux.com", clientInstanceId: setup.clientInstanceId, canManageTeam: false,
    }, "k1", dashboardTicketKey);
    sessionRequests++;
    return Response.json({ schemaId: "dashboard.ready.v1", requestId: setup.requestId, ticket });
  }) as typeof fetch;
  globalThis.WebSocket = class extends NodeWebSocket {
    constructor(url: string, protocols: string[]) {
      expect(url).toBe("wss://cmux-v2.debussy.workers.dev/v2/dashboard/socket");
      super(fixtureURL.href, protocols, { headers: { origin: "https://cmux.com" } });
    }
  } as unknown as typeof WebSocket;
  let resolveDirectory!: (value: any) => void;
  let rejectDirectory!: (reason: Error) => void;
  const result = new Promise<any>((resolve, reject) => { resolveDirectory = resolve; rejectDirectory = reject; });
  const controller = new V2DashboardController({
    origin: "https://cmux-v2.debussy.workers.dev", environment, projectId, teamId, userId,
    getStackToken: async () => "fixture-access", onDirectory: resolveDirectory,
    onError: message => rejectDirectory(new Error(message)),
  });
  const timeout = setTimeout(() => rejectDirectory(new Error("Directory never arrived")), 5000);
  try {
    void controller.start();
    const directory = await result;
    expect(directory.devices[0].descriptor.identity.deviceId).toBe("control-device");
    expect(directory.teamId).toBe(teamId);
    expect(sessionRequests).toBe(1);
  } finally {
    clearTimeout(timeout);
    await controller.stop();
    globalThis.fetch = originalFetch; globalThis.WebSocket = originalSocket;
  }
});

test("production HTTP router reaches the fixture TeamControl for directory and metadata", async () => {
  const requestId = "http-directory";
  const directory = { schemaId: "directory.request.v1", requestId };
  const setup = await setupFor(requestId, directory);
  const result = await json("https://iroh.test/v2/requests", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}`, "x-cmux-v2-setup": setupHeader(setup) },
    body: JSON.stringify(directory),
  });
  expect(result.response.status).toBe(200);
  expect(result.body.schemaId).toBe("directory.result.v1");
  expect(result.body.directory.devices[0].descriptor.identity.deviceId).toBe("control-device");

  const metadata = { schemaId: "device.metadata.v1", requestId: "http-metadata", metadata: { ...descriptor.metadata, displayName: "Updated fixture" } };
  const metadataSetup = await setupFor(metadata.requestId, metadata);
  const updated = await json("https://iroh.test/v2/requests", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}`, "x-cmux-v2-setup": setupHeader(metadataSetup) },
    body: JSON.stringify(metadata),
  });
  expect(updated.response.status).toBe(200);
  expect(updated.body.schemaId).toBe("operation.completed.v1");
});

test("production control session and relay paths use the same ticket authority", async () => {
  const sessionSetup = await setupFor("session-open", undefined);
  const session = await json("https://iroh.test/v2/control/session", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}` },
    body: JSON.stringify(sessionSetup),
  });
  expect(session.response.status).toBe(200);
  expect(session.body.schemaId).toBe("session.ready.v1");
  const relay = { schemaId: "relay.request.v1", requestId: "http-relay" };
  const relaySetup = await setupFor(relay.requestId, relay);
  const relayResult = await json("https://iroh.test/v2/requests", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}`, "x-cmux-v2-setup": setupHeader(relaySetup) },
    body: JSON.stringify(relay),
  });
  expect(relayResult.response.status).toBe(200);
  expect(relayResult.body.schemaId).toBe("relay.result.v1");
  expect(relayResult.body.credentials[0].relayURL).toBe("https://relay.test");
});

test("native socket setup delivers directory and relay responses", async () => {
  const setup = await setupFor("socket-open", undefined);
  const ready = await mf.ready;
  const socketURL = new URL("v2/control/socket", ready);
  socketURL.protocol = "ws:";
  const socket = new NodeWebSocket(socketURL.href, {
    headers: { authorization: `IrohTicket ${ticket}`, "x-cmux-v2-setup": setupHeader(setup) },
  });
  await new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); });
  await new Promise<void>((resolve, reject) => { socket.once("pong", () => resolve()); socket.once("error", reject); socket.ping(); });
  const request = (schemaId: string, requestId: string) => new Promise<any>((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timeout);
      socket.off("message", onMessage);
      socket.off("error", onError);
      socket.off("close", onClose);
    };
    const onError = (error: Error) => { cleanup(); reject(error); };
    const onClose = () => onError(new Error(`Socket closed before response to ${requestId}`));
    const onMessage = (value: NodeWebSocket.RawData) => {
      const response = JSON.parse(value.toString());
      if (response.requestId !== requestId) return;
      cleanup();
      resolve(response);
    };
    const timeout = setTimeout(() => onError(new Error(`Timed out waiting for ${requestId}`)), 2_000);
    socket.on("message", onMessage);
    socket.once("error", onError);
    socket.once("close", onClose);
    socket.send(JSON.stringify({ schemaId, requestId }));
  });
  try {
    expect((await request("directory.request.v1", "socket-directory")).schemaId).toBe("directory.result.v1");
    expect((await request("relay.request.v1", "socket-relay")).schemaId).toBe("relay.result.v1");
  } finally {
    socket.close();
  }
});

test("a socket reclaims reservations leaked by a Durable Object reset", async () => {
  // A reset drops sockets without webSocketClose, leaving reservations whose
  // unacknowledged output still counts against the user's aggregate budget.
  const namespace = await mf.getDurableObjectNamespace("USER_USAGE");
  const usage = namespace.getByName(objectName(environment, projectId, userId)) as any;
  for (const index of [1, 2, 3, 4]) {
    const sessionId = `leaked-${index}`;
    expect((await usage.reserveSocket({ userId, teamId, sessionId, deviceKey: "f".repeat(64) })).ok).toBe(true);
    expect((await usage.setOutput(userId, sessionId, 1, 2 * 1024 * 1024, 1000)).ok).toBe(true);
  }
  const setup = await setupFor("socket-leaked", undefined);
  const socketURL = new URL("v2/control/socket", await mf.ready);
  socketURL.protocol = "ws:";
  const socket = new NodeWebSocket(socketURL.href, {
    headers: { authorization: `IrohTicket ${ticket}`, "x-cmux-v2-setup": setupHeader(setup) },
  });
  const messages: any[] = [];
  socket.on("message", value => messages.push(JSON.parse(value.toString())));
  await new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); });
  const response = (requestId: string) => new Promise<any>((resolve, reject) => {
    const buffered = messages.find(message => message.requestId === requestId);
    if (buffered) { resolve(buffered); return; }
    const cleanup = () => {
      clearTimeout(timeout);
      socket.off("message", onMessage);
      socket.off("close", onClose);
      socket.off("error", onError);
    };
    const onError = (error: Error) => { cleanup(); reject(error); };
    const onClose = () => onError(new Error(`Socket closed before ${requestId}`));
    const onMessage = (value: NodeWebSocket.RawData) => {
      const message = JSON.parse(value.toString());
      if (message.requestId !== requestId) return;
      cleanup(); resolve(message);
    };
    const timeout = setTimeout(() => onError(new Error(`Timed out waiting for ${requestId}`)), 2_000);
    socket.on("message", onMessage);
    socket.once("close", onClose);
    socket.once("error", onError);
  });
  try {
    socket.send(JSON.stringify({ schemaId: "directory.request.v1", requestId: "leaked-directory" }));
    expect((await response("leaked-directory")).schemaId).toBe("directory.result.v1");
    const remaining = (await usage.listSocketReservations(userId)).value.map((row: { sessionId: string }) => row.sessionId);
    expect(remaining.filter((id: string) => id.startsWith("leaked-"))).toEqual([]);
    // Repeated leaked budgets must recover on an already-open connection
    // without reclaiming that live socket's reservation.
    for (let cycle = 0; cycle < 3; cycle += 1) {
      const live = (await usage.listSocketReservations(userId)).value;
      const liveIDs = live.map((row: any) => row.sessionId);
      expect(liveIDs.length).toBeGreaterThan(0);
      let available = 8 * 1024 * 1024 - live.reduce((sum: number, row: any) => sum + row.outputBytes, 0);
      for (let index = 0; available > 0; index += 1) {
        const sessionId = `leaked-cycle-${cycle}-${index}`;
        const bytes = Math.min(available, 2 * 1024 * 1024);
        expect((await usage.reserveSocket({ userId, teamId, sessionId, deviceKey: "f".repeat(64) })).ok).toBe(true);
        expect((await usage.setOutput(userId, sessionId, 1, bytes, 1000)).ok).toBe(true);
        available -= bytes;
      }
      const requestId = `directory-cycle-${cycle}`;
      const pending = response(requestId);
      socket.send(JSON.stringify({ schemaId: "directory.request.v1", requestId }));
      expect((await pending).schemaId).toBe("directory.result.v1");
      const retained = (await usage.listSocketReservations(userId)).value.map((row: any) => row.sessionId);
      expect(retained.filter((id: string) => id.startsWith("leaked-"))).toEqual([]);
      for (const id of liveIDs) expect(retained).toContain(id);
    }
  } finally {
    socket.close();
  }
});

const waitFor = async (satisfied: () => boolean, description: string, timeoutMs = 10_000) => {
  const deadline = Date.now() + timeoutMs;
  while (!satisfied()) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${description}`);
    await new Promise(resolve => setTimeout(resolve, 25));
  }
};

test("a team change during the budget call leaves the dashboard socket usable", async () => {
  // The dashboard reply names the team revision it read. A mutation that lands
  // while that reply is parked on its output budget call makes the revision
  // guard reject it, and the client must learn that from an error frame it can
  // act on rather than from a backpressure close it cannot.
  const raceUser = "revision-race-user";
  const { token } = await issueDashboardTicket({
    authority: { environment, projectId, teamId, userId: raceUser, verifiedAt: Math.floor(Date.now() / 1000) },
    origin: "https://cmux.com", clientInstanceId: "revision-race", canManageTeam: false,
  }, "k1", dashboardTicketKey);
  const response = await mf.dispatchFetch("https://iroh.test/v2/dashboard/socket", {
    headers: { origin: "https://cmux.com", upgrade: "websocket", "sec-websocket-protocol": `cmux-v2-dashboard, ticket.${token}` },
  });
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  const frames: any[] = [];
  const closeCodes: number[] = [];
  socket.addEventListener("message", event => frames.push(JSON.parse(String(event.data))));
  socket.addEventListener("close", event => closeCodes.push(event.code));
  socket.accept();
  try {
    await waitFor(() => frames.some(frame => frame.schemaId === "dashboard.connected.v1"), "the dashboard connected frame");
    const usage = await mf.getDurableObjectNamespace("USER_USAGE");
    await (usage.getByName(objectName(environment, projectId, raceUser)) as any).armOutputStall(3_000);
    socket.send(JSON.stringify({ schemaId: "directory.request.v1", requestId: "raced-directory" }));
    await new Promise(resolve => setTimeout(resolve, 500));
    const metadata = { schemaId: "device.metadata.v1", requestId: "race-metadata",
      metadata: { ...descriptor.metadata, displayName: `Raced fixture ${Date.now()}` } };
    const mutated = await json("https://iroh.test/v2/requests", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}`,
        "x-cmux-v2-setup": setupHeader(await setupFor(metadata.requestId, metadata)) },
      body: JSON.stringify(metadata),
    });
    expect(mutated.response.status).toBe(200);
    await waitFor(() => closeCodes.length > 0 || frames.some(frame => frame.requestId === "raced-directory"),
      "the raced directory reply");
    // 1013 tells the client to wait for the connection to drain. Nothing here is
    // draining, so it would back off instead of refreshing what changed.
    expect(closeCodes).toEqual([]);
    expect(frames.find(frame => frame.requestId === "raced-directory")?.schemaId).toBe("dashboard.directory.v1");
    // The reply names the revision it read, and the change notice that follows
    // is how the client learns to ask again.
    await waitFor(() => frames.some(frame => frame.schemaId === "directory.changed.v1"), "the directory change notice");
  } finally { socket.close(); }
}, 30_000);

test("a native reply rejected after its budget call leaves no gap in the delivery sequence", async () => {
  // Every prepared frame takes the next sequence number, and checkpoint receipts
  // report that number. A frame that is accounted for but never written makes the
  // client see a sequence it was never sent, and mints a checkpoint token that
  // only existed inside the unsent text, so its bytes can never be acknowledged.
  const setup = await setupFor("sequence-socket", undefined);
  const socketURL = new URL("v2/control/socket", await mf.ready);
  socketURL.protocol = "ws:";
  const socket = new NodeWebSocket(socketURL.href, {
    headers: { authorization: `IrohTicket ${ticket}`, "x-cmux-v2-setup": setupHeader(setup) },
  });
  const frames: any[] = [];
  socket.on("message", (value: { toString(): string }) => frames.push(JSON.parse(value.toString())));
  await new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); });
  try {
    await waitFor(() => frames.some(frame => frame.schemaId === "session.ready.v1"), "the session ready frame");
    const usage = await mf.getDurableObjectNamespace("USER_USAGE");
    await (usage.getByName(objectName(environment, projectId, userId)) as any).armOutputStall(3_000);
    socket.send(JSON.stringify({ schemaId: "directory.request.v1", requestId: "raced-native-directory" }));
    await new Promise(resolve => setTimeout(resolve, 500));
    const metadata = { schemaId: "device.metadata.v1", requestId: "native-race-metadata",
      metadata: { ...descriptor.metadata, displayName: `Sequence fixture ${Date.now()}` } };
    const mutated = await json("https://iroh.test/v2/requests", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}`,
        "x-cmux-v2-setup": setupHeader(await setupFor(metadata.requestId, metadata)) },
      body: JSON.stringify(metadata),
    });
    expect(mutated.response.status).toBe(200);
    await waitFor(() => frames.some(frame => frame.requestId === "raced-native-directory"), "the raced native reply");
    for (let index = 0; index < 32 && !frames.some(frame => frame.deliveryReceipt); index += 1) {
      const requestId = `sequence-fill-${index}`;
      socket.send(JSON.stringify({ schemaId: "directory.request.v1", requestId }));
      await waitFor(() => frames.some(frame => frame.requestId === requestId), requestId);
    }
    const carrier = frames.findIndex(frame => frame.deliveryReceipt);
    expect(carrier).toBeGreaterThanOrEqual(0);
    expect(frames[carrier].deliveryReceipt.sequence).toBe(carrier + 1);
  } finally { socket.close(); }
}, 30_000);

test("forged scope is rejected before the TeamControl binding", async () => {
  const forged = { ...descriptor, identity: { ...descriptor.identity, teamId: "other-team" } };
  const requestId = "forged-scope";
  const response = await mf.dispatchFetch("https://iroh.test/v2/control/session", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}` },
    body: JSON.stringify({ schemaId: "session.open.v1", requestId, device: forged }),
  });
  expect(response.status).toBe(403);
});


test("Mac control accepts either discovery or hosting without enabling iOS pairing", async () => {
  for (const capabilities of [[], ["cmux.mac-devices.v1"], ["cmux.mac-host.v1"]]) {
    const device = { ...descriptor, metadata: { ...descriptor.metadata,
      pairingEnabled: false, capabilities } };
    const setup = await setupFor(`capabilities-${capabilities.length}-${capabilities.join()}`, undefined, device);
    const result = await json("https://iroh.test/v2/control/session", {
      method: "POST", headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}` },
      body: JSON.stringify(setup),
    });
    expect(result.response.status).toBe(capabilities.length > 0 ? 200 : 403);
  }
});

test("a team at its socket cap sheds the next socket before it mutates team state", async () => {
  // At the cap the connection is refused either way, so anything the open path
  // does first is pure amplification: it verifies a caller-supplied signature,
  // consumes the device proof, bumps the team revision and then pushes that
  // revision to every socket already connected. Load shedding has to come first.
  const namespace = await mf.getDurableObjectNamespace("TEAM_CONTROL");
  const control = namespace.getByName(objectName(environment, projectId, teamId)) as any;
  const socketURL = new URL("v2/control/socket", await mf.ready);
  socketURL.protocol = "ws:";
  const holder = new NodeWebSocket(socketURL.href, {
    headers: { authorization: `IrohTicket ${ticket}`, "x-cmux-v2-setup": setupHeader(await setupFor("cap-holder", undefined)) },
  });
  const frames: any[] = [];
  holder.on("message", value => frames.push(JSON.parse(value.toString())));
  await new Promise<void>((resolve, reject) => { holder.once("open", resolve); holder.once("error", reject); });
  try {
    await control.setSocketLimit(1);
    const before = await control.teamRevision();
    // A ticket issued slightly ahead carries authority the team has not observed
    // yet, so the open path would record it and broadcast the new revision.
    const aheadTicket = (await issueTicket(descriptor, "k1", ticketSigningKey, Math.floor(Date.now() / 1000) + 5)).token;
    const refused = await mf.dispatchFetch("https://iroh.test/v2/control/socket", {
      headers: { upgrade: "websocket", authorization: `IrohTicket ${aheadTicket}`,
        "x-cmux-v2-setup": setupHeader(await setupFor("over-cap", undefined)) },
    });
    expect(refused.status).toBe(429);
    expect(refused.webSocket).toBeNull();
    expect(await control.teamRevision()).toBe(before);
    // The broadcast is scheduled with waitUntil, so give it room to arrive.
    await Bun.sleep(500);
    expect(frames.filter(frame => frame.schemaId === "directory.changed.v1")).toEqual([]);
    expect(holder.readyState).toBe(NodeWebSocket.OPEN);
  } finally {
    await control.restoreSocketLimit();
    holder.close();
  }
});

test("the account directory reaches AccountControl and the team record through the production Worker", async () => {
  const accountCall = async (schemaId: string, requestId: string, authorization = `IrohTicket ${ticket}`, device = descriptor) => {
    const request = { schemaId, requestId };
    const plain = { schemaId: "session.open.v1", requestId, device };
    const nonce = encodeBase64URL(crypto.getRandomValues(new Uint8Array(16)));
    const issuedAt = Math.floor(Date.now() / 1000);
    const signature = await crypto.subtle.sign("Ed25519", signingKey, new TextEncoder().encode(
      accountRequestSigningInput(device, requestId, issuedAt, { setup: plain, request }, nonce)));
    const setup = { ...plain, proof: { requestId, nonce, issuedAt, signature: encodeBase64URL(new Uint8Array(signature)) } };
    return json("https://iroh.test/v2/account/requests", {
      method: "POST", headers: { "content-type": "application/json", authorization, "x-cmux-v2-setup": setupHeader(setup) },
      body: JSON.stringify(request),
    });
  };
  const teamRequest = async (input: { schemaId: string; requestId: string; [key: string]: unknown }) => json("https://iroh.test/v2/requests", {
    method: "POST", headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}`, "x-cmux-v2-setup": setupHeader(await setupFor(input.requestId, input)) },
    body: JSON.stringify(input),
  });
  expect((await accountCall("account.directory.v1", "account-bearer", "Bearer stack-token")).response.status).toBe(401);
  // The fixture Mac has no Mac capability in its team record yet.
  const original = descriptor.metadata;
  await teamRequest({ schemaId: "device.metadata.v1", requestId: "account-plain", metadata: { ...original, capabilities: ["directory"] } });
  const refused = await accountCall("account.publish.v1", "account-publish-refused");
  expect(refused.response.status).toBe(403);
  expect(refused.body.code).toBe("permission_denied");
  const before = await teamRequest({ schemaId: "directory.request.v1", requestId: "team-before-account" });
  const hosting = { ...original, capabilities: ["cmux.mac-host.v1", "cmux.mac-devices.v1"] };
  expect((await teamRequest({ schemaId: "device.metadata.v1", requestId: "account-hosting", metadata: hosting })).body.schemaId).toBe("operation.completed.v1");
  const published = await accountCall("account.publish.v1", "account-publish");
  expect(published.response.status).toBe(200);
  expect(published.body).toMatchObject({ schemaId: "account.published.v1", device: { descriptor: { endpointId: descriptor.endpointId, metadata: { capabilities: hosting.capabilities } } } });
  const directory = await accountCall("account.directory.v1", "account-directory");
  expect(directory.body.schemaId).toBe("account.directory.result.v1");
  expect(directory.body.directory).toMatchObject({ userId, macs: [], inboundMacs: [], rules: ["cmux.mac-account-peer.v1"] });
  // Account traffic wrote nothing to the team: only the metadata change moved its revision.
  const after = await teamRequest({ schemaId: "directory.request.v1", requestId: "team-after-account" });
  expect(after.body.directory.revision).toBe(before.body.directory.revision + 1);
  expect(after.body.directory.rules).toEqual(["cmux.mac-peer-inbound.v1"]);
  // Another user's valid ticket reaches only that user's object: it cannot
  // borrow this user's device, and its own object lists nothing of this user.
  const other = { ...descriptor, identity: { ...descriptor.identity, userId: "other-user" } };
  const otherTicket = `IrohTicket ${(await issueTicket(other, "k1", ticketSigningKey, Math.floor(Date.now() / 1000))).token}`;
  const borrowed = await accountCall("account.directory.v1", "account-borrowed", otherTicket);
  expect(borrowed.response.status).toBe(403);
  expect(borrowed.body.code).toBe("identity_mismatch");
  for (const schemaId of ["account.directory.v1", "account.publish.v1"]) {
    const foreign = await accountCall(schemaId, `account-foreign-${schemaId}`, otherTicket, other);
    expect(foreign.response.status).toBe(409);
    expect(foreign.body.code).toBe("device_not_enrolled");
  }
  expect((await accountCall("account.withdraw.v1", "account-withdraw")).body.schemaId).toBe("account.withdrawn.v1");
  await teamRequest({ schemaId: "device.metadata.v1", requestId: "account-restore", metadata: original });
});

test("a forgotten Mac receives its revocation and can reopen a real recovery socket", async () => {
  const nextFrame = (socket: NodeWebSocket, schema: string) => new Promise<any>((resolve, reject) => {
    const cleanup = () => { clearTimeout(timer); socket.off("message", listener); socket.off("error", failed); };
    const failed = (error: Error) => { cleanup(); reject(error); };
    const timer = setTimeout(() => failed(new Error(`No ${schema}`)), 2000);
    const listener = (data: NodeWebSocket.RawData) => {
      const frame = JSON.parse(data.toString());
      if (frame.schemaId !== schema) return;
      cleanup();
      resolve(frame);
    };
    socket.on("message", listener);
    socket.on("error", failed);
  });
  const open = async (requestId: string, fresh: boolean) => {
    const url = new URL(fresh ? "/fixture/stack/socket" : "/v2/control/socket", await mf.ready);
    url.protocol = "ws:";
    const setup = await setupFor(requestId, undefined);
    const socket = new NodeWebSocket(url.href, {
      headers: { "x-cmux-v2-setup": setupHeader(setup), authorization: `IrohTicket ${ticket}` },
    });
    return { socket, ready: nextFrame(socket, "session.ready.v1") };
  };
  const { socket, ready: initialReady } = await open("before-forget", false);
  try {
    const device = (await initialReady).device;
    const revoked = nextFrame(socket, "device.revoked.v1");
    const request = { schemaId: "device.revoke.v1", requestId: "forget", deviceRecordId: device.deviceRecordId };
    const response = await mf.dispatchFetch("https://iroh.test/v2/requests", {
      method: "POST", headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}`,
        "x-cmux-v2-setup": setupHeader(await setupFor(request.requestId, request)) },
      body: JSON.stringify(request),
    });
    expect(response.status).toBe(200);
    expect(await revoked).toMatchObject({ deviceRecordId: device.deviceRecordId, recoverable: true });
    const oldTicket = await mf.dispatchFetch("https://iroh.test/v2/control/session", {
      method: "POST", headers: { "content-type": "application/json", authorization: `IrohTicket ${ticket}` },
      body: JSON.stringify(await setupFor("old-ticket", undefined)),
    });
    expect(oldTicket.status).toBe(403);
    const recovery = await open("fresh-stack", true);
    const recoveredSocket = recovery.socket;
    try {
      const frame = await recovery.ready;
      expect(frame.challenge).toBeDefined();
      expect(frame.device).toBeUndefined();
    } finally { recoveredSocket.close(); }
  } finally { socket.close(); }
});
