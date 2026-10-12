import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

// DELETE /api/vm/access-grants/[id] cuts the grant and its tunnels in our
// database, then revokes the Stack sessions that enrolled the Mac. It used to
// revoke them through the caller's session inside `Promise.allSettled` and
// answer `{ revoked: true }` whatever Stack said, so a throttled revocation
// left the sessions alive with nothing to retry it. A Stack 429 is now final
// for each call, which made that silent case common.

process.env.SKIP_ENV_VALIDATION = "1";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "00000000-0000-4000-8000-0000000000cc";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "pck_test";
process.env.STACK_SECRET_SERVER_KEY = "ssk_test";
process.env.STACK_API_BASE_URL = "https://stack.test";
process.env.CRON_SECRET = "cron-secret";

const USER_ID = "grant-owner-1";
const GRANT_ID = "6f1f6f0e-8f5a-4d55-9a37-7f6c0b1a2c3d";
const SESSIONS = ["session-a", "session-b"];

const callerRevokeSession = mock(async () => {
  throw Object.assign(new Error("Stack Auth rate limited"), { status: 429 });
});
const getUser = mock(async () => ({
  id: USER_ID,
  displayName: null,
  primaryEmail: "owner@example.com",
  selectedTeam: null,
  clientReadOnlyMetadata: {},
  listTeams: async () => Object.assign([], { nextCursor: null }),
  revokeSession: callerRevokeSession,
}));
mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const grantRevocations: string[] = [];
mock.module("../services/vms/routeWorkflow", () => ({
  runVmRoute: async () => {
    grantRevocations.push(GRANT_ID);
    return { ok: true, value: { revoked: true, accessGrantId: GRANT_ID, stackSessionIds: SESSIONS } };
  },
}));

mock.module("../services/vms/workflows", () => ({
  renameVmAccessGrant: () => ({ workflow: "rename" }),
  revokeVmAccessGrant: () => ({ workflow: "revoke" }),
  reconcileVmProviderStatuses: () => ({ workflow: "reconcile" }),
  reapStaleVmTunnels: () => ({ workflow: "reap" }),
  runVmWorkflow: async () => ({}),
}));

type MemoryRow = { stackSessionId: string; userId: string; attempts: number; nextAttemptAt: Date; revokedAt: Date | null };
const rows = new Map<string, MemoryRow>();
mock.module("../services/vms/stackSessionRevocationStore", () => ({
  databaseStackSessionRevocationStore: () => ({
    enqueue: async ({ userId, stackSessionIds }: { userId: string; stackSessionIds: readonly string[] }) => {
      for (const stackSessionId of stackSessionIds) {
        if (!rows.has(stackSessionId)) {
          rows.set(stackSessionId, { stackSessionId, userId, attempts: 0, nextAttemptAt: new Date(0), revokedAt: null });
        }
      }
    },
    listDue: async (now: Date, limit: number) => [...rows.values()]
      .filter((row) => !row.revokedAt && row.nextAttemptAt <= now)
      .slice(0, limit),
    listOpen: async (ids: readonly string[]) => ids.flatMap((id) => {
      const row = rows.get(id);
      return row && !row.revokedAt ? [row] : [];
    }),
    markRevoked: async (id: string, at: Date) => { rows.get(id)!.revokedAt = at; },
    markFailed: async (id: string, input: { attempts: number; nextAttemptAt: Date }) => {
      const row = rows.get(id)!;
      row.attempts = input.attempts;
      row.nextAttemptAt = input.nextAttemptAt;
    },
  }),
}));

const { DELETE } = await import("../app/api/vm/access-grants/[id]/route");
const { retryPendingStackSessionRevocations, stackServerSessionRevoker } = await import("../services/vms/stackSessionRevocations");
const { databaseStackSessionRevocationStore } = await import("../services/vms/stackSessionRevocationStore");
const { clearNativeAuthCacheForTests } = await import("../services/vms/auth");

const originalFetch = globalThis.fetch;
let stackAnswers: number[] = [];
const stackDeletes: string[] = [];

