import { describe, expect, test } from "bun:test";

import {
  AccountDeletionMutationBlockedError,
  AccountDeletionUserMutationInProgressError,
  type AccountDeletionUserMutationLease,
} from "../services/account/deletionLock";
import { AccountMetadataUserUnavailableError } from "../services/account/metadataMutation";
import {
  AdminGrantConflictError,
  AdminInvalidEmailError,
  AdminTeamNotFoundError,
  AdminUserNotFoundError,
  adminUserRow,
  applyPendingEmailGrants,
  createPendingEmailGrant,
  grantRecordFromServerMetadata,
  isAdminGrantablePlanId,
  isMissingGrantsTableError,
  isPlausibleEmail,
  listPendingEmailGrants,
  revokePendingEmailGrant,
  searchAdminTeams,
  searchAdminUsers,
  setManualPlanGrant,
  setTeamManualPlanGrant,
  type AdminGrantsDb,
  type SetManualPlanGrantInput,
  type AdminStackApp,
  type AdminStackTeam,
  type AdminStackUser,
} from "../services/admin/proGrants";
import type { StripeBillingStatus } from "../services/billing/pro";

type FakeUser = AdminStackUser & {
  readonly updates: Array<{ clientReadOnlyMetadata?: unknown; serverMetadata?: unknown }>;
};

function fakeUser(
  overrides: Partial<Omit<AdminStackUser, "update">> & { id: string },
): FakeUser {
  const updates: FakeUser["updates"] = [];
  const user = {
    primaryEmail: `${overrides.id}@example.com`,
    primaryEmailVerified: true,
    displayName: null,
    isAnonymous: false,
    signedUpAt: new Date("2026-01-02T03:04:05.000Z"),
    clientReadOnlyMetadata: {},
    serverMetadata: {},
    ...overrides,
    updates,
    async update(options: { clientReadOnlyMetadata?: unknown; serverMetadata?: unknown }) {
      updates.push(options);
      if ("clientReadOnlyMetadata" in options) {
        (user as { clientReadOnlyMetadata: unknown }).clientReadOnlyMetadata =
          options.clientReadOnlyMetadata;
      }
      if ("serverMetadata" in options) {
        (user as { serverMetadata: unknown }).serverMetadata = options.serverMetadata;
      }
    },
  };
  return user as FakeUser;
}

type FakeTeam = AdminStackTeam & {
  readonly updates: Array<{ clientReadOnlyMetadata?: unknown; serverMetadata?: unknown }>;
};

function fakeTeam(
  overrides: Partial<Omit<AdminStackTeam, "update" | "listUsers">> & { id: string; members?: number },
): FakeTeam {
  const updates: FakeTeam["updates"] = [];
  const { members = 0, ...rest } = overrides;
  const team = {
    displayName: `Team ${overrides.id}`,
    createdAt: new Date("2026-02-03T04:05:06.000Z"),
    clientReadOnlyMetadata: {},
    serverMetadata: {},
    ...rest,
    updates,
    async listUsers() {
      return Array.from({ length: members }, (_, index) => ({ id: `m${index}` }));
    },
    async update(options: { clientReadOnlyMetadata?: unknown; serverMetadata?: unknown }) {
      updates.push(options);
      if ("clientReadOnlyMetadata" in options) {
        (team as { clientReadOnlyMetadata: unknown }).clientReadOnlyMetadata =
          options.clientReadOnlyMetadata;
      }
      if ("serverMetadata" in options) {
        (team as { serverMetadata: unknown }).serverMetadata = options.serverMetadata;
      }
    },
  };
  return team as FakeTeam;
}

function fakeApp(
  users: readonly AdminStackUser[],
  teams: readonly AdminStackTeam[] = [],
): AdminStackApp & {
  readonly listCalls: unknown[];
} {
  const listCalls: unknown[] = [];
  return {
    listCalls,
    async getUser(userId) {
      return users.find((user) => user.id === userId) ?? null;
    },
    async listUsers(options) {
      listCalls.push(options);
      const query = (options.query ?? "").toLowerCase();
      return users.filter((user) =>
        user.id === query ||
        (user.primaryEmail ?? "").toLowerCase().includes(query) ||
        (user.displayName ?? "").toLowerCase().includes(query),
      );
    },
    async getTeam(teamId) {
      return teams.find((team) => team.id === teamId) ?? null;
    },
    async listTeams(options) {
      const query = (options.query ?? "").toLowerCase();
      return teams.filter((team) =>
        team.id === query || team.displayName.toLowerCase().includes(query),
      );
    },
  };
}

const noStripe: StripeBillingStatus = {
  customerId: null,
  subscriptionStatus: null,
  cancelAtPeriodEnd: false,
  hasCustomer: false,
  hasActiveSubscription: false,
};
const activeStripe: StripeBillingStatus = {
  customerId: "cus_1",
  subscriptionStatus: "active",
  cancelAtPeriodEnd: false,
  hasCustomer: true,
  hasActiveSubscription: true,
};

const lease: AccountDeletionUserMutationLease = { refresh: async () => undefined };

function directMutation(app: AdminStackApp) {
  return async <Result>(
    userId: string,
    operation: (user: AdminStackUser, lease: AccountDeletionUserMutationLease) => Promise<Result>,
  ): Promise<Result> => {
    const user = await app.getUser(userId);
    if (!user) throw new AccountMetadataUserUnavailableError(userId);
    return await operation(user, lease);
  };
}

const admin = { id: "admin-1", primaryEmail: "lawrence@manaflow.ai" };

