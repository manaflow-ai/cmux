import { beforeAll, expect, test } from "bun:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { join } from "node:path";
import NodeWebSocket from "ws";
import type { DeviceDescriptor } from "../src/contracts/common";
import { accountRequestSigningInput, encodeBase64URL, issueTicket, requestSigningInput } from "../src/crypto";
import { objectName } from "../src/routing";
import { relayPem, sign, deviceKey, type DeviceKey } from "../test/support/team-fixture";

/**
 * One Stack user (user-u) with Mac A in team X and Mac B in team Y, a
 * teammate T in X, and an iPhone P in X, all through the production Worker,
 * TeamControl and AccountControl under workerd. The same team operations run
 * twice, once with the account directory exercised and once without, and the
 * iPhone's team socket frames and team directory must be byte-identical.
 */
const FIXED_NOW = 1_900_000_000; // e2e/account-worker.ts freezes Date.now() here.
const environment = "test";
const projectId = "iroh-v2-account-test";
const HOST = ["cmux.mac-host.v1", "cmux.mac-devices.v1"];
const ticketKey = encodeBase64URL(new Uint8Array(32).fill(5));
let workerRoot = "";

type Device = { key: DeviceKey; descriptor: DeviceDescriptor; ticket: string };

async function device(seed: number, teamId: string, userId: string, deviceId: string, platform: "mac" | "ios", capabilities: string[]): Promise<Device> {
  const key = await deviceKey(seed);
  const descriptor: DeviceDescriptor = {
    identity: { environment, projectId, teamId, userId, deviceId, appNamespace: "com.cmux.app", buildTag: "release" },
    endpointId: key.endpointId, identityGeneration: 1,
    metadata: { platform, displayName: `${platform} ${deviceId}`, appVersion: "1.0", pairingEnabled: true, capabilities, relayURLs: ["https://relay.test/"] },
  };
  return { key, descriptor, ticket: (await issueTicket(descriptor, "k1", ticketKey, FIXED_NOW - 10)).token };
}

beforeAll(async () => {
  workerRoot = `/tmp/iroh-v2-account-worker-build-${Date.now()}`;
  const build = Bun.spawnSync({
    cmd: ["bunx", "wrangler", "deploy", "--config", join(import.meta.dir, "account-wrangler.jsonc"), "--dry-run", "--outdir", workerRoot],
    cwd: process.cwd(), stdout: "pipe", stderr: "pipe",
  });
  if (build.exitCode !== 0) throw new Error(new TextDecoder().decode(build.stderr));
}, 60_000);

async function runtime(): Promise<Miniflare> {
  const mf = new Miniflare({ ...convertV4MiniflareOptions({
    rootPath: workerRoot, resourcePersistencePath: `/tmp/iroh-v2-account-persist-${crypto.randomUUID()}`,
    scriptPath: "account-worker.js", modules: true,
    durableObjects: {
      TEAM_CONTROL: { className: "TestTeamControl", useSQLite: true },
      USER_USAGE: { className: "TestUserUsage", useSQLite: true },
      ACCOUNT_CONTROL: { className: "TestAccountControl", useSQLite: true },
    },
    compatibilityDate: "2026-09-10", compatibilityFlags: ["nodejs_compat"],
    bindings: {
      ENVIRONMENT: environment, STACK_PROJECT_ID: projectId, STACK_API_URL: "https://stack.test",
      STACK_PUBLISHABLE_KEY: "pk_test", STACK_SERVER_KEY: "sk_test",
      API_TICKET_KEYS: JSON.stringify({ k1: ticketKey }), API_TICKET_CURRENT_KEY_ID: "k1",
      RELAY_SIGNING_KEY: await relayPem(9), RELAY_KEY_ID: "relay-test", RELAY_URLS: JSON.stringify(["https://relay.test/"]),
      PLANETSCALE_DATABASE_URL: "postgresql://fixture:fixture@fixture.psdb.cloud/account",
    },
    outboundService: async () => new Response(null, { status: 404 }),
  }), verbose: true });
  await mf.ready;
  return mf;
}

const setupHeader = (setup: unknown) => encodeBase64URL(new TextEncoder().encode(JSON.stringify(setup)));
const nonce = () => encodeBase64URL(crypto.getRandomValues(new Uint8Array(16)));

async function signedSetup(owner: Device, requestId: string, body: (plain: object) => unknown, purpose: "team" | "account", as = owner.descriptor) {
  const plain = { schemaId: "session.open.v1", requestId, device: as };
  const value = nonce();
  const input = purpose === "team" ? requestSigningInput : accountRequestSigningInput;
  return { ...plain, proof: { requestId, nonce: value, issuedAt: FIXED_NOW, signature: await sign(owner.key, input(as, requestId, FIXED_NOW, body(plain), value)) } };
}

