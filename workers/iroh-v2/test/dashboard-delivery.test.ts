import { expect, test } from "bun:test";
import { TeamBroker, type BrokerDependencies } from "../src/broker";
import { DashboardControl } from "../src/dashboard-control";
import type { DashboardClaims } from "../src/dashboard-auth";
import { emptyDeliveryState, type DeliveryState } from "../src/delivery";
import type { Environment } from "../src/environment";

const environment = "staging";
const projectId = "project";
const teamId = "team";
const userId = "user";
const sessionId = "dashboard-session";
const authority = { environment, projectId, teamId, userId, verifiedAt: 1000 } as const;

type Attachment = {
  kind: "dashboard"; sessionId: string; claims: DashboardClaims; deviceKey: string;
  delivery: DeliveryState; outputRevision: number; notifiedRevision: number; closed: boolean;
};
type OutputCall = { revision: number; bytes: number; messages: number };

/**
 * `UserSocketStore.setOutput` accepts an exact repeat of the recorded row and
 * otherwise only the next revision. The fake keeps that rule so a connection
 * whose local revision has fallen behind the user object fails here the same
 * way it fails in the Durable Object.
 */
function outputLedger(options: { refuseFirstCharge?: boolean } = {}) {
  const calls: OutputCall[] = [];
  let committed: OutputCall = { revision: 0, bytes: 0, messages: 0 };
  let refusalsLeft = options.refuseFirstCharge ? 1 : 0;
  return {
    calls,
    setOutput(_userId: string, _sessionId: string, revision: number, bytes: number, messages: number) {
      calls.push({ revision, bytes, messages });
      if (refusalsLeft > 0) {
        // The per-user aggregate cap is a sum over every socket that user holds,
        // so it can refuse one large frame and still have room for the much
        // smaller error frame that follows it at the same revision.
        refusalsLeft -= 1;
        return { ok: false as const, code: "slow_consumer" as const, status: 429, retryable: true };
      }
      if (revision === committed.revision && bytes === committed.bytes && messages === committed.messages) {
        return { ok: true as const, value: undefined };
      }
      if (revision !== committed.revision + 1) {
        return { ok: false as const, code: "revision_conflict" as const, status: 409, retryable: true };
      }
      committed = { revision, bytes, messages };
      return { ok: true as const, value: undefined };
    },
    consume() { return { ok: true as const, value: undefined }; },
  };
}

function connection(options: { refuseFirstCharge?: boolean } = {}) {
  const now = Math.floor(Date.now() / 1000);
  const claims: DashboardClaims = {
    version: 2, audience: "cmux-iroh-dashboard-v2", authority, origin: "https://cmux.com",
    clientInstanceId: "tab", canManageTeam: false, expiresAt: now + 3600, keyId: "key-1",
  };
  // A writer that lands while this reply is being prepared moves the team
  // revision past the one the directory frame reports.
  let storedRevision = 7;
  let concurrentWrite = false;
  const dependencies = {
    store: {
      readRevision: () => storedRevision,
      getRelayPreferences: () => ({ relayURLs: [], revision: 1 }),
      listDashboardDevices: () => {
        if (concurrentWrite) storedRevision += 1;
        return [];
      },
    },
    ownership: { reserve: async () => {} },
    relays: { configuration: { relayURLs: ["https://relay.example/"] } },
    now: () => Math.floor(Date.now() / 1000),
    charge: async () => {},
    issueTicket: async () => ({ token: "ticket", expiresAt: now + 3600, refreshAfter: now + 3300 }),
    verifyStack: async () => ({ ...authority }),
    canManageTeam: async () => false,
    verifyTeamMember: async () => true,
  } as unknown as BrokerDependencies;

  let stored: Attachment = {
    kind: "dashboard", sessionId, claims, deviceKey: "a".repeat(64),
    delivery: emptyDeliveryState(), outputRevision: 0, notifiedRevision: 0, closed: false,
  };
  const frames: string[] = [];
  const closes: { code: number; reason: string }[] = [];
  const ws = {
    readyState: 1,
    serializeAttachment(value: Attachment) { stored = structuredClone(value); },
    deserializeAttachment() { return stored; },
    send(text: string) { frames.push(text); },
    close(code: number, reason: string) { closes.push({ code, reason }); },
  } as unknown as WebSocket;

  const ledger = outputLedger(options);
  const control = new DashboardControl(
    { waitUntil: () => {} } as unknown as DurableObjectState,
    { ENVIRONMENT: environment, STACK_PROJECT_ID: projectId } as unknown as Environment,
    {
      broker: () => new TeamBroker(dependencies),
      user: () => ledger,
      reserve: async () => {},
      enqueue: (_ws: WebSocket, _bytes: number, action: () => Promise<void>) => action(),
      changed: () => {},
      opening: new Set<string>(),
    } as unknown as ConstructorParameters<typeof DashboardControl>[2],
  );

  return {
    control, ws, frames, closes, outputs: ledger.calls,
    attachment: () => stored,
    startConcurrentWrite: () => { concurrentWrite = true; },
    request: (requestId: string) => control.message(ws, JSON.stringify({ schemaId: "directory.request.v1", requestId })),
  };
}