describe("isAdminGrantablePlanId", () => {
  test("accepts pro and founders only", () => {
    expect(isAdminGrantablePlanId("pro")).toBe(true);
    expect(isAdminGrantablePlanId("founders")).toBe(true);
    expect(isAdminGrantablePlanId("team")).toBe(false);
    expect(isAdminGrantablePlanId("free")).toBe(false);
    expect(isAdminGrantablePlanId("")).toBe(false);
    expect(isAdminGrantablePlanId(null)).toBe(false);
  });
});

describe("adminUserRow", () => {
  test("reports Pro from a Stripe subscription", () => {
    const row = adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxPlan: "pro" } }), activeStripe);
    expect(row.isPro).toBe(true);
    expect(row.manualPlanId).toBeNull();
    expect(row.metadataPlanId).toBe("pro");
    expect(row.stripe.hasActiveSubscription).toBe(true);
    expect(row.signedUpAt).toBe("2026-01-02T03:04:05.000Z");
  });

  test("reports Pro from a paid manual grant without Stripe", () => {
    expect(adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } }), noStripe).isPro).toBe(true);
    expect(adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxVmPlan: "Founders" } }), noStripe).isPro).toBe(true);
    expect(adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxVmPlan: "free" } }), noStripe).isPro).toBe(false);
    expect(adminUserRow(fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxVmPlan: "enterprise" } }), noStripe).isPro).toBe(false);
    expect(adminUserRow(fakeUser({ id: "u1" }), noStripe).isPro).toBe(false);
  });

  test("surfaces the last grant from server metadata", () => {
    const row = adminUserRow(
      fakeUser({
        id: "u1",
        serverMetadata: {
          cmuxAdminPlanGrant: { plan: "pro", byUserId: "admin-1", byEmail: "lawrence@manaflow.ai", at: "2026-09-02T00:00:00.000Z" },
        },
      }),
      noStripe,
    );
    expect(row.lastGrant).toEqual({
      plan: "pro",
      byUserId: "admin-1",
      byEmail: "lawrence@manaflow.ai",
      at: "2026-09-02T00:00:00.000Z",
      pendingGrantId: null,
    });
    expect(grantRecordFromServerMetadata({ cmuxAdminPlanGrant: "nope" })).toBeNull();
    expect(grantRecordFromServerMetadata({ cmuxAdminPlanGrant: { plan: "pro" } })).toBeNull();
    expect(grantRecordFromServerMetadata(null)).toBeNull();
  });
});

describe("searchAdminUsers", () => {
  test("requires at least two characters", async () => {
    const app = fakeApp([fakeUser({ id: "u1" })]);
    expect(await searchAdminUsers(" a ", { app, stripeBillingStatus: async () => noStripe })).toEqual([]);
    expect(app.listCalls).toEqual([]);
  });

  test("lists non-anonymous matches with billing state", async () => {
    const app = fakeApp([
      fakeUser({ id: "u1", primaryEmail: "pat@example.com", clientReadOnlyMetadata: { cmuxVmPlan: "pro" } }),
      fakeUser({ id: "u2", primaryEmail: "pat-anon@example.com", isAnonymous: true }),
      fakeUser({ id: "u3", primaryEmail: "other@example.com" }),
    ]);
    const rows = await searchAdminUsers("pat", {
      app,
      stripeBillingStatus: async (userId) => (userId === "u3" ? activeStripe : noStripe),
    });
    expect(rows.map((row) => row.id)).toEqual(["u1"]);
    expect(rows[0]?.isPro).toBe(true);
    expect(app.listCalls).toEqual([
      { query: "pat", limit: 25, includeAnonymous: false, includeRestricted: true },
    ]);
  });
});

describe("setManualPlanGrant", () => {
  test("grants pro by writing cmuxVmPlan and an audit record", async () => {
    const target = fakeUser({ id: "u1", clientReadOnlyMetadata: { cmuxPlan: "free", other: 1 } });
    const app = fakeApp([target]);
    const row = await setManualPlanGrant({
      targetUserId: "u1",
      plan: "pro",
      admin,
      app,
      now: () => new Date("2026-09-02T10:00:00.000Z"),
      withFreshUser: directMutation(app),
      stripeBillingStatus: async () => noStripe,
    });
    expect(target.updates).toHaveLength(1);
    expect(target.updates[0]).toEqual({
      clientReadOnlyMetadata: { cmuxPlan: "free", other: 1, cmuxVmPlan: "pro" },
      serverMetadata: {
        cmuxAdminPlanGrant: {
          plan: "pro",
          byUserId: "admin-1",
          byEmail: "lawrence@manaflow.ai",
          at: "2026-09-02T10:00:00.000Z",
          pendingGrantId: null,
        },
      },
    });
    expect(row.isPro).toBe(true);
    expect(row.manualPlanId).toBe("pro");
    expect(row.lastGrant?.plan).toBe("pro");
  });

  test("removing the grant deletes cmuxVmPlan and reconciles cmuxPlan from Stripe", async () => {
    const target = fakeUser({
      id: "u1",
      clientReadOnlyMetadata: { cmuxVmPlan: "pro", cmuxPlan: "pro" },
    });
    const app = fakeApp([target]);
    const row = await setManualPlanGrant({
      targetUserId: "u1",
      plan: null,
      admin,
      app,
      withFreshUser: directMutation(app),
      stripeBillingStatus: async () => noStripe,
    });
    // First write clears the override; the resolver then drops the stale
    // cmuxPlan mirror because there is no Stripe subscription behind it.
    expect(target.updates[0]?.clientReadOnlyMetadata).toEqual({ cmuxPlan: "pro" });
    expect(target.clientReadOnlyMetadata).toEqual({});
    expect(row.isPro).toBe(false);
    expect(row.manualPlanId).toBeNull();
    expect(row.metadataPlanId).toBeNull();
    expect(row.lastGrant?.plan).toBeNull();
  });

  test("removing the grant keeps Pro for a Stripe subscriber", async () => {
    const target = fakeUser({
      id: "u1",
      clientReadOnlyMetadata: { cmuxVmPlan: "founders", cmuxPlan: "pro" },
    });
    const app = fakeApp([target]);
    const row = await setManualPlanGrant({
      targetUserId: "u1",
      plan: null,
      admin,
      app,
      withFreshUser: directMutation(app),
      stripeBillingStatus: async () => activeStripe,
    });
    expect(target.updates).toHaveLength(1);
    expect(target.clientReadOnlyMetadata).toEqual({ cmuxPlan: "pro" });
    expect(row.isPro).toBe(true);
    expect(row.manualPlanId).toBeNull();
  });

  test("maps a missing user to AdminUserNotFoundError", async () => {
    const app = fakeApp([]);
    await expect(
      setManualPlanGrant({
        targetUserId: "missing",
        plan: "pro",
        admin,
        app,
        withFreshUser: directMutation(app),
        stripeBillingStatus: async () => noStripe,
      }),
    ).rejects.toBeInstanceOf(AdminUserNotFoundError);
  });

  test("refuses anonymous targets", async () => {
    const target = fakeUser({ id: "anon", isAnonymous: true });
    const app = fakeApp([target]);
    await expect(
      setManualPlanGrant({
        targetUserId: "anon",
        plan: "pro",
        admin,
        app,
        withFreshUser: directMutation(app),
        stripeBillingStatus: async () => noStripe,
      }),
    ).rejects.toBeInstanceOf(AdminUserNotFoundError);
    expect(target.updates).toEqual([]);
  });

  test("maps deletion and lease conflicts to AdminGrantConflictError", async () => {
    const app = fakeApp([fakeUser({ id: "u1" })]);
    for (const error of [
      new AccountDeletionMutationBlockedError("u1"),
      new AccountDeletionUserMutationInProgressError("u1"),
    ]) {
      await expect(
        setManualPlanGrant({
          targetUserId: "u1",
          plan: "pro",
          admin,
          app,
          withFreshUser: async () => {
            throw error;
          },
          stripeBillingStatus: async () => noStripe,
        }),
      ).rejects.toBeInstanceOf(AdminGrantConflictError);
    }
  });
});