function frames(socket: NodeWebSocket) {
  const received: string[] = [];
  socket.on("message", data => received.push(data.toString()));
  const until = async (match: (frame: any) => boolean, description: string) => {
    const deadline = performance.now() + 5000;
    for (;;) {
      const found = received.map(text => JSON.parse(text)).find(match);
      if (found) return found;
      if (performance.now() > deadline) throw new Error(`Timed out waiting for ${description}; received ${received.join("\n")}`);
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  };
  return { received, until };
}

async function openSocket(mf: Miniflare, path: string, owner: Device, purpose: "team" | "account", as = owner.descriptor) {
  const url = new URL(path, await mf.ready);
  url.protocol = "ws:";
  const setup = await signedSetup(owner, `${purpose}-open-${as.identity.deviceId}`, plain => plain, purpose, as);
  const socket = new NodeWebSocket(url.href, { headers: { authorization: `IrohTicket ${owner.ticket}`, "x-cmux-v2-setup": setupHeader(setup) } });
  const stream = frames(socket);
  await new Promise<void>((resolve, reject) => {
    socket.once("open", () => resolve());
    socket.once("unexpected-response", (_request, response) => reject(Object.assign(new Error(`socket refused ${response.statusCode}`), { status: response.statusCode })));
    socket.once("error", reject);
  });
  return { socket, ...stream };
}

async function post(mf: Miniflare, path: string, owner: Device, input: { schemaId: string; requestId: string; [key: string]: unknown }, purpose: "team" | "account", as = owner.descriptor) {
  const setup = await signedSetup(owner, input.requestId, plain => ({ setup: plain, request: input }), purpose, as);
  const response = await mf.dispatchFetch(`https://iroh.test${path}`, {
    method: "POST", headers: { "content-type": "application/json", authorization: `IrohTicket ${owner.ticket}`, "x-cmux-v2-setup": setupHeader(setup) },
    body: JSON.stringify(input),
  });
  return { status: response.status, text: await response.text() };
}

async function scenario(withAccount: boolean) {
  const mf = await runtime();
  try {
    const a = await device(201, "team-x", "user-u", "mac-a", "mac", HOST);
    const phone = await device(202, "team-x", "user-u", "iphone", "ios", []);
    const teammate = await device(203, "team-x", "user-t", "mac-t", "mac", HOST);
    const b = await device(204, "team-y", "user-u", "mac-b", "mac", HOST);
    const bInZ = await device(205, "team-z", "user-u", "mac-b", "mac", HOST);
    const teams = await mf.getDurableObjectNamespace("TEAM_CONTROL");
    const team = (teamId: string) => teams.getByName(objectName(environment, projectId, teamId)) as unknown as { seed(teamId: string, device: DeviceDescriptor): Promise<string> };
    for (const item of [a, phone, teammate]) await team("team-x").seed("team-x", item.descriptor);
    const bRecordId = await team("team-y").seed("team-y", b.descriptor);

    // The iPhone's team socket observes everything team X sends while the rest happens.
    const phoneSocket = await openSocket(mf, "/v2/control/socket", phone, "team");
    let revision = (await phoneSocket.until(frame => frame.schemaId === "session.ready.v1", "phone ready")).teamRevision as number;
    const teamXMoved = async (next: number) => {
      if (next > revision) await phoneSocket.until(frame => frame.schemaId === "directory.changed.v1" && frame.revision === next, `team-x revision ${next}`);
      revision = Math.max(revision, next);
    };
    const teamRequest = async (owner: Device, input: { schemaId: string; requestId: string; [key: string]: unknown }) => {
      const result = await post(mf, "/v2/requests", owner, input, "team");
      expect({ input: input.requestId, status: result.status }).toEqual({ input: input.requestId, status: 200 });
      const body = JSON.parse(result.text);
      if (owner.descriptor.identity.teamId === "team-x") await teamXMoved(body.directory?.revision ?? body.revision);
      return body;
    };
    // Each Mac opens its team session as a client does, recording its authority lease.
    for (const owner of [a, teammate, b]) await teamRequest(owner, { schemaId: "directory.request.v1", requestId: `team-directory-${owner.descriptor.identity.deviceId}` });

    const account = async (owner: Device, schemaId: string, requestId: string, as = owner.descriptor) => {
      const result = await post(mf, "/v2/account/requests", owner, { schemaId, requestId }, "account", as);
      return { status: result.status, body: JSON.parse(result.text) };
    };
    const directory = async (owner: Device, requestId: string) => {
      const result = await account(owner, "account.directory.v1", requestId);
      expect(result.body.schemaId).toBe("account.directory.result.v1");
      return result.body.directory;
    };
    let accountSocket: Awaited<ReturnType<typeof openSocket>> | undefined;
    if (withAccount) {
      accountSocket = await openSocket(mf, "/v2/account/socket", a, "account");
      expect((await accountSocket.until(frame => frame.schemaId === "account.ready.v1", "account ready")).revision).toBe(0);
      expect((await account(a, "account.publish.v1", "publish-a")).body.schemaId).toBe("account.published.v1");
      const published = await account(b, "account.publish.v1", "publish-b");
      expect(published.body.schemaId).toBe("account.published.v1");
      await accountSocket.until(frame => frame.schemaId === "account.changed.v1" && frame.revision === published.body.revision, "A told about B");

      const fromA = await directory(a, "directory-a-1");
      expect(fromA.userId).toBe("user-u");
      expect(fromA.macs.map((mac: any) => [mac.descriptor.identity.teamId, mac.descriptor.endpointId])).toEqual([["team-y", b.descriptor.endpointId]]);
      expect(fromA.rules).toEqual(["cmux.mac-account-peer.v1"]);
      const fromB = await directory(b, "directory-b-1");
      expect(fromB.macs.map((mac: any) => mac.descriptor.endpointId)).toEqual([a.descriptor.endpointId]);
      expect(fromB.inboundMacs.map((peer: any) => [peer.device.descriptor.endpointId, peer.device.descriptor.identity.teamId])).toEqual([[a.descriptor.endpointId, "team-x"]]);

      // Teammate T: its own account object has nothing of user-u, and its
      // ticket cannot reach user-u's object with A's identity on any route.
      const fromT = await directory(teammate, "directory-t");
      expect({ macs: fromT.macs, inboundMacs: fromT.inboundMacs, userId: fromT.userId }).toEqual({ macs: [], inboundMacs: [], userId: "user-t" });
      for (const schemaId of ["account.directory.v1", "account.publish.v1", "account.withdraw.v1"]) {
        const borrowed = await account(teammate, schemaId, `borrowed-${schemaId}`, a.descriptor);
        expect({ schemaId, status: borrowed.status, code: borrowed.body.code }).toEqual({ schemaId, status: 403, code: "identity_mismatch" });
      }
      await expect(openSocket(mf, "/v2/account/socket", teammate, "account", a.descriptor)).rejects.toMatchObject({ status: 403 });
      // A Stack bearer token never opens an account route.
      const bearer = await mf.dispatchFetch("https://iroh.test/v2/account/requests", {
        method: "POST", headers: { "content-type": "application/json", authorization: "Bearer stack-token",
          "x-cmux-v2-setup": setupHeader(await signedSetup(a, "bearer", plain => ({ setup: plain, request: { schemaId: "account.directory.v1", requestId: "bearer" } }), "account")) },
        body: JSON.stringify({ schemaId: "account.directory.v1", requestId: "bearer" }),
      });
      expect(bearer.status).toBe(401);
    }

    // A Mac metadata change in team X: the account notice fires, team frames must not change.
    await teamRequest(a, { schemaId: "device.metadata.v1", requestId: "metadata-a", metadata: { ...a.descriptor.metadata, displayName: "Renamed A" } });
    if (withAccount) {
      const renamed = await directory(b, "directory-b-renamed");
      expect(renamed.macs.map((mac: any) => mac.descriptor.metadata.displayName)).toEqual(["Renamed A"]);
    }

    // B revokes itself in team Y: dropped from A's account directory on next read.
    await teamRequest(b, { schemaId: "device.revoke.v1", requestId: "revoke-b", deviceRecordId: bRecordId });
    if (withAccount) {
      await accountSocket!.until(frame => frame.schemaId === "account.changed.v1" && frame.revision >= 4, "A told about B's revocation");
      expect((await directory(a, "directory-a-revoked")).macs).toEqual([]);
    }

    // B moves to team Z with a new endpoint and republishes: only the Z endpoint remains.
    await team("team-z").seed("team-z", bInZ.descriptor);
    await teamRequest(bInZ, { schemaId: "directory.request.v1", requestId: "team-directory-b-z" });
    if (withAccount) {
      expect((await account(bInZ, "account.publish.v1", "publish-b-z")).body.schemaId).toBe("account.published.v1");
      const fromA = await directory(a, "directory-a-z");
      expect(fromA.macs.map((mac: any) => [mac.descriptor.identity.teamId, mac.descriptor.endpointId])).toEqual([["team-z", bInZ.descriptor.endpointId]]);
      accountSocket!.socket.close();
    }

    // The iPhone's team directory, read over its socket at the end.
    phoneSocket.socket.send(JSON.stringify({ schemaId: "directory.request.v1", requestId: "phone-final" }));
    await phoneSocket.until(frame => frame.requestId === "phone-final", "phone directory");
    await new Promise(resolve => setTimeout(resolve, 250));
    phoneSocket.socket.close();
    return { phoneFrames: [...phoneSocket.received] };
  } finally { await mf.dispose(); }
}

test("one user's Macs on teams X, Y and Z find each other; teammates and the iPhone see nothing new", async () => {
  const exercised = await scenario(true);
  const untouched = await scenario(false);
  expect(exercised.phoneFrames.length).toBeGreaterThan(2);
  const final = JSON.parse(exercised.phoneFrames.find(text => text.includes('"phone-final"'))!);
  expect(final.schemaId).toBe("directory.result.v1");
  expect(final.directory.rules).toEqual(["cmux.mac-peer-inbound.v1"]);
  expect(final.directory.devices.map((record: any) => record.descriptor.identity.deviceId).sort()).toEqual(["iphone", "mac-a"]);
  // Byte-for-byte: every frame the iPhone's team socket received, including its directory.
  expect(exercised.phoneFrames).toEqual(untouched.phoneFrames);
}, 120_000);