test("a dashboard directory reply that loses a revision race still delivers its own error", async () => {
  const connected = connection();
  connected.startConcurrentWrite();
  await connected.request("stale-directory");

  const frames = connected.frames.map(text => JSON.parse(text) as Record<string, unknown>);
  expect(frames).toEqual([{ schemaId: "error.v1", requestId: "stale-directory", code: "resync_required", retryable: true }]);
  // Backpressure is the wrong story to tell the client here: it must re-fetch
  // the directory, not wait for the connection to drain.
  expect(connected.closes).toEqual([]);
});

test("a rejected dashboard frame charges no output and consumes no sequence", async () => {
  const connected = connection();
  connected.startConcurrentWrite();
  await connected.request("stale-directory");

  // Only the error frame reached the socket, so only the error frame may appear
  // in the user object's output ledger and in the connection's delivery state.
  expect(connected.outputs.map(call => call.revision)).toEqual([1]);
  expect(connected.attachment().outputRevision).toBe(1);
  expect(connected.attachment().delivery.sequence).toBe(1);
});

test("an accepted dashboard frame advances the ledger and the connection together", async () => {
  const connected = connection();
  await connected.request("fresh-directory");

  const frames = connected.frames.map(text => JSON.parse(text) as Record<string, unknown>);
  expect(frames).toHaveLength(1);
  expect(frames[0]!.schemaId).toBe("dashboard.directory.v1");
  expect(connected.outputs.map(call => call.revision)).toEqual([1]);
  expect(connected.attachment().outputRevision).toBe(1);
  expect(connected.attachment().delivery.sequence).toBe(1);
  expect(connected.closes).toEqual([]);
});

test("a dashboard frame whose charge is refused after the send closes the connection", async () => {
  const connected = connection({ refuseFirstCharge: true });
  await connected.request("fresh-directory");

  // The directory frame is already on the wire, so the refused charge cannot be
  // taken back. Leaving the socket open would let the error reply below fit the
  // headroom this frame just overran, and the connection would go on delivering
  // large frames that are never charged, so the connection has to go instead.
  const frames = connected.frames.map(text => JSON.parse(text) as Record<string, unknown>);
  expect(frames).toHaveLength(1);
  expect(frames[0]!.schemaId).toBe("dashboard.directory.v1");
  expect(connected.closes).toEqual([{ code: 1013, reason: "slow_consumer" }]);
  // Nothing is recorded for the frame whose charge was refused, and the closed
  // connection sends no second frame at the revision it did not commit.
  expect(connected.attachment().outputRevision).toBe(0);
  expect(connected.outputs.map(call => call.revision)).toEqual([1]);
});