describe("teams", () => {
  test("a team whose member list fails to load reports an unknown count", async () => {
    const broken = fakeTeam({ id: "tb", displayName: "Broken" });
    (broken as unknown as { listUsers: () => Promise<never> }).listUsers = async () => { throw new Error("provider down"); };
    const rows = await searchAdminTeams("broken", { app: fakeApp([], [broken]), stripeBillingStatus: async () => noStripe });
    expect(rows[0]?.memberCount).toBeNull();
  });

  test("searchAdminTeams reports Team access from Stripe or a manual grant", async () => {
    const app = fakeApp([], [
      fakeTeam({ id: "t1", displayName: "Acme", members: 3, clientReadOnlyMetadata: { cmuxVmPlan: "team" } }),
      fakeTeam({ id: "t2", displayName: "Acme Labs", members: 1 }),
      fakeTeam({ id: "t3", displayName: "Other" }),
    ]);
    const rows = await searchAdminTeams("acme", {
      app,
      stripeBillingStatus: async (teamId) => (teamId === "t2" ? activeStripe : noStripe),
    });
    expect(rows.map((row) => [row.id, row.isTeam, row.manualPlanId, row.memberCount])).toEqual([
      ["t1", true, "team", 3],
      ["t2", true, null, 1],
    ]);
  });

  function directTeamMutation(app: AdminStackApp) {
    return async <Result>(
      teamId: string,
      operation: (team: AdminStackTeam, lease: AccountDeletionUserMutationLease) => Promise<Result>,
    ): Promise<Result> => {
      const team = await app.getTeam(teamId);
      if (!team) throw new AdminTeamNotFoundError(teamId);
      return await operation(team, lease);
    };
  }

  test("setTeamManualPlanGrant writes the override with an audit record and keeps a live Stripe mirror", async () => {
    const team = fakeTeam({ id: "t1", members: 2, clientReadOnlyMetadata: { cmuxPlan: "team", other: 1 } });
    const app = fakeApp([], [team]);
    const granted = await setTeamManualPlanGrant({
      teamId: "t1",
      plan: "team",
      admin,
      app,
      now: () => new Date("2026-09-02T10:00:00.000Z"),
      withFreshTeam: directTeamMutation(app),
      hasActiveTeamSubscription: async () => true,
      stripeBillingStatus: async () => activeStripe,
    });
    expect(team.updates[0]).toEqual({
      clientReadOnlyMetadata: { cmuxPlan: "team", other: 1, cmuxVmPlan: "team" },
      serverMetadata: {
        cmuxAdminPlanGrant: {
          plan: "team",
          byUserId: "admin-1",
          byEmail: "lawrence@manaflow.ai",
          at: "2026-09-02T10:00:00.000Z",
        },
      },
    });
    expect(granted.isTeam).toBe(true);
    expect(granted.manualPlanId).toBe("team");
  });

  test("removing a team grant also drops a stale cmuxPlan mirror when Stripe lapsed", async () => {
    for (const stale of ["team", "pro", "founders"]) {
      const staleTeam = fakeTeam({ id: "ts", clientReadOnlyMetadata: { cmuxVmPlan: "team", cmuxPlan: stale } });
      const staleApp = fakeApp([], [staleTeam]);
      await setTeamManualPlanGrant({
        teamId: "ts", plan: null, admin, app: staleApp, withFreshTeam: directTeamMutation(staleApp),
        hasActiveTeamSubscription: async () => false, stripeBillingStatus: async () => noStripe,
      });
      expect(staleTeam.clientReadOnlyMetadata).toEqual({});
    }
    const team = fakeTeam({ id: "t1", clientReadOnlyMetadata: { cmuxVmPlan: "team", cmuxPlan: "team" } });
    const app = fakeApp([], [team]);
    const removed = await setTeamManualPlanGrant({
      teamId: "t1",
      plan: null,
      admin,
      app,
      withFreshTeam: directTeamMutation(app),
      hasActiveTeamSubscription: async () => false,
      stripeBillingStatus: async () => noStripe,
    });
    expect(team.clientReadOnlyMetadata).toEqual({});
    expect(removed.isTeam).toBe(false);
    expect(removed.manualPlanId).toBeNull();
    expect(removed.metadataPlanId).toBeNull();
    expect(removed.lastGrant?.plan).toBeNull();
  });

  test("removing a team grant keeps Team for a paying team and writes the mirror", async () => {
    const team = fakeTeam({ id: "t1", clientReadOnlyMetadata: { cmuxVmPlan: "team" } });
    const app = fakeApp([], [team]);
    const removed = await setTeamManualPlanGrant({
      teamId: "t1",
      plan: null,
      admin,
      app,
      withFreshTeam: directTeamMutation(app),
      hasActiveTeamSubscription: async () => true,
      stripeBillingStatus: async () => activeStripe,
    });
    expect(team.clientReadOnlyMetadata).toEqual({ cmuxPlan: "team" });
    expect(removed.isTeam).toBe(true);
    expect(removed.manualPlanId).toBeNull();
  });

  test("setTeamManualPlanGrant rejects unknown teams and maps lease conflicts", async () => {
    const app = fakeApp([]);
    await expect(
      setTeamManualPlanGrant({ teamId: "missing", plan: "team", admin, app, withFreshTeam: directTeamMutation(app) }),
    ).rejects.toBeInstanceOf(AdminTeamNotFoundError);
    await expect(
      setTeamManualPlanGrant({
        teamId: "t1",
        plan: "team",
        admin,
        app: fakeApp([], [fakeTeam({ id: "t1" })]),
        withFreshTeam: async () => {
          throw new AccountDeletionUserMutationInProgressError("team:t1");
        },
      }),
    ).rejects.toBeInstanceOf(AdminGrantConflictError);
  });
});