function stubStack(): void {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.origin === "https://stack.test" && init?.method === "DELETE") {
      stackDeletes.push(url.pathname);
      const status = stackAnswers.shift() ?? 200;
      return new Response(status === 200 ? "{}" : JSON.stringify({ error: "x" }), { status });
    }
    throw new Error(`unexpected fetch ${url}`);
  }) as typeof fetch;
}

function revokeRequest(): Request {
  return new Request(`https://cmux.test/api/vm/access-grants/${GRANT_ID}`, {
    method: "DELETE",
    headers: { authorization: "Bearer access-1", "x-stack-refresh-token": "refresh-1" },
  });
}

beforeEach(() => {
  clearNativeAuthCacheForTests();
  rows.clear();
  stackAnswers = [];
  stackDeletes.length = 0;
  grantRevocations.length = 0;
  callerRevokeSession.mockClear();
  stubStack();
});

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("access-grant session revocation", () => {
  test("a Stack 429 answers pending, keeps the grant cut, and the cron retry revokes the sessions", async () => {
    stackAnswers = [429, 429];
    const response = await DELETE(revokeRequest(), { params: Promise.resolve({ id: GRANT_ID }) });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ revoked: true, sessionRevocation: "pending" });
    expect(grantRevocations).toEqual([GRANT_ID]);
    expect([...rows.values()].map((row) => [row.stackSessionId, row.attempts, row.revokedAt])).toEqual([
      ["session-a", 1, null],
      ["session-b", 1, null],
    ]);

    const store = databaseStackSessionRevocationStore();
    const revoke = stackServerSessionRevoker();
    // Not due yet: the backoff holds the retry.
    expect(await retryPendingStackSessionRevocations({ store, revoke })).toEqual({ attempted: 0, revoked: 0, pending: 0 });
    const later = () => new Date(Date.now() + 2 * 60_000);
    expect(await retryPendingStackSessionRevocations({ store, revoke, now: later })).toEqual({ attempted: 2, revoked: 2, pending: 0 });
    expect([...rows.values()].every((row) => row.revokedAt !== null)).toBe(true);
    expect(stackDeletes).toEqual([
      "/api/v1/auth/sessions/session-a",
      "/api/v1/auth/sessions/session-b",
      "/api/v1/auth/sessions/session-a",
      "/api/v1/auth/sessions/session-b",
    ]);
  });

  test("an accepted revocation answers revoked and leaves nothing for the cron", async () => {
    const response = await DELETE(revokeRequest(), { params: Promise.resolve({ id: GRANT_ID }) });
    expect(await response.json()).toEqual({ revoked: true, sessionRevocation: "revoked" });
    const due = await retryPendingStackSessionRevocations({
      store: databaseStackSessionRevocationStore(),
      revoke: stackServerSessionRevoker(),
      now: () => new Date(Date.now() + 24 * 60 * 60_000),
    });
    expect(due.attempted).toBe(0);
  });

  test("a session Stack no longer has counts as revoked", async () => {
    globalThis.fetch = (async () => new Response("{}", {
      status: 404,
      headers: { "x-hexclave-known-error": "SESSION_NOT_FOUND" },
    })) as unknown as typeof fetch;
    await expect(stackServerSessionRevoker()("session-a")).resolves.toBeUndefined();
  });
});

describe("vm-reconcile cron", () => {
  test("retries due session revocations", async () => {
    rows.set("session-c", { stackSessionId: "session-c", userId: USER_ID, attempts: 3, nextAttemptAt: new Date(0), revokedAt: null });
    const { GET } = await import("../app/api/cron/vm-reconcile/route");
    const response = await GET(new Request("https://cmux.test/api/cron/vm-reconcile", {
      headers: { authorization: "Bearer cron-secret" },
    }));
    const body = await response.json() as { stackSessionRevocations?: unknown };
    expect(body.stackSessionRevocations).toEqual({ attempted: 1, revoked: 1, pending: 0 });
    expect(rows.get("session-c")!.revokedAt).not.toBeNull();
  });
});
