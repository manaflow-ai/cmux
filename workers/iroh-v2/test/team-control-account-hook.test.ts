import { expect, mock, test } from "bun:test";
import type { BrokerSession } from "../src/broker";
import { encodeResponse } from "../src/boundary";
import { emptyDeliveryState } from "../src/delivery";
import { TeamStore } from "../src/storage/team-store";
import { sqliteStorage } from "./support/sqlite-storage";
import { ENVIRONMENT, PROJECT_ID, RELAY_URL, TICKET_KEY, deterministicRandom, descriptor, deviceKey, identity, relayPem } from "./support/team-fixture";

// The production TeamControl class, run over bun:sqlite with fake sockets and
// bindings. Only the Durable Object base class is substituted.
mock.module("cloudflare:workers", () => ({
  DurableObject: class { constructor(readonly ctx: unknown, readonly env: unknown) {} },
}));
const { TeamControl } = await import("../src/team-control");

type Variant = "notified" | "rejects" | "throws" | "unbound" | "flaky";
type FakeSocket = { frames: string[]; attachment: unknown; readyState: number; send(text: string): void; close(): void;
  serializeAttachment(value: unknown): void; deserializeAttachment(): unknown };

function socket(session: BrokerSession): FakeSocket {
  const ws: FakeSocket = {
    frames: [], attachment: undefined, readyState: 1,
    send(text) { this.frames.push(text); }, close() { this.readyState = 3; },
    serializeAttachment(value) { this.attachment = structuredClone(value); }, deserializeAttachment() { return structuredClone(this.attachment); },
  };
  ws.serializeAttachment({ version: 1, session, deviceKey: "a".repeat(64), delivery: emptyDeliveryState(), outputRevision: 0, closed: false });
  return ws;
}

/** One Mac metadata change, then one iOS metadata change, with the account binding behaving per variant. */
async function run(variant: Variant) {
  const restore = deterministicRandom();
  try {
    const storage = sqliteStorage();
    const pending: Promise<unknown>[] = [];
    const sockets: FakeSocket[] = [];
    const notices: unknown[][] = [];
    const account = {
      getByName: () => {
        if (variant === "throws") throw new Error("binding unavailable");
        return { teamChanged: async (...args: unknown[]) => {
          notices.push(args);
          if (variant === "rejects" || (variant === "flaky" && notices.length === 1)) throw new Error("account object reset");
        } };
      },
    };
    const env = {
      ENVIRONMENT, STACK_PROJECT_ID: PROJECT_ID, STACK_API_URL: "https://stack.test", STACK_PUBLISHABLE_KEY: "pk", STACK_SERVER_KEY: "sk",
      API_TICKET_KEYS: JSON.stringify({ k1: TICKET_KEY }), API_TICKET_CURRENT_KEY_ID: "k1", RELAY_URLS: JSON.stringify([RELAY_URL]),
      RELAY_SIGNING_KEY: await relayPem(3), RELAY_KEY_ID: "relay-1", DATABASE_URL: "postgresql://fixture:fixture@fixture.test/db",
      TEAM_CONTROL: { idFromName: () => ({}) },
      USER_USAGE: { getByName: () => ({ consume: async () => ({ ok: true, value: { remaining: 1 } }), setOutput: async () => ({ ok: true, value: undefined }) }) },
      ...(variant === "unbound" ? {} : { ACCOUNT_CONTROL: account }),
    };
    const ctx = {
      id: { equals: () => true }, storage, blockConcurrencyWhile: async (action: () => Promise<void>) => action(),
      waitUntil: (promise: Promise<unknown>) => { pending.push(promise); },
      getWebSockets: (tag?: string) => tag ? [] : sockets,
    };
    const control = new TeamControl(ctx as never, env as never) as unknown as {
      broker(teamId: string): { execute(session: BrokerSession, input: unknown): Promise<any> };
      scheduleChanges(result: unknown, teamId: string): void;
    };
    const store = new TeamStore(storage, { environment: ENVIRONMENT, projectId: PROJECT_ID, teamId: "team-x" }, { initialize: false });
    const [macKey, phoneKey] = await Promise.all([81, 82].map(deviceKey));
    const mac = descriptor(macKey!, identity("team-x", "user-u", "mac-a"), "mac", ["cmux.mac-host.v1", "cmux.mac-devices.v1"]);
    const phone = descriptor(phoneKey!, identity("team-x", "user-u", "iphone"), "ios", []);
    const now = Math.floor(Date.now() / 1000);
    const records = [mac, phone].map(device => {
      store.issueChallenge(device.identity, { challengeId: `c-${device.identity.deviceId}`, nonceHash: "n", payloadHash: "p", issuedAt: now - 100, expiresAt: now + 1700 });
      return store.commitRegistration({ descriptor: device, challengeId: `c-${device.identity.deviceId}`, nonceHash: "n", payloadHash: "p",
        requestId: `r-${device.identity.deviceId}`, requestHash: `h-${device.identity.deviceId}`, now: now - 100 }).device;
    });
    const session = (device: typeof mac): BrokerSession => ({
      sessionId: `s-${device.identity.deviceId}`, identity: device.identity, endpointId: device.endpointId, identityGeneration: 1,
      authority: { environment: ENVIRONMENT, projectId: PROJECT_ID, teamId: "team-x", userId: "user-u", verifiedAt: now - 10 }, expiresAt: now + 3590, issueTicket: false,
    });
    const phoneSocket = socket(session(phone)), macSocket = socket(session(mac));
    sockets.push(phoneSocket, macSocket);
    const responses: string[] = [];
    const noticesAfter: number[] = [];
    for (const [device, name] of [[mac, "Renamed Mac"], [phone, "Renamed iPhone"]] as const) {
      const result = await control.broker("team-x").execute(session(device), {
        schemaId: "device.metadata.v1", requestId: `metadata-${device.identity.deviceId}`, metadata: { ...device.metadata, displayName: name },
      });
      responses.push(encodeResponse(result.response));
      control.scheduleChanges(result, "team-x");
      await Promise.allSettled(pending.splice(0));
      noticesAfter.push(notices.length);
    }
    return { responses, phoneFrames: phoneSocket.frames, macFrames: macSocket.frames, notices, noticesAfter, macRecordId: records[0]!.deviceRecordId };
  } finally { restore(); }
}