type GrantRow = {
  id: string;
  email: string;
  plan: string;
  grantedByUserId: string;
  grantedByEmail: string | null;
  claimedAt: Date | null;
  appliedUserId: string | null;
  appliedAt: Date | null;
  revokedAt: Date | null;
  createdAt: Date;
};

type Row = Record<string, unknown>;

const COLUMN_FIELDS: Record<string, string> = {
  id: "id",
  email: "email",
  plan: "plan",
  granted_by_user_id: "grantedByUserId",
  granted_by_email: "grantedByEmail",
  claimed_at: "claimedAt",
  applied_user_id: "appliedUserId",
  applied_at: "appliedAt",
  revoked_at: "revokedAt",
  created_at: "createdAt",
};

function isStringChunk(node: unknown): node is { value: string[] } {
  return !!node && typeof node === "object" && (node as { constructor?: { name?: string } }).constructor?.name === "StringChunk";
}
function isColumn(node: unknown): node is { name: string } {
  return !!node && typeof node === "object" && "table" in (node as object) && typeof (node as { name?: unknown }).name === "string";
}
function leafParams(chunks: unknown[]): unknown[] {
  const out: unknown[] = [];
  for (const chunk of chunks) {
    if (isStringChunk(chunk) || isColumn(chunk)) continue;
    if (Array.isArray(chunk)) {
      for (const item of chunk) out.push(item && typeof item === "object" && "value" in item ? (item as { value: unknown }).value : item);
    } else if (chunk && typeof chunk === "object" && (chunk as { constructor?: { name?: string } }).constructor?.name === "Param") {
      out.push((chunk as { value: unknown }).value);
    } else if (typeof chunk === "string" || chunk instanceof Date) {
      out.push(chunk);
    }
  }
  return out;
}

/** Evaluates a drizzle SQL condition tree against a plain row. */
function evalCondition(node: unknown, row: Row): boolean {
  if (!node || typeof node !== "object") return true;
  const chunks = (node as { queryChunks?: unknown[] }).queryChunks;
  if (!Array.isArray(chunks)) return true;
  const texts = chunks.map((chunk) => (isStringChunk(chunk) ? chunk.value.join("") : null));
  const children = chunks.filter((chunk) => !isStringChunk(chunk));
  if (texts.includes(" and ")) return children.every((child) => evalCondition(child, row));
  if (texts.includes(" or ")) return children.some((child) => evalCondition(child, row));
  const column = chunks.find(isColumn);
  if (!column) return children.every((child) => evalCondition(child, row));
  const value = row[COLUMN_FIELDS[column.name] ?? column.name];
  const op = texts.filter((text): text is string => text !== null).join("").replace(/[()]/g, "").trim();
  const params = leafParams(chunks);
  switch (op) {
    case "is null": return value === null || value === undefined;
    case "is not null": return value !== null && value !== undefined;
    case "=": return value === params[0];
    case "<": return value instanceof Date && params[0] instanceof Date ? value < params[0] : false;
    case "in": return params.includes(value);
    case "ilike": {
      const pattern = String(params[0]).toLowerCase();
      const needle = pattern.replace(/^%/, "").replace(/%$/, "").replace(/\\(.)/g, "$1");
      return String(value).toLowerCase().includes(needle);
    }
    default: throw new Error(`fakeGrantsDb: unsupported operator ${JSON.stringify(op)}`);
  }
}

