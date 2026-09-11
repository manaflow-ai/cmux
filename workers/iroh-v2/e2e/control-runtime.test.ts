import { expect, test, afterAll, beforeAll } from "bun:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { join } from "node:path";
import NodeWebSocket from "ws";
import { encodeBase64URL, issueTicket, requestSigningInput } from "../src/crypto";

let mf: Miniflare;
let descriptor: any;
let signingKey: CryptoKey;
let ticket = "";
let fixturePublicKey = "";
let workerRoot = "";
let persistencePath = "";
const environment = "test";
const projectId = "iroh-v2-test";
const teamId = "team-control";
const userId = "control-user";

const json = async (request: RequestInfo, init?: RequestInit) => {
  const response = await mf.dispatchFetch(request, init);
  return { response, body: await response.json() as any };
};

const setupFor = async (requestId: string, input: unknown) => {
  const plainSetup = { schemaId: "session.open.v1", requestId, device: descriptor };
  const nonce = encodeBase64URL(crypto.getRandomValues(new Uint8Array(16)));
  const issuedAt = Math.floor(Date.now() / 1000);
  const body = input === undefined ? plainSetup : { setup: plainSetup, request: input };
  const value = await crypto.subtle.sign("Ed25519", signingKey, new TextEncoder().encode(
    requestSigningInput(descriptor, requestId, issuedAt, body, nonce),
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
  }), verbose: true });
});

afterAll(async () => { await mf?.dispose(); });

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
  const messages: string[] = [];
  socket.on("message", value => messages.push(value.toString()));
  socket.send(JSON.stringify({ schemaId: "directory.request.v1", requestId: "socket-directory" }));
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(messages.some(value => value.includes('"schemaId":"directory.result.v1"'))).toBe(true);
  socket.send(JSON.stringify({ schemaId: "relay.request.v1", requestId: "socket-relay" }));
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(messages.some(value => value.includes('"schemaId":"relay.result.v1"'))).toBe(true);
  socket.close();
});

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