test("the account notice fires only for Mac rows and never changes a team response or frame", async () => {
  const notified = await run("notified");
  // Exactly the frames main sends: revision invalidations only, no account data.
  expect(notified.phoneFrames).toEqual([
    JSON.stringify({ schemaId: "directory.changed.v1", teamId: "team-x", revision: 4 }),
    JSON.stringify({ schemaId: "directory.changed.v1", teamId: "team-x", revision: 5 }),
  ]);
  expect(notified.macFrames).toEqual(notified.phoneFrames);
  expect(notified.responses).toEqual([
    JSON.stringify({ schemaId: "operation.completed.v1", requestId: "metadata-mac-a", revision: 4 }),
    JSON.stringify({ schemaId: "operation.completed.v1", requestId: "metadata-iphone", revision: 5 }),
  ]);
  // One notice for the Mac change, none for the iOS change.
  const macIdentity = { environment: ENVIRONMENT, projectId: PROJECT_ID, teamId: "team-x", userId: "user-u", deviceId: "mac-a", appNamespace: "com.cmux.app", buildTag: "release" };
  expect(notified.notices).toEqual([["user-u", "team-x", notified.macRecordId, macIdentity]]);
  expect(notified.noticesAfter).toEqual([1, 1]);
  for (const variant of ["rejects", "throws", "unbound", "flaky"] as const) {
    const failed = await run(variant);
    expect({ variant, responses: failed.responses, phone: failed.phoneFrames, mac: failed.macFrames })
      .toEqual({ variant, responses: notified.responses, phone: notified.phoneFrames, mac: notified.macFrames });
  }
});

test("a transiently failing account object still receives the notice; a dead one gets three bounded attempts", async () => {
  const flaky = await run("flaky");
  expect(flaky.notices.length).toBe(2);
  expect(flaky.notices[1]).toEqual(flaky.notices[0]);
  const dead = await run("rejects");
  expect(dead.notices.length).toBe(3);
});