/** In-memory double for the admin_plan_grants queries the service issues. */
function fakeGrantsDb(rows: GrantRow[]): AdminGrantsDb {
  const db = {
    transaction: async <Result,>(operation: (tx: AdminGrantsDb) => Promise<Result>) => await operation(db),
    select: () => ({
      from: () => ({
        where: (condition: unknown) => ({
          orderBy: () => ({
            limit: async (limit: number) =>
              rows
                .filter((row) => evalCondition(condition, row as unknown as Row))
                .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())
                .slice(0, limit),
          }),
        }),
      }),
    }),
    insert: () => ({
      values: (values: Partial<GrantRow>) => ({
        returning: async () => {
          const row: GrantRow = {
            id: `g${rows.length + 1}`,
            email: values.email!,
            plan: values.plan!,
            grantedByUserId: values.grantedByUserId!,
            grantedByEmail: values.grantedByEmail ?? null,
            claimedAt: null,
            appliedUserId: null,
            appliedAt: null,
            revokedAt: null,
            createdAt: new Date(2026, 8, 2, 0, rows.length),
          };
          rows.push(row);
          return [row];
        },
      }),
    }),
    update: () => ({
      set: (values: Partial<GrantRow>) => ({
        where: (condition: unknown) => {
          const hit = rows.filter((row) => evalCondition(condition, row as unknown as Row));
          const run = async () => {
            for (const row of hit) Object.assign(row, values);
            return hit.map((row) => ({ ...row }));
          };
          const promise = run();
          return Object.assign(promise, { returning: async () => await promise });
        },
      }),
    }),
  } as unknown as AdminGrantsDb;
  return db;
}

describe("pending email grants", () => {
  test("isPlausibleEmail", () => {
    expect(isPlausibleEmail("pat@example.com")).toBe(true);
    expect(isPlausibleEmail("Pat.Smith+x@sub.example.co.uk")).toBe(true);
    expect(isPlausibleEmail("pat")).toBe(false);
    expect(isPlausibleEmail("pat@")).toBe(false);
    expect(isPlausibleEmail("@example.com")).toBe(false);
    expect(isPlausibleEmail("pat@localhost")).toBe(false);
    expect(isPlausibleEmail("pat @example.com")).toBe(false);
    expect(isPlausibleEmail("a@evil.com@manaflow.ai")).toBe(false);
    expect(isPlausibleEmail('"quoted"@example.com')).toBe(false);
    expect(isPlausibleEmail("pat\\x@example.com")).toBe(false);
    expect(isPlausibleEmail("pat@example..com")).toBe(false);
    expect(isPlausibleEmail("pat@-example.com")).toBe(true);
    expect(isPlausibleEmail(`${"a".repeat(65)}@example.com`)).toBe(false);
  });

  test("createPendingEmailGrant canonicalizes the email and rejects junk", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    const created = await createPendingEmailGrant({ email: "  New.Person@Example.com ", plan: "pro", admin, db });
    expect(created.email).toBe("new.person@example.com");
    expect(created.plan).toBe("pro");
    expect(created.grantedByEmail).toBe("lawrence@manaflow.ai");
    await expect(createPendingEmailGrant({ email: "nope", plan: "pro", admin, db })).rejects.toBeInstanceOf(
      AdminInvalidEmailError,
    );
  });

  test("listPendingEmailGrants filters open rows by substring", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "a@example.com", plan: "pro", admin, db });
    await createPendingEmailGrant({ email: "b@other.org", plan: "founders", admin, db });
    await createPendingEmailGrant({ email: "c@example.com", plan: "pro", admin, db });
    await revokePendingEmailGrant({ grantId: "g3", db });
    const listed = await listPendingEmailGrants("example", { db });
    expect(listed.map((row) => row.email)).toEqual(["a@example.com"]);
  });

  test("a new grant for the same email supersedes the earlier open one", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    await createPendingEmailGrant({ email: "pat@example.com", plan: "founders", admin, db });
    expect(rows.map((row) => [row.plan, row.revokedAt !== null])).toEqual([["pro", true], ["founders", false]]);
    expect((await listPendingEmailGrants("pat", { db })).map((row) => row.plan)).toEqual(["founders"]);
  });

  test("applyPendingEmailGrants applies the open grant and closes it", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    await createPendingEmailGrant({ email: "pat@example.com", plan: "founders", admin, db });
    await createPendingEmailGrant({ email: "other@example.com", plan: "pro", admin, db });
    const grants: unknown[] = [];
    const applied = await applyPendingEmailGrants(
      { id: "u9", primaryEmail: "Pat@Example.com" },
      { db, grant: async (input) => { grants.push(input); return undefined; } },
    );
    expect(applied).toBe(1);
    expect(grants).toEqual([
      {
        targetUserId: "u9",
        plan: "founders",
        admin: { id: "admin-1", primaryEmail: "lawrence@manaflow.ai" },
        unlessAuditNewerThan: rows.find((row) => row.plan === "founders")!.createdAt,
        supersedePending: false,
        pendingGrantId: "g2",
      },
    ]);
    expect(rows.find((row) => row.plan === "founders")?.appliedUserId).toBe("u9");
    expect(rows.find((row) => row.plan === "pro" && row.email === "pat@example.com")?.appliedAt).toBeNull();
    expect(rows.find((row) => row.email === "other@example.com")?.appliedAt).toBeNull();
    // Second sign-in finds nothing open.
    expect(await applyPendingEmailGrants({ id: "u9", primaryEmail: "pat@example.com" }, { db, grant: async () => undefined })).toBe(0);
  });

  test("applyPendingEmailGrants never applies a row revoked before the claim, and releases the claim on failure", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    await revokePendingEmailGrant({ grantId: "g1", db });
    const grants: unknown[] = [];
    expect(
      await applyPendingEmailGrants({ id: "u9", primaryEmail: "pat@example.com" }, { db, grant: async (input) => { grants.push(input); } }),
    ).toBe(0);
    expect(grants).toEqual([]);

    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    await expect(
      applyPendingEmailGrants({ id: "u9", primaryEmail: "pat@example.com" }, { db, grant: async () => { throw new Error("stack down"); } }),
    ).rejects.toThrow("stack down");
    const row = rows.find((candidate) => candidate.id === "g2")!;
    expect(row.appliedAt).toBeNull();
    expect(row.appliedUserId).toBeNull();
  });

  test("a revoke that lands while the grant write is in flight wins and the grant is rolled back", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    const calls: Array<{ plan: unknown }> = [];
    const applied = await applyPendingEmailGrants(
      { id: "u9", primaryEmail: "pat@example.com" },
      {
        db,
        grant: async (input) => {
          calls.push({ plan: input.plan });
          if (input.plan !== null) {
            await revokePendingEmailGrant({ grantId: "g1", db, grant: async (inner) => { calls.push({ plan: inner.plan }); } });
          }
        },
      },
    );
    expect(applied).toBe(0);
    // The revoke's own conditional clear runs (a no-op if the write had not
    // landed yet), and finalization compensates again because the row was
    // revoked, without relying on the claim marker the revoke cleared.
    expect(calls).toEqual([{ plan: "pro" }, { plan: null }, { plan: null }]);
    const row = rows[0]!;
    expect(row.revokedAt).toBeInstanceOf(Date);
    expect(row.appliedAt).toBeNull();
    expect(row.appliedUserId).toBeNull();
  });

  test("a revoke between claim and write is still compensated, and a failed compensation restores the marker", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    let writes = 0;
    await expect(
      applyPendingEmailGrants(
        { id: "u9", primaryEmail: "pat@example.com" },
        {
          db,
          grant: async (input) => {
            if (input.plan !== null) {
              // Admin revokes while the claim is held but before the write lands.
              await revokePendingEmailGrant({ grantId: "g1", db, grant: async () => undefined });
              writes += 1;
              return;
            }
            throw new AdminGrantConflictError("u9");
          },
        },
      ),
    ).rejects.toBeInstanceOf(AdminGrantConflictError);
    expect(writes).toBe(1);
    // Marker restored so the durable cleanup retries at the next sign-in.
    expect(rows[0]!.revokedAt).toBeInstanceOf(Date);
    expect(rows[0]!.appliedUserId).toBe("u9");
    const seen: SetManualPlanGrantInput[] = [];
    await applyPendingEmailGrants({ id: "u9", primaryEmail: "pat@example.com" }, { db, grant: async (input) => { seen.push(input); } });
    expect(seen.map((input) => input.plan)).toEqual([null]);
    expect(rows[0]!.appliedUserId).toBeNull();
  });

  test("a fresh claim by another sign-in is not claimed twice, a stale one is", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    const now = new Date("2026-09-02T12:00:00.000Z");
    rows[0]!.appliedUserId = "u1";
    rows[0]!.claimedAt = new Date(now.getTime() - 60_000);
    expect(await applyPendingEmailGrants({ id: "u2", primaryEmail: "pat@example.com" }, { db, now: () => now, grant: async () => undefined })).toBe(0);
    rows[0]!.claimedAt = new Date(now.getTime() - 11 * 60_000);
    expect(await applyPendingEmailGrants({ id: "u2", primaryEmail: "pat@example.com" }, { db, now: () => now, grant: async () => undefined })).toBe(1);
    expect(rows[0]!.appliedUserId).toBe("u2");
  });

  test("a claim left behind by a crash is retried by the same user's next sign-in", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    const now = new Date("2026-09-02T12:00:00.000Z");
    rows[0]!.appliedUserId = "u9";
    rows[0]!.claimedAt = new Date(now.getTime() - 5_000);
    const plans: unknown[] = [];
    expect(await applyPendingEmailGrants({ id: "u9", primaryEmail: "pat@example.com" }, { db, now: () => now, grant: async (input) => { plans.push(input.plan); } })).toBe(1);
    expect(plans).toEqual(["pro"]);
    expect(rows[0]!.appliedAt).toEqual(now);
  });

  test("revoking a row that a crashed sign-in claimed clears that user's grant", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    rows[0]!.appliedUserId = "u9";
    rows[0]!.claimedAt = new Date();
    const calls: unknown[] = [];
    const result = await revokePendingEmailGrant({ grantId: "g1", db, admin, grant: async (input) => { calls.push({ target: input.targetUserId, plan: input.plan }); } });
    expect(result).toEqual({ revoked: true, clearedUserId: "u9" });
    expect(calls).toEqual([{ target: "u9", plan: null }]);
    expect(await revokePendingEmailGrant({ grantId: "g1", db, grant: async () => undefined })).toEqual({ revoked: false, clearedUserId: null });
  });

  test("revoke only clears the claimer's override when it is the one this grant produced", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    rows[0]!.appliedUserId = "u9";
    rows[0]!.claimedAt = new Date();
    const seen: SetManualPlanGrantInput[] = [];
    await revokePendingEmailGrant({ grantId: "g1", db, admin, grant: async (input) => { seen.push(input); } });
    expect(seen[0]?.onlyIfCurrent).toEqual({ plan: "pro", byUserId: "admin-1", pendingGrantId: "g1" });

    // The real writer honors onlyIfCurrent: an unrelated founders grant by
    // another admin is left untouched, a direct pro grant by the SAME admin
    // (no pending id) is left untouched, and the matching pending-produced
    // grant is cleared.
    const other = fakeUser({
      id: "u9",
      clientReadOnlyMetadata: { cmuxVmPlan: "founders" },
      serverMetadata: { cmuxAdminPlanGrant: { plan: "founders", byUserId: "admin-2", byEmail: null, at: "2026-09-02T00:00:00.000Z" } },
    });
    const app = fakeApp([other]);
    await setManualPlanGrant({
      targetUserId: "u9", plan: null, admin, app, withFreshUser: directMutation(app),
      stripeBillingStatus: async () => noStripe, onlyIfCurrent: { plan: "pro", byUserId: "admin-1", pendingGrantId: "g1" },
    });
    expect(other.updates).toEqual([]);
    const direct = fakeUser({
      id: "u7",
      clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      serverMetadata: { cmuxAdminPlanGrant: { plan: "pro", byUserId: "admin-1", byEmail: null, at: "2026-09-02T00:00:00.000Z" } },
    });
    const app3 = fakeApp([direct]);
    await setManualPlanGrant({
      targetUserId: "u7", plan: null, admin, app: app3, withFreshUser: directMutation(app3),
      stripeBillingStatus: async () => noStripe, onlyIfCurrent: { plan: "pro", byUserId: "admin-1", pendingGrantId: "g1" },
    });
    expect(direct.updates).toEqual([]);
    const mine = fakeUser({
      id: "u8",
      clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
      serverMetadata: { cmuxAdminPlanGrant: { plan: "pro", byUserId: "admin-1", byEmail: null, at: "2026-09-02T00:00:00.000Z", pendingGrantId: "g1" } },
    });
    const app2 = fakeApp([mine]);
    await setManualPlanGrant({
      targetUserId: "u8", plan: null, admin, app: app2, withFreshUser: directMutation(app2),
      stripeBillingStatus: async () => noStripe, onlyIfCurrent: { plan: "pro", byUserId: "admin-1", pendingGrantId: "g1" },
    });
    expect(mine.clientReadOnlyMetadata).toEqual({});
  });

  test("superseding a claimed row unwinds the claimer's grant instead of revoking blindly", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    rows[0]!.appliedUserId = "u9";
    rows[0]!.claimedAt = new Date();
    const seen: SetManualPlanGrantInput[] = [];
    const created = await createPendingEmailGrant({ email: "pat@example.com", plan: "founders", admin, db, grant: async (input) => { seen.push(input); } });
    expect(seen).toEqual([
      expect.objectContaining({ targetUserId: "u9", plan: null, onlyIfCurrent: { plan: "pro", byUserId: "admin-1", pendingGrantId: "g1" } }),
    ]);
    expect(rows[0]!.revokedAt).toBeInstanceOf(Date);
    expect(rows[0]!.appliedUserId).toBeNull();
    expect(created.plan).toBe("founders");
    expect(created.unclearedUserIds).toEqual([]);
    expect((await listPendingEmailGrants("pat", { db })).map((row) => row.plan)).toEqual(["founders"]);
  });

  test("superseding keeps the claim marker for durable retry when the clear fails", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    rows[0]!.appliedUserId = "u9";
    rows[0]!.claimedAt = new Date();
    const created = await createPendingEmailGrant({ email: "pat@example.com", plan: "founders", admin, db, grant: async () => { throw new AdminGrantConflictError("u9"); } });
    expect(created.plan).toBe("founders");
    expect(created.unclearedUserIds).toEqual(["u9"]);
    expect(rows[0]!.revokedAt).toBeInstanceOf(Date);
    expect(rows[0]!.appliedUserId).toBe("u9");
    // The user's next sign-in retries the clear before applying the new grant.
    const seen: SetManualPlanGrantInput[] = [];
    await applyPendingEmailGrants({ id: "u9", primaryEmail: "pat@example.com" }, { db, grant: async (input) => { seen.push(input); } });
    expect(seen.map((input) => input.plan)).toEqual([null, "founders"]);
    expect(rows[0]!.appliedUserId).toBeNull();
    expect(rows[1]!.appliedAt).toBeInstanceOf(Date);
  });

  test("a direct admin decision on a verified account supersedes older pending grants", async () => {
    const rows: GrantRow[] = [];
    const grantsDb = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "founders", admin, db: grantsDb });
    const target = fakeUser({ id: "u1", primaryEmail: "Pat@Example.com", primaryEmailVerified: true });
    const app = fakeApp([target]);
    await setManualPlanGrant({
      targetUserId: "u1", plan: "pro", admin, app, withFreshUser: directMutation(app),
      stripeBillingStatus: async () => noStripe, grantsDb,
    });
    expect(rows[0]!.revokedAt).toBeInstanceOf(Date);
    expect(await listPendingEmailGrants("pat", { db: grantsDb })).toEqual([]);

    // A declined conditional write supersedes nothing either.
    await createPendingEmailGrant({ email: "pat@example.com", plan: "founders", admin, db: grantsDb });
    await setManualPlanGrant({
      targetUserId: "u1", plan: null, admin, app, withFreshUser: directMutation(app),
      stripeBillingStatus: async () => noStripe, grantsDb,
      onlyIfCurrent: { plan: "founders", byUserId: "nobody", pendingGrantId: "gx" },
    });
    expect((await listPendingEmailGrants("pat", { db: grantsDb })).length).toBe(1);
    await supersedeForTest(grantsDb);

    // Unverified accounts do not supersede: the pending row may belong to the real owner.
    await createPendingEmailGrant({ email: "pat@example.com", plan: "founders", admin, db: grantsDb });
    const squatter = fakeUser({ id: "u2", primaryEmail: "pat@example.com", primaryEmailVerified: false });
    const app2 = fakeApp([squatter]);
    await setManualPlanGrant({
      targetUserId: "u2", plan: "pro", admin, app: app2, withFreshUser: directMutation(app2),
      stripeBillingStatus: async () => noStripe, grantsDb,
    });
    expect((await listPendingEmailGrants("pat", { db: grantsDb })).length).toBe(1);
  });

  async function supersedeForTest(db: AdminGrantsDb) {
    for (const row of await listPendingEmailGrants("pat", { db })) {
      await revokePendingEmailGrant({ grantId: row.id, db, grant: async () => undefined });
    }
  }

  test("an older pending grant never overwrites a newer direct admin decision", async () => {
    const target = fakeUser({
      id: "u1",
      clientReadOnlyMetadata: { cmuxVmPlan: "founders" },
      serverMetadata: { cmuxAdminPlanGrant: { plan: "founders", byUserId: "admin-2", byEmail: null, at: "2026-09-02T12:00:00.000Z" } },
    });
    const app = fakeApp([target]);
    await setManualPlanGrant({
      targetUserId: "u1", plan: "pro", admin, app, withFreshUser: directMutation(app),
      stripeBillingStatus: async () => noStripe, unlessAuditNewerThan: new Date("2026-09-02T11:00:00.000Z"),
    });
    expect(target.updates).toEqual([]);
    await setManualPlanGrant({
      targetUserId: "u1", plan: "pro", admin, app, withFreshUser: directMutation(app),
      stripeBillingStatus: async () => noStripe, unlessAuditNewerThan: new Date("2026-09-02T13:00:00.000Z"),
    });
    expect(target.clientReadOnlyMetadata).toEqual({ cmuxVmPlan: "pro" });
  });

  test("a claim stolen after the TTL is neither finalized nor compensated by the original sign-in", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    const seen: SetManualPlanGrantInput[] = [];
    const applied = await applyPendingEmailGrants(
      { id: "u9", primaryEmail: "pat@example.com" },
      {
        db,
        grant: async (input) => {
          seen.push(input);
          // Another sign-in steals the claim while our write is in flight.
          rows[0]!.appliedUserId = "u2";
          rows[0]!.claimedAt = new Date();
        },
      },
    );
    expect(applied).toBe(0);
    // The original sign-in removes exactly the grant it wrote (by pending id)
    // and leaves the claim with the sign-in that took it over.
    expect(seen.map((input) => [input.plan, input.onlyIfCurrent?.pendingGrantId ?? null, input.pendingGrantId ?? null])).toEqual([
      ["pro", null, "g1"],
      [null, "g1", null],
    ]);
    expect(rows[0]!.appliedAt).toBeNull();
    expect(rows[0]!.appliedUserId).toBe("u2");
  });

  test("a failed compensating clear is retried at the user's next sign-in", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    // State left behind by the race: revoked, claimed by u9, never finalized.
    rows[0]!.revokedAt = new Date();
    rows[0]!.appliedUserId = "u9";
    rows[0]!.claimedAt = new Date();
    const seen: SetManualPlanGrantInput[] = [];
    expect(await applyPendingEmailGrants({ id: "u9", primaryEmail: "pat@example.com" }, { db, grant: async (input) => { seen.push(input); } })).toBe(0);
    expect(seen).toEqual([
      expect.objectContaining({ targetUserId: "u9", plan: null, onlyIfCurrent: { plan: "pro", byUserId: "admin-1", pendingGrantId: "g1" } }),
    ]);
    expect(rows[0]!.appliedUserId).toBeNull();
    // Nothing left to retry.
    seen.length = 0;
    await applyPendingEmailGrants({ id: "u9", primaryEmail: "pat@example.com" }, { db, grant: async (input) => { seen.push(input); } });
    expect(seen).toEqual([]);
  });

  test("revoke is retry-safe: a failed metadata clear reopens the row", async () => {
    const rows: GrantRow[] = [];
    const db = fakeGrantsDb(rows);
    await createPendingEmailGrant({ email: "pat@example.com", plan: "pro", admin, db });
    rows[0]!.appliedUserId = "u9";
    rows[0]!.claimedAt = new Date();
    await expect(
      revokePendingEmailGrant({ grantId: "g1", db, admin, grant: async () => { throw new AdminGrantConflictError("u9"); } }),
    ).rejects.toBeInstanceOf(AdminGrantConflictError);
    expect(rows[0]!.revokedAt).toBeNull();
    expect((await listPendingEmailGrants("pat", { db })).length).toBe(1);
  });

  test("applyPendingEmailGrants ignores users without an email", async () => {
    expect(await applyPendingEmailGrants({ id: "u1", primaryEmail: null }, { db: fakeGrantsDb([]) })).toBe(0);
  });
});

describe("isMissingGrantsTableError", () => {
  test("recognizes pg 42P01 directly and through a drizzle cause chain", () => {
    expect(isMissingGrantsTableError(Object.assign(new Error("x"), { code: "42P01" }))).toBe(true);
    const wrapped = new Error("Failed query");
    (wrapped as { cause?: unknown }).cause = Object.assign(new Error("relation \"admin_plan_grants\" does not exist"), { code: "42P01" });
    expect(isMissingGrantsTableError(wrapped)).toBe(true);
    expect(isMissingGrantsTableError(new Error('relation "admin_plan_grants" does not exist'))).toBe(true);
    expect(isMissingGrantsTableError(new Error("connection refused"))).toBe(false);
    expect(isMissingGrantsTableError(null)).toBe(false);
  });

  test("applyPendingEmailGrants treats a missing table as nothing to apply", async () => {
    const missing = () => {
      throw Object.assign(new Error("Failed query"), { cause: { code: "42P01" } });
    };
    const db = {
      select: () => ({ from: () => ({ where: () => ({ orderBy: () => ({ limit: async () => missing() }) }) }) }),
      update: () => ({ set: () => ({ where: () => ({ returning: async () => missing() }) }) }),
    } as unknown as AdminGrantsDb;
    expect(await applyPendingEmailGrants({ id: "u1", primaryEmail: "a@example.com" }, { db })).toBe(0);
  });
});
