// Operator Pro grants.
//
// An account holds up to two operator grants, one per slot:
// - classic: `clientReadOnlyMetadata.cmuxVmPlan`, the manual override that
//   `resolveProPlanStatus` and Cloud VM entitlements already honor and that
//   Stripe reconciliation never touches;
// - cmux NEXT: `clientReadOnlyMetadata.cmuxNextVmPlan` (`next_plus`,
//   `next_pro` or `next_max`), which the classic app never reads.
// A write to one slot never changes the other. Grants made before the NEXT
// slot existed hold the NEXT id in `cmuxVmPlan`; they read as the NEXT grant
// and move to `cmuxNextVmPlan` in the next admin write to either slot.
// Removing a grant deletes its key so the account falls back to its real
// Stripe state. Who granted what is kept per slot in
// `serverMetadata.cmuxAdminPlanGrant` (classic) and
// `serverMetadata.cmuxAdminNextPlanGrant` (NEXT), which end users cannot read.

import { and, desc, eq, ilike, inArray, isNotNull, isNull, lt, or } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { adminPlanGrants } from "../../db/schema";
import { getStackServerApp } from "../../app/lib/stack";
import { canonicalizeEmailForMatching } from "../billing/emailMatching";
import { isPlainEmailLocalPart } from "./access";
import {
  AccountDeletionMutationBlockedError,
  AccountDeletionUserMutationInProgressError,
  type AccountDeletionUserMutationLease,
} from "../account/deletionLock";
import { withTeamMetadataMutation } from "../teams/mutationLease";
import {
  AccountMetadataUserUnavailableError,
  type AccountMetadataUserLoader,
  withFreshAccountMetadataUser,
} from "../account/metadataMutation";
import {
  FOUNDERS_PLAN_ID,
  MAX_PLAN_ID,
  PRO_PLAN_ID,
  TEAM_PLAN_ID,
  classicManualVmPlanOverride,
  hasActiveTeamSubscriptionForTeam,
  isPaidPlanId,
  metadataPlanId,
  resolveProPlanStatus,
  stripeBillingStatusForTeam,
  stripeBillingStatusForUser,
  type ProMetadataJson,
  type StripeBillingStatus,
} from "../billing/pro";
import {
  NEXT_GRANT_METADATA_KEY,
  NEXT_MAX_PLAN_ID,
  NEXT_PLAN_IDS,
  NEXT_PLUS_PLAN_ID,
  NEXT_PRO_PLAN_ID,
  isNextPlanId,
  nextGrantPlanIdFromMetadata,
  nextPlanId,
  type NextPlanId,
} from "../billing/nextPlans";

// `next_plus` / `next_pro` / `next_max` grant a cmux NEXT Cloud plan (see
// services/billing/nextPlans.ts); the classic app reads them as no plan.
export const ADMIN_GRANTABLE_PLAN_IDS = [
  PRO_PLAN_ID,
  MAX_PLAN_ID,
  FOUNDERS_PLAN_ID,
  NEXT_PLUS_PLAN_ID,
  NEXT_PRO_PLAN_ID,
  NEXT_MAX_PLAN_ID,
] as const;
export type AdminGrantablePlanId = (typeof ADMIN_GRANTABLE_PLAN_IDS)[number];

/** Which operator grant a write targets: the classic plan or the cmux NEXT plan. */
export type AdminGrantSlot = "classic" | "next";
export const ADMIN_GRANT_SLOTS: readonly AdminGrantSlot[] = ["classic", "next"];

/** Server metadata key of the audit record for the cmux NEXT slot. */
export const NEXT_GRANT_AUDIT_KEY = "cmuxAdminNextPlanGrant";
const CLASSIC_GRANT_AUDIT_KEY = "cmuxAdminPlanGrant";

export const ADMIN_USER_SEARCH_LIMIT = 25;
export const ADMIN_USER_SEARCH_MIN_QUERY_LENGTH = 2;
/** Stack teams read per call while skipping test teams. */
export const ADMIN_TEAM_SEARCH_PAGE_SIZE = 100;
/** Stack pages one team search reads before it hands back a cursor. */
export const ADMIN_TEAM_SEARCH_MAX_PAGES = 5;
const ADMIN_TEAM_MEMBER_COUNT_CONCURRENCY = 8;

/**
 * The personal team Stack gives each probe account at sign-up is named after
 * the account: `cmux <env> smoke` (web/scripts/cloud-vm/smoke-vm-api.mjs),
 * `cmux <env> stress <n>` (stress-vm-api.mjs), `cmux <env> startup bench`
 * (bench-vm-startup.mjs), `cmux dogfood` (dogfood-journey.mjs), `cmux Iroh
 * production gate` (scripts/lib/temporary-stack-user.mjs), and the retired
 * `team check` and `freestyle rpc smoke` probes.
 */
const PROBE_TEAM_NAME =
  /^cmux (?:(?:prod|production|staging|dev) (?:smoke|team check|freestyle rpc smoke|stress \d+|startup bench)|dogfood|Iroh production gate)'s Team$/;

export function isProbeTeamName(displayName: string): boolean {
  return PROBE_TEAM_NAME.test(displayName);
}

export type AdminStackUser = {
  readonly id: string;
  readonly primaryEmail: string | null;
  readonly primaryEmailVerified: boolean;
  readonly displayName: string | null;
  readonly isAnonymous: boolean;
  readonly signedUpAt: Date;
  readonly clientReadOnlyMetadata: unknown;
  readonly serverMetadata?: unknown;
  update(options: {
    clientReadOnlyMetadata?: ProMetadataJson;
    serverMetadata?: ProMetadataJson;
  }): Promise<unknown>;
};

export type AdminStackTeam = {
  readonly id: string;
  readonly displayName: string;
  readonly createdAt?: Date;
  readonly clientReadOnlyMetadata: unknown;
  readonly serverMetadata?: unknown;
  listUsers(): Promise<readonly { readonly id: string }[]>;
  update(options: {
    clientReadOnlyMetadata?: ProMetadataJson;
    serverMetadata?: ProMetadataJson;
  }): Promise<unknown>;
};

export type AdminStackApp = {
  getUser(userId: string): Promise<AdminStackUser | null>;
  listUsers(options: {
    query?: string;
    limit?: number;
    includeAnonymous?: boolean;
    includeRestricted?: boolean;
  }): Promise<readonly AdminStackUser[]>;
  getTeam(teamId: string): Promise<AdminStackTeam | null>;
  listTeams(options: {
    query?: string;
    limit?: number;
    cursor?: string;
  }): Promise<readonly AdminStackTeam[] & { readonly nextCursor?: string | null }>;
};

export type AdminTeamRow = {
  readonly id: string;
  readonly displayName: string;
  readonly createdAt: string | null;
  /** Null when member listing failed. */
  readonly memberCount: number | null;
  /** An empty personal team left by a probe account (isProbeTeamName). */
  readonly isTestTeam: boolean;
  /** Effective Team access: Stripe team subscription or a paid manual grant. */
  readonly isTeam: boolean;
  /** The classic grant (`cmuxVmPlan`); never a cmux NEXT id. */
  readonly manualPlanId: string | null;
  /** The cmux NEXT grant (`cmuxNextVmPlan`, else a legacy NEXT id in `cmuxVmPlan`). */
  readonly nextManualPlanId: NextPlanId | null;
  readonly metadataPlanId: string | null;
  readonly stripe: {
    readonly subscriptionStatus: string | null;
    readonly cancelAtPeriodEnd: boolean;
    readonly hasActiveSubscription: boolean;
  };
  /** Audit record of the classic slot. */
  readonly lastGrant: AdminPlanGrantRecord | null;
  /** Audit record of the cmux NEXT slot. */
  readonly lastNextGrant: AdminPlanGrantRecord | null;
};

export type AdminPendingGrantRow = {
  readonly id: string;
  readonly email: string;
  readonly plan: string;
  readonly grantedByEmail: string | null;
  readonly createdAt: string;
};

export type AdminPlanGrantRecord = {
  readonly plan: string | null;
  readonly byUserId: string;
  readonly byEmail: string | null;
  readonly at: string;
  /** Set when the grant was applied from a pending email grant row. */
  readonly pendingGrantId?: string | null;
};

export type AdminUserRow = {
  readonly id: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
  readonly displayName: string | null;
  readonly signedUpAt: string;
  /** Effective Pro access: Stripe subscription or a paid manual grant. */
  readonly isPro: boolean;
  /** The classic grant (`cmuxVmPlan` override), when set; never a cmux NEXT id. */
  readonly manualPlanId: string | null;
  /** The cmux NEXT grant (`cmuxNextVmPlan`, else a legacy NEXT id in `cmuxVmPlan`). */
  readonly nextManualPlanId: NextPlanId | null;
  /** `cmuxPlan` mirror written from Stripe state. */
  readonly metadataPlanId: string | null;
  readonly stripe: {
    readonly subscriptionStatus: string | null;
    readonly cancelAtPeriodEnd: boolean;
    readonly hasActiveSubscription: boolean;
  };
  /** Audit record of the classic slot. */
  readonly lastGrant: AdminPlanGrantRecord | null;
  /** Audit record of the cmux NEXT slot. */
  readonly lastNextGrant: AdminPlanGrantRecord | null;
};

export class AdminUserNotFoundError extends Error {
  constructor(readonly userId: string) {
    super("Stack user not found");
    this.name = "AdminUserNotFoundError";
  }
}

export class AdminGrantConflictError extends Error {
  constructor(readonly userId: string) {
    super("Another account mutation is in progress");
    this.name = "AdminGrantConflictError";
  }
}

/** `slot: "next"` was sent with a classic plan id. */
export class AdminGrantSlotMismatchError extends Error {
  constructor(readonly plan: string) {
    super("A classic plan cannot be written to the cmux NEXT slot");
    this.name = "AdminGrantSlotMismatchError";
  }
}

const CLASSIC_GRANT_PLAN_IDS = [PRO_PLAN_ID, MAX_PLAN_ID, FOUNDERS_PLAN_ID] as const;

export function isAdminGrantSlot(value: unknown): value is AdminGrantSlot {
  return value === "classic" || value === "next";
}

/** The slot a plan id lives in. */
export function grantSlotForPlan(plan: string): AdminGrantSlot {
  return isNextPlanId(plan) ? "next" : "classic";
}

/**
 * The slot a write targets. A NEXT plan always goes to the NEXT slot, whatever
 * `requested` says; a removal (`plan: null`) goes to `requested`, else the
 * classic slot (the behaviour before slots existed). `slot: "next"` with a
 * classic plan is refused.
 */
export function resolveGrantSlot(plan: string | null, requested?: AdminGrantSlot): AdminGrantSlot {
  if (plan === null) return requested ?? "classic";
  const slot = grantSlotForPlan(plan);
  if (requested === "next" && slot === "classic") throw new AdminGrantSlotMismatchError(plan);
  return slot;
}

export function isAdminGrantablePlanId(value: unknown): value is AdminGrantablePlanId {
  return typeof value === "string" &&
    (ADMIN_GRANTABLE_PLAN_IDS as readonly string[]).includes(value);
}

export async function searchAdminUsers(
  query: string,
  options: {
    readonly app?: AdminStackApp;
    readonly stripeBillingStatus?: (userId: string) => Promise<StripeBillingStatus>;
  } = {},
): Promise<AdminUserRow[]> {
  const trimmed = query.trim();
  if (trimmed.length < ADMIN_USER_SEARCH_MIN_QUERY_LENGTH) return [];
  const app = options.app ?? defaultAdminStackApp();
  const users = await app.listUsers({
    query: trimmed,
    limit: ADMIN_USER_SEARCH_LIMIT,
    includeAnonymous: false,
    includeRestricted: true,
  });
  const billing = options.stripeBillingStatus ?? stripeBillingStatusForUser;
  return await Promise.all(
    users
      .filter((user) => !user.isAnonymous)
      .map(async (user) => adminUserRow(user, await billing(user.id))),
  );
}

export async function loadAdminUser(
  userId: string,
  options: {
    readonly app?: AdminStackApp;
    readonly stripeBillingStatus?: (userId: string) => Promise<StripeBillingStatus>;
  } = {},
): Promise<AdminUserRow | null> {
  const app = options.app ?? defaultAdminStackApp();
  const user = await app.getUser(userId);
  if (!user || user.isAnonymous) return null;
  const billing = options.stripeBillingStatus ?? stripeBillingStatusForUser;
  return adminUserRow(user, await billing(user.id));
}

export function adminUserRow(
  user: AdminStackUser,
  stripe: StripeBillingStatus,
): AdminUserRow {
  const manualPlanId = classicManualVmPlanOverride(user.clientReadOnlyMetadata);
  return {
    id: user.id,
    email: user.primaryEmail ?? null,
    emailVerified: user.primaryEmailVerified === true,
    displayName: user.displayName ?? null,
    signedUpAt: user.signedUpAt.toISOString(),
    isPro: stripe.hasActiveSubscription || isPaidPlanId(manualPlanId),
    manualPlanId,
    nextManualPlanId: nextGrantPlanIdFromMetadata(user.clientReadOnlyMetadata),
    metadataPlanId: metadataPlanId(user.clientReadOnlyMetadata),
    stripe: {
      subscriptionStatus: stripe.subscriptionStatus,
      cancelAtPeriodEnd: stripe.cancelAtPeriodEnd,
      hasActiveSubscription: stripe.hasActiveSubscription,
    },
    lastGrant: grantRecordFromServerMetadata(user.serverMetadata),
    lastNextGrant: nextGrantRecordFromServerMetadata(user.serverMetadata),
  };
}

export type SetManualPlanGrantInput = {
  readonly targetUserId: string;
  /** A grantable plan id, or null to remove the manual grant of `slot`. */
  readonly plan: AdminGrantablePlanId | null;
  /**
   * The slot to write. A NEXT plan always writes the NEXT slot; a removal
   * defaults to the classic slot, or to the slot of `onlyIfCurrent.plan`.
   * `"next"` with a classic plan throws AdminGrantSlotMismatchError.
   */
  readonly slot?: AdminGrantSlot;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  /**
   * Only write when the user's current override and audit record match this
   * grant. Used when unwinding a pending email grant so an unrelated manual
   * grant on the same account is left alone.
   */
  readonly onlyIfCurrent?: {
    readonly plan: string;
    readonly byUserId: string;
    /** Required to equal the audit record's pendingGrantId (null matches a direct grant). */
    readonly pendingGrantId: string | null;
  };
  /** Recorded in the audit record when applying a pending email grant. */
  readonly pendingGrantId?: string;
  /**
   * Skip the write when the account's audit record is newer than this
   * instant. Used when applying a pending email grant so it never overwrites
   * a later direct admin decision on the same account.
   */
  readonly unlessAuditNewerThan?: Date;
  /**
   * After a direct admin write on a verified account, revoke open pending
   * grants for the same email so an older pending grant cannot undo it.
   * Defaults to true for direct writes; pending-grant application passes
   * false.
   */
  readonly supersedePending?: boolean;
  readonly grantsDb?: AdminGrantsDb;
  readonly now?: () => Date;
  readonly app?: AdminStackApp;
  readonly withFreshUser?: FreshAdminUserMutation;
  readonly stripeBillingStatus?: (userId: string) => Promise<StripeBillingStatus>;
};

/** Reloads the user under the account-mutation lease and runs one write. */
export type FreshAdminUserMutation = <Result>(
  userId: string,
  operation: (
    user: AdminStackUser,
    lease: AccountDeletionUserMutationLease,
  ) => Promise<Result>,
) => Promise<Result>;

/**
 * Writes or clears one slot's manual grant under the account-mutation lease,
 * on a fresh read of the user, so a concurrent billing, TestFlight or admin
 * metadata write (including one to the other slot) cannot be clobbered. Then
 * re-reads the user so `cmuxPlan` is reconciled against Stripe when the grant
 * was removed.
 */
export async function setManualPlanGrant(
  input: SetManualPlanGrantInput,
): Promise<AdminUserRow> {
  const app = input.app ?? defaultAdminStackApp();
  const withFreshUser = input.withFreshUser ?? defaultWithFreshUser(app);
  const now = input.now ?? (() => new Date());
  const slot = resolveGrantSlot(
    input.plan,
    input.slot ?? (input.onlyIfCurrent ? grantSlotForPlan(input.onlyIfCurrent.plan) : undefined),
  );

  let mutated: AdminStackUser;
  let wrote = false;
  try {
    mutated = await withFreshUser(input.targetUserId, async (user, lease) => {
      if (user.isAnonymous) throw new AdminUserNotFoundError(input.targetUserId);
      if (input.onlyIfCurrent) {
        const currentPlan = slotPlanId(user.clientReadOnlyMetadata, slot);
        const audit = slotGrantRecord(user.serverMetadata, slot);
        if (
          currentPlan !== input.onlyIfCurrent.plan.toLowerCase() ||
          audit?.byUserId !== input.onlyIfCurrent.byUserId ||
          (audit?.pendingGrantId ?? null) !== input.onlyIfCurrent.pendingGrantId
        ) {
          return user;
        }
      }
      if (input.unlessAuditNewerThan) {
        const audit = slotGrantRecord(user.serverMetadata, slot);
        const auditAt = audit ? Date.parse(audit.at) : Number.NaN;
        if (!Number.isNaN(auditAt) && auditAt > input.unlessAuditNewerThan.getTime()) {
          return user;
        }
      }
      await lease.refresh();
      const client = metadataRecord(user.clientReadOnlyMetadata);
      const server = metadataRecord(user.serverMetadata);
      writeGrantSlot(client, server, slot, input.plan, {
        plan: input.plan,
        byUserId: input.admin.id,
        byEmail: input.admin.primaryEmail ?? null,
        at: now().toISOString(),
        pendingGrantId: input.pendingGrantId ?? null,
      });
      await user.update({
        clientReadOnlyMetadata: client as ProMetadataJson,
        serverMetadata: server as ProMetadataJson,
      });
      wrote = true;
      return user;
    });
  } catch (error) {
    if (error instanceof AccountMetadataUserUnavailableError) {
      throw new AdminUserNotFoundError(input.targetUserId);
    }
    if (
      error instanceof AccountDeletionMutationBlockedError ||
      error instanceof AccountDeletionUserMutationInProgressError
    ) {
      throw new AdminGrantConflictError(input.targetUserId);
    }
    throw error;
  }

  // A direct admin decision on a verified account supersedes any older
  // pending grant addressed to that mailbox; otherwise the pending grant would
  // re-apply at the next sign-in and silently undo this write.
  if (wrote && input.supersedePending !== false && mutated.primaryEmailVerified && mutated.primaryEmail) {
    await supersedeOpenGrantsForEmail(mutated.primaryEmail, mutated.id, slot, input.grantsDb);
  }

  // Outside the lease: the resolver takes its own lease when it needs to
  // rewrite `cmuxPlan` after the override stopped masking Stripe state.
  const billing = input.stripeBillingStatus ?? stripeBillingStatusForUser;
  const fresh = (await app.getUser(input.targetUserId)) ?? mutated;
  await resolveProPlanStatus(fresh, {
    stripeBillingStatus: billing,
    withFreshMetadataUser: (userId, operation) =>
      withFreshUser(userId, (user, lease) => operation(user, lease)),
  });
  const reloaded = (await app.getUser(input.targetUserId)) ?? fresh;
  return adminUserRow(reloaded, await billing(reloaded.id));
}

/**
 * The classic slot's audit record. A record naming a cmux NEXT plan predates
 * the NEXT slot and belongs to it, so it is not reported here.
 */
export function grantRecordFromServerMetadata(raw: unknown): AdminPlanGrantRecord | null {
  const record = parseGrantRecord(metadataRecord(raw)[CLASSIC_GRANT_AUDIT_KEY]);
  return record && isNextPlanId(record.plan) ? null : record;
}

/**
 * The cmux NEXT slot's audit record: `cmuxAdminNextPlanGrant`, else a legacy
 * classic-key record that names a NEXT plan.
 */
export function nextGrantRecordFromServerMetadata(raw: unknown): AdminPlanGrantRecord | null {
  const metadata = metadataRecord(raw);
  const own = parseGrantRecord(metadata[NEXT_GRANT_AUDIT_KEY]);
  if (own) return own;
  const legacy = parseGrantRecord(metadata[CLASSIC_GRANT_AUDIT_KEY]);
  return legacy && isNextPlanId(legacy.plan) ? legacy : null;
}

/** The grant a slot holds: the classic plan, or the cmux NEXT plan. */
function slotPlanId(clientMetadata: unknown, slot: AdminGrantSlot): string | null {
  return slot === "next"
    ? nextGrantPlanIdFromMetadata(clientMetadata)
    : classicManualVmPlanOverride(clientMetadata);
}

function slotGrantRecord(serverMetadata: unknown, slot: AdminGrantSlot): AdminPlanGrantRecord | null {
  return slot === "next"
    ? nextGrantRecordFromServerMetadata(serverMetadata)
    : grantRecordFromServerMetadata(serverMetadata);
}

/**
 * Applies one slot's write to copies of the account's metadata. The other
 * slot's grant and audit record are kept.
 *
 * Mirror, so the write is safe while an older reader that only knows
 * `cmuxVmPlan` is live: whenever the classic slot holds no classic value
 * (absent, or a NEXT id), the NEXT grant is also written to `cmuxVmPlan` as
 * the NEXT id (the legacy shape; classic code reads it as no classic plan).
 * When the classic slot holds a classic grant or restriction, a NEXT write
 * touches only `cmuxNextVmPlan`. A legacy NEXT id in `cmuxVmPlan` is copied to
 * `cmuxNextVmPlan` (with its audit record) before a classic write, and a
 * classic removal restores the mirror, so a classic change never drops a
 * NEXT grant.
 */
export function writeGrantSlot(
  client: Record<string, unknown>,
  server: Record<string, unknown>,
  slot: AdminGrantSlot,
  plan: string | null,
  grant: AdminPlanGrantRecord,
): void {
  const legacyNext = nextPlanId(client.cmuxVmPlan);
  if (slot === "next") {
    if (plan === null) {
      delete client[NEXT_GRANT_METADATA_KEY];
      if (legacyNext) delete client.cmuxVmPlan;
    } else {
      client[NEXT_GRANT_METADATA_KEY] = plan;
      if (!holdsClassicValue(client)) client.cmuxVmPlan = plan;
    }
    server[NEXT_GRANT_AUDIT_KEY] = grant;
    return;
  }
  if (legacyNext && !nextPlanId(client[NEXT_GRANT_METADATA_KEY])) {
    client[NEXT_GRANT_METADATA_KEY] = legacyNext;
    if (!parseGrantRecord(server[NEXT_GRANT_AUDIT_KEY])) {
      const legacyAudit = nextGrantRecordFromServerMetadata(server);
      if (legacyAudit) server[NEXT_GRANT_AUDIT_KEY] = server[CLASSIC_GRANT_AUDIT_KEY];
    }
  }
  if (plan === null) {
    const next = nextPlanId(client[NEXT_GRANT_METADATA_KEY]);
    if (next) client.cmuxVmPlan = next;
    else delete client.cmuxVmPlan;
  } else {
    client.cmuxVmPlan = plan;
  }
  server[CLASSIC_GRANT_AUDIT_KEY] = grant;
}

/**
 * Whether `cmuxVmPlan` holds anything a classic reader acts on: any value
 * that is present and is not a NEXT id. That includes an empty, whitespace or
 * non-string value: the classic readers disagree on those (the override
 * reader calls them unset, the billing plan reader keeps them as a
 * restriction that hides the subscription), so the NEXT mirror never
 * overwrites one. Such an account's NEXT grant is read from `cmuxNextVmPlan`.
 */
function holdsClassicValue(client: Record<string, unknown>): boolean {
  const value = client.cmuxVmPlan;
  return value !== undefined && value !== null && nextPlanId(value) === null;
}

function parseGrantRecord(record: unknown): AdminPlanGrantRecord | null {
  if (!record || typeof record !== "object" || Array.isArray(record)) return null;
  const value = record as Record<string, unknown>;
  if (typeof value.byUserId !== "string" || typeof value.at !== "string") return null;
  return {
    plan: typeof value.plan === "string" ? value.plan : null,
    byUserId: value.byUserId,
    byEmail: typeof value.byEmail === "string" ? value.byEmail : null,
    at: value.at,
    pendingGrantId: typeof value.pendingGrantId === "string" ? value.pendingGrantId : null,
  };
}

function metadataRecord(raw: unknown): Record<string, unknown> {
  return raw && typeof raw === "object" && !Array.isArray(raw)
    ? { ...(raw as Record<string, unknown>) }
    : {};
}

export function defaultAdminStackApp(): AdminStackApp {
  const app = getStackServerApp();
  return {
    getUser: (userId) => app.getUser(userId),
    listUsers: (options) => app.listUsers(options),
    getTeam: (teamId) => app.getTeam(teamId),
    listTeams: (options) => app.listTeams(options),
  };
}

function defaultWithFreshUser(app: AdminStackApp): FreshAdminUserMutation {
  return async (userId, operation) => {
    const loader: AccountMetadataUserLoader<AdminStackUser> = {
      getUser: (requestedUserId) => app.getUser(requestedUserId),
    };
    return await withFreshAccountMetadataUser({
      db: cloudDb(),
      userId,
      loader,
      operation: async (user, lease) => await operation(user, lease),
    });
  };
}

// ---------------------------------------------------------------------------
// Teams

export type AdminTeamSearchPage = {
  readonly teams: AdminTeamRow[];
  /** Pass back as `cursor` for the next page; null when Stack has no more. */
  readonly nextCursor: string | null;
  /** Empty probe teams skipped on this page (0 with includeTestTeams). */
  readonly hiddenTestTeams: number;
};

/**
 * One page of teams matching `query` (display name, or an exact Stack id).
 * Stack lists oldest first, so a common word like "cmux" can fill a page
 * with empty probe teams. By default those are skipped and the search keeps
 * reading Stack pages until it has a full page of other teams, reaching the
 * end, or ADMIN_TEAM_SEARCH_MAX_PAGES; `nextCursor` resumes from there.
 */
export async function searchAdminTeams(
  query: string,
  options: {
    readonly app?: AdminStackApp;
    readonly stripeBillingStatus?: (teamId: string) => Promise<StripeBillingStatus>;
    readonly cursor?: string | null;
    readonly includeTestTeams?: boolean;
  } = {},
): Promise<AdminTeamSearchPage> {
  const trimmed = query.trim();
  if (trimmed.length < ADMIN_USER_SEARCH_MIN_QUERY_LENGTH) return { teams: [], nextCursor: null, hiddenTestTeams: 0 };
  const app = options.app ?? defaultAdminStackApp();
  const billing = options.stripeBillingStatus ?? stripeBillingStatusForTeam;
  const includeTestTeams = options.includeTestTeams === true;
  const kept: Array<{ team: AdminStackTeam; members: number | null }> = [];
  let hiddenTestTeams = 0;
  let cursor = options.cursor ?? null;
  for (let page = 0; page < (includeTestTeams ? 1 : ADMIN_TEAM_SEARCH_MAX_PAGES); page += 1) {
    const teams = await app.listTeams({
      query: trimmed,
      limit: includeTestTeams ? ADMIN_USER_SEARCH_LIMIT : ADMIN_TEAM_SEARCH_PAGE_SIZE,
      ...(cursor ? { cursor } : {}),
    });
    const counted = await mapLimited(teams, ADMIN_TEAM_MEMBER_COUNT_CONCURRENCY, async (team) => ({
      team,
      members: await memberCount(team),
    }));
    for (const row of counted) {
      if (!includeTestTeams && isTestTeam(row.team, row.members)) hiddenTestTeams += 1;
      else kept.push(row);
    }
    cursor = teams.nextCursor ?? null;
    if (!cursor || kept.length >= ADMIN_USER_SEARCH_LIMIT) break;
  }
  const rows = await Promise.all(
    kept.map(async ({ team, members }) => adminTeamRow(team, await billing(team.id), members)),
  );
  return { teams: rows, nextCursor: cursor, hiddenTestTeams };
}

function isTestTeam(team: AdminStackTeam, members: number | null): boolean {
  return members === 0 && isProbeTeamName(team.displayName);
}

async function mapLimited<Item, Result>(
  items: readonly Item[],
  limit: number,
  work: (item: Item) => Promise<Result>,
): Promise<Result[]> {
  const results = new Array<Result>(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await work(items[index]!);
    }
  });
  await Promise.all(workers);
  return results;
}

/** Null when the provider could not list members; the UI then blocks a Team grant. */
async function memberCount(team: AdminStackTeam): Promise<number | null> {
  try {
    return (await team.listUsers()).length;
  } catch {
    return null;
  }
}

export function adminTeamRow(
  team: AdminStackTeam,
  stripe: StripeBillingStatus,
  members: number | null,
): AdminTeamRow {
  const manualPlanId = classicManualVmPlanOverride(team.clientReadOnlyMetadata);
  return {
    id: team.id,
    displayName: team.displayName,
    createdAt: team.createdAt ? team.createdAt.toISOString() : null,
    memberCount: members,
    isTestTeam: isTestTeam(team, members),
    isTeam: stripe.hasActiveSubscription || isPaidPlanId(manualPlanId),
    manualPlanId,
    nextManualPlanId: nextGrantPlanIdFromMetadata(team.clientReadOnlyMetadata),
    metadataPlanId: metadataPlanId(team.clientReadOnlyMetadata),
    stripe: {
      subscriptionStatus: stripe.subscriptionStatus,
      cancelAtPeriodEnd: stripe.cancelAtPeriodEnd,
      hasActiveSubscription: stripe.hasActiveSubscription,
    },
    lastGrant: grantRecordFromServerMetadata(team.serverMetadata),
    lastNextGrant: nextGrantRecordFromServerMetadata(team.serverMetadata),
  };
}

export class AdminTeamNotFoundError extends Error {
  constructor(readonly teamId: string) {
    super("Stack team not found");
    this.name = "AdminTeamNotFoundError";
  }
}

/** Reloads the team under a metadata-mutation lease and runs one write. */
export type FreshAdminTeamMutation = <Result>(
  teamId: string,
  operation: (
    team: AdminStackTeam,
    lease: AccountDeletionUserMutationLease,
  ) => Promise<Result>,
) => Promise<Result>;

/**
 * Writes or clears the team's classic `cmuxVmPlan` override; a cmux NEXT
 * grant on the team (including a legacy one, which moves to its own key) is
 * kept. A paid team override
 * gives every member the Team plan through billing team resolution, the same
 * way a Stripe Team subscription writes `cmuxPlan: "team"`.
 *
 * The write runs under the shared account-mutation lease keyed by the team
 * id, and the team is re-read inside it, so two admins cannot clobber each
 * other's metadata. In the same write the `cmuxPlan` mirror is reconciled
 * against the live Stripe team subscription, so removing a grant from a team
 * whose subscription lapsed leaves no stale paid mirror behind.
 */
export async function setTeamManualPlanGrant(input: {
  readonly teamId: string;
  readonly plan: typeof TEAM_PLAN_ID | null;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly now?: () => Date;
  readonly app?: AdminStackApp;
  readonly withFreshTeam?: FreshAdminTeamMutation;
  readonly hasActiveTeamSubscription?: (teamId: string) => Promise<boolean>;
  readonly stripeBillingStatus?: (teamId: string) => Promise<StripeBillingStatus>;
}): Promise<AdminTeamRow> {
  const app = input.app ?? defaultAdminStackApp();
  const now = input.now ?? (() => new Date());
  const withFreshTeam = input.withFreshTeam ?? defaultWithFreshTeam(app);
  const hasStripeTeam = input.hasActiveTeamSubscription ?? hasActiveTeamSubscriptionForTeam;

  try {
    await withFreshTeam(input.teamId, async (team, lease) => {
      const stripeActive = await hasStripeTeam(team.id);
      await lease.refresh();
      const client = metadataRecord(team.clientReadOnlyMetadata);
      const server = metadataRecord(team.serverMetadata);
      writeGrantSlot(client, server, "classic", input.plan, {
        plan: input.plan,
        byUserId: input.admin.id,
        byEmail: input.admin.primaryEmail ?? null,
        at: now().toISOString(),
      });
      // Mirror reconciliation, like syncTeamPlanMetadata but clearing any
      // stale paid value: entitlements treat pro, team, and founders alike.
      if (stripeActive) {
        client.cmuxPlan = TEAM_PLAN_ID;
      } else if (isPaidPlanId(typeof client.cmuxPlan === "string" ? client.cmuxPlan : null)) {
        delete client.cmuxPlan;
      }
      await team.update({
        clientReadOnlyMetadata: client as ProMetadataJson,
        serverMetadata: server as ProMetadataJson,
      });
    });
  } catch (error) {
    if (error instanceof AdminTeamNotFoundError) throw error;
    if (
      error instanceof AccountDeletionMutationBlockedError ||
      error instanceof AccountDeletionUserMutationInProgressError
    ) {
      throw new AdminGrantConflictError(input.teamId);
    }
    throw error;
  }

  const reloaded = await app.getTeam(input.teamId);
  if (!reloaded) throw new AdminTeamNotFoundError(input.teamId);
  const billing = input.stripeBillingStatus ?? stripeBillingStatusForTeam;
  return adminTeamRow(reloaded, await billing(reloaded.id), await memberCount(reloaded));
}

export function defaultWithFreshTeam(app: AdminStackApp): FreshAdminTeamMutation {
  return async (teamId, operation) =>
    await withTeamMetadataMutation(cloudDb(), teamId, async (lease) => {
      const team = await app.getTeam(teamId);
      if (!team || team.id !== teamId) throw new AdminTeamNotFoundError(teamId);
      return await operation(team, lease);
    });
}

// ---------------------------------------------------------------------------
// Pending grants for emails without a Stack user yet

export type AdminGrantsDb = Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "update"> & {
  transaction<Result>(
    operation: (tx: Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "update">) => Promise<Result>,
  ): Promise<Result>;
};

export function isPlausibleEmail(value: string): boolean {
  const trimmed = value.trim();
  if (trimmed.length < 3 || trimmed.length > 254) return false;
  const at = trimmed.lastIndexOf("@");
  if (at <= 0 || at === trimmed.length - 1) return false;
  if (!isPlainEmailLocalPart(trimmed.slice(0, at))) return false;
  return /^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/i.test(trimmed.slice(at + 1));
}

export async function listPendingEmailGrants(
  query: string,
  options: { readonly db?: AdminGrantsDb } = {},
): Promise<AdminPendingGrantRow[]> {
  const trimmed = query.trim().toLowerCase();
  if (trimmed.length < ADMIN_USER_SEARCH_MIN_QUERY_LENGTH) return [];
  const db = options.db ?? cloudDb();
  const rows = await db
    .select({
      id: adminPlanGrants.id,
      email: adminPlanGrants.email,
      plan: adminPlanGrants.plan,
      grantedByEmail: adminPlanGrants.grantedByEmail,
      createdAt: adminPlanGrants.createdAt,
    })
    .from(adminPlanGrants)
    .where(
      and(
        isNull(adminPlanGrants.appliedAt),
        isNull(adminPlanGrants.revokedAt),
        ilike(adminPlanGrants.email, `%${escapeLikePattern(trimmed)}%`),
      ),
    )
    .orderBy(desc(adminPlanGrants.createdAt))
    .limit(ADMIN_USER_SEARCH_LIMIT);
  return rows.map((row) => ({
    id: row.id,
    email: row.email,
    plan: row.plan,
    grantedByEmail: row.grantedByEmail ?? null,
    createdAt: row.createdAt.toISOString(),
  }));
}

function escapeLikePattern(value: string): string {
  return value.replace(/[\\%_]/g, (char) => `\\${char}`);
}

export type CreatePendingEmailGrantResult = AdminPendingGrantRow & {
  /**
   * Accounts whose superseded grant could not be cleared right now. The
   * clear is retried at that user's next sign-in; an admin can also use
   * "Remove grant" on the user row immediately. Never empty silently: the
   * route reports it and the UI shows it.
   */
  readonly unclearedUserIds: readonly string[];
};

export async function createPendingEmailGrant(input: {
  readonly email: string;
  readonly plan: AdminGrantablePlanId;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly db?: AdminGrantsDb;
  readonly grant?: (input: SetManualPlanGrantInput) => Promise<unknown>;
}): Promise<CreatePendingEmailGrantResult> {
  if (!isPlausibleEmail(input.email)) {
    throw new AdminInvalidEmailError(input.email);
  }
  const db = input.db ?? cloudDb();
  const email = canonicalizeEmailForMatching(input.email);
  // One open grant per email: a new grant supersedes any earlier open one, so
  // sign-in never has more than one row to apply and the newest plan wins.
  // This holds across slots too (the open-email unique index allows one row),
  // so a pending cmux NEXT grant replaces a pending classic one for the same
  // email and the reverse; applying the row writes only its own slot.
  // Supersede and insert commit together, and the partial unique index on
  // open emails makes a concurrent second grant fail instead of leaving two
  // open rows. A superseded row that a sign-in had claimed may already have
  // written metadata; that grant is cleared after the commit through the
  // conditional clear, and if the clear fails the row keeps its claim marker
  // so the user's next sign-in retries it (retryRevokedGrantCleanup).
  const { row, superseded } = await db.transaction(async (tx) => {
    const supersededRows = await tx
      .update(adminPlanGrants)
      .set({ revokedAt: new Date() })
      .where(
        and(
          eq(adminPlanGrants.email, email),
          isNull(adminPlanGrants.appliedAt),
          isNull(adminPlanGrants.revokedAt),
        ),
      )
      .returning({
        id: adminPlanGrants.id,
        plan: adminPlanGrants.plan,
        appliedUserId: adminPlanGrants.appliedUserId,
        grantedByUserId: adminPlanGrants.grantedByUserId,
        grantedByEmail: adminPlanGrants.grantedByEmail,
      });
    const [inserted] = await tx
      .insert(adminPlanGrants)
      .values({
        email,
        plan: input.plan,
        grantedByUserId: input.admin.id,
        grantedByEmail: input.admin.primaryEmail ?? null,
      })
      .returning({
        id: adminPlanGrants.id,
        email: adminPlanGrants.email,
        plan: adminPlanGrants.plan,
        grantedByEmail: adminPlanGrants.grantedByEmail,
        createdAt: adminPlanGrants.createdAt,
      });
    return { row: inserted, superseded: supersededRows };
  });
  const unclearedUserIds: string[] = [];
  for (const old of superseded) {
    if (!old.appliedUserId) continue;
    try {
      await (input.grant ?? setManualPlanGrant)({
        targetUserId: old.appliedUserId,
        plan: null,
        admin: input.admin,
        onlyIfCurrent: { plan: old.plan, byUserId: old.grantedByUserId, pendingGrantId: old.id },
        supersedePending: false,
      });
      await db
        .update(adminPlanGrants)
        .set({ appliedUserId: null, claimedAt: null })
        .where(eq(adminPlanGrants.id, old.id));
    } catch (error) {
      if (error instanceof AdminUserNotFoundError) continue;
      console.error("admin.pending_grants.supersede_clear_failed", {
        grantId: old.id,
        failure: error instanceof Error ? error.name : "unknown",
      });
      unclearedUserIds.push(old.appliedUserId);
    }
  }
  if (!row) throw new Error("admin_plan_grants insert returned no row");
  return {
    id: row.id,
    email: row.email,
    plan: row.plan,
    grantedByEmail: row.grantedByEmail ?? null,
    createdAt: row.createdAt.toISOString(),
    unclearedUserIds,
  };
}

/**
 * True when Postgres reports the admin_plan_grants relation missing (42P01),
 * i.e. the deployment has not run the migration yet. drizzle wraps pg errors,
 * so the code is read from `cause` as well as the error itself.
 */
export function isMissingGrantsTableError(error: unknown): boolean {
  const seen = new Set<unknown>();
  let current: unknown = error;
  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current);
    const record = current as { code?: unknown; message?: unknown; cause?: unknown };
    if (record.code === "42P01") return true;
    if (typeof record.message === "string" && /relation "?admin_plan_grants"? does not exist/.test(record.message)) {
      return true;
    }
    current = record.cause;
  }
  return false;
}

export class AdminInvalidEmailError extends Error {
  constructor(readonly email: string) {
    super("Not a plausible email address");
    this.name = "AdminInvalidEmailError";
  }
}

/**
 * Revokes open pending grants of `slot` for an email that are unclaimed or
 * claimed by the given user. Rows claimed by another user are left for that
 * sign-in, and a pending grant of the other slot is left alone: it writes a
 * different key, so it cannot undo this decision. Tolerates a missing
 * database or table.
 */
async function supersedeOpenGrantsForEmail(
  rawEmail: string,
  userId: string,
  slot: AdminGrantSlot,
  grantsDb?: AdminGrantsDb,
): Promise<void> {
  const email = canonicalizeEmailForMatching(rawEmail);
  try {
    const db = grantsDb ?? cloudDb();
    await db
      .update(adminPlanGrants)
      .set({ revokedAt: new Date() })
      .where(
        and(
          eq(adminPlanGrants.email, email),
          isNull(adminPlanGrants.appliedAt),
          isNull(adminPlanGrants.revokedAt),
          inArray(adminPlanGrants.plan, slot === "next" ? NEXT_PLAN_IDS : CLASSIC_GRANT_PLAN_IDS),
          or(isNull(adminPlanGrants.appliedUserId), eq(adminPlanGrants.appliedUserId, userId)),
        ),
      );
  } catch (error) {
    if (isMissingGrantsTableError(error) || isMissingDatabaseConfigError(error)) return;
    throw error;
  }
}

/** A claim older than this is treated as abandoned and may be re-claimed. */
export const ADMIN_GRANT_CLAIM_TTL_MS = 10 * 60 * 1000;

/**
 * Revokes an open grant. If a sign-in had claimed the row but never finalized
 * it (process or database failure after the metadata write), the claimer's
 * manual grant is removed as well, but only when that grant is the one this
 * row produced (same plan, same granting admin in the audit record), so an
 * unrelated manual grant on the account is left alone.
 *
 * The row is revoked first so an in-flight apply cannot finalize it. If the
 * metadata clear then fails, the revoke is undone (best effort) and the
 * error propagates, so the row stays open and the admin can retry.
 */
export async function revokePendingEmailGrant(input: {
  readonly grantId: string;
  readonly db?: AdminGrantsDb;
  readonly admin?: { readonly id: string; readonly primaryEmail?: string | null };
  readonly grant?: (input: SetManualPlanGrantInput) => Promise<unknown>;
}): Promise<{ readonly revoked: boolean; readonly clearedUserId: string | null }> {
  const db = input.db ?? cloudDb();
  const rows = await db
    .update(adminPlanGrants)
    .set({ revokedAt: new Date() })
    .where(
      and(
        eq(adminPlanGrants.id, input.grantId),
        isNull(adminPlanGrants.appliedAt),
        isNull(adminPlanGrants.revokedAt),
      ),
    )
    .returning({
      id: adminPlanGrants.id,
      plan: adminPlanGrants.plan,
      appliedUserId: adminPlanGrants.appliedUserId,
      grantedByUserId: adminPlanGrants.grantedByUserId,
      grantedByEmail: adminPlanGrants.grantedByEmail,
    });
  const row = rows[0];
  if (!row) return { revoked: false, clearedUserId: null };
  if (!row.appliedUserId) return { revoked: true, clearedUserId: null };
  try {
    await (input.grant ?? setManualPlanGrant)({
      targetUserId: row.appliedUserId,
      plan: null,
      admin: input.admin ?? { id: row.grantedByUserId, primaryEmail: row.grantedByEmail },
      onlyIfCurrent: { plan: row.plan, byUserId: row.grantedByUserId, pendingGrantId: row.id },
      supersedePending: false,
    });
  } catch (error) {
    if (!(error instanceof AdminUserNotFoundError)) {
      await db
        .update(adminPlanGrants)
        .set({ revokedAt: null })
        .where(and(eq(adminPlanGrants.id, row.id), isNull(adminPlanGrants.appliedAt)))
        .catch(() => undefined);
      throw error;
    }
  }
  await db
    .update(adminPlanGrants)
    .set({ appliedUserId: null, claimedAt: null })
    .where(eq(adminPlanGrants.id, row.id));
  return { revoked: true, clearedUserId: row.appliedUserId };
}

/**
 * Applies every open grant addressed to the user's verified primary email.
 * Called from the after-sign-in callback, which only runs it once Stack
 * reports the mailbox verified. The newest grant wins when several are open.
 *
 * Work is bounded: createPendingEmailGrant keeps at most one open row per
 * email, and claim, finalize, and release are each a single statement.
 *
 * Protocol, so that a revoke always wins until the grant is durably applied:
 * 1. claim: set applied_user_id and claimed_at on open rows that are
 *    unclaimed, claimed by this same user, or whose claim is older than
 *    ADMIN_GRANT_CLAIM_TTL_MS (applied_at stays NULL, so the rows still count
 *    as pending and can still be revoked);
 * 2. write the metadata grant for the newest claimed row;
 * 3. finalize: set applied_at on claimed rows that are still unrevoked;
 * 4. if the applied row was revoked during 2, remove the grant again.
 * A failed write releases the claim; a crash mid-way leaves a claim that the
 * same user's next sign-in, or anyone after the TTL, picks up again. The
 * metadata write is idempotent, so a retry after a crash is safe.
 */
/**
 * Writes the newest claimed pending grant into its own slot (a cmux NEXT plan
 * into the NEXT slot), leaving the other slot's grant alone. A failure
 * releases the claims and is rethrown.
 */
async function applyNewestPendingGrant(
  grant: (input: SetManualPlanGrantInput) => Promise<unknown>,
  userId: string,
  plan: AdminGrantablePlanId,
  newest: { readonly id: string; readonly grantedByUserId: string; readonly grantedByEmail: string | null; readonly createdAt: Date },
  releaseClaims: () => Promise<void>,
): Promise<void> {
  try {
    await grant({
      targetUserId: userId,
      plan,
      admin: { id: newest.grantedByUserId, primaryEmail: newest.grantedByEmail },
      // A direct admin decision made after this grant was created wins.
      unlessAuditNewerThan: newest.createdAt,
      supersedePending: false,
      pendingGrantId: newest.id,
    });
  } catch (error) {
    await releaseClaims();
    throw error;
  }
}

export async function applyPendingEmailGrants(
  user: { readonly id: string; readonly primaryEmail?: string | null },
  options: {
    readonly db?: AdminGrantsDb;
    readonly grant?: (input: SetManualPlanGrantInput) => Promise<unknown>;
    readonly now?: () => Date;
  } = {},
): Promise<number> {
  if (!user.primaryEmail) return 0;
  const db = options.db ?? cloudDb();
  const grant = options.grant ?? setManualPlanGrant;
  const now = options.now ?? (() => new Date());
  const email = canonicalizeEmailForMatching(user.primaryEmail);
  try {
    await retryRevokedGrantCleanup(db, email, user.id, grant);
  } catch (error) {
    if (isMissingGrantsTableError(error) || isMissingDatabaseConfigError(error)) return 0;
    throw error;
  }
  const claimedAt = now();
  const staleBefore = new Date(claimedAt.getTime() - ADMIN_GRANT_CLAIM_TTL_MS);
  let claimed: Array<{
    id: string;
    plan: string;
    grantedByUserId: string;
    grantedByEmail: string | null;
    createdAt: Date;
  }>;
  try {
    claimed = await db
      .update(adminPlanGrants)
      .set({ appliedUserId: user.id, claimedAt })
      .where(
        and(
          eq(adminPlanGrants.email, email),
          isNull(adminPlanGrants.appliedAt),
          isNull(adminPlanGrants.revokedAt),
          or(
            isNull(adminPlanGrants.appliedUserId),
            eq(adminPlanGrants.appliedUserId, user.id),
            isNull(adminPlanGrants.claimedAt),
            lt(adminPlanGrants.claimedAt, staleBefore),
          ),
        ),
      )
      .returning({
        id: adminPlanGrants.id,
        plan: adminPlanGrants.plan,
        grantedByUserId: adminPlanGrants.grantedByUserId,
        grantedByEmail: adminPlanGrants.grantedByEmail,
        createdAt: adminPlanGrants.createdAt,
      });
  } catch (error) {
    // No table yet (migration pending) or no database: nothing to apply.
    if (isMissingGrantsTableError(error) || isMissingDatabaseConfigError(error)) return 0;
    throw error;
  }
  if (claimed.length === 0) return 0;
  const claimedIds = claimed.map((row) => row.id);
  const releaseClaims = async () => {
    await db
      .update(adminPlanGrants)
      .set({ appliedUserId: null, claimedAt: null })
      .where(and(inArray(adminPlanGrants.id, claimedIds), isNull(adminPlanGrants.appliedAt)))
      .catch(() => undefined);
  };

  const newest = [...claimed].sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())[0]!;
  const plan = isAdminGrantablePlanId(newest.plan) ? newest.plan : null;
  if (plan !== null) await applyNewestPendingGrant(grant, user.id, plan, newest, releaseClaims);

  // Finalize only rows this sign-in still owns: a claim stolen after the TTL
  // belongs to that later sign-in, which finalizes (or compensates) itself.
  const done = await db
    .update(adminPlanGrants)
    .set({ appliedAt: now() })
    .where(
      and(
        inArray(adminPlanGrants.id, claimedIds),
        eq(adminPlanGrants.appliedUserId, user.id),
        isNull(adminPlanGrants.appliedAt),
        isNull(adminPlanGrants.revokedAt),
      ),
    )
    .returning({ id: adminPlanGrants.id });
  const finalized = new Set(done.map((row) => row.id));
  if (plan !== null && !finalized.has(newest.id)) {
    // Not ours to keep: either revoked while the write was in flight (the
    // revoke wins), or the claim was taken over after the TTL by a later
    // sign-in for the same email (that sign-in owns the grant now). Either
    // way remove exactly the grant this row produced. This does not depend
    // on the claim marker, which a concurrent revoke may already have
    // cleared before our write landed.
    const revoked = await wasRevoked(db, newest.id);
    try {
      await grant({
        targetUserId: user.id,
        plan: null,
        admin: { id: newest.grantedByUserId, primaryEmail: newest.grantedByEmail },
        onlyIfCurrent: { plan: newest.plan, byUserId: newest.grantedByUserId, pendingGrantId: newest.id },
        supersedePending: false,
      });
    } catch (error) {
      // For a revoked row, put the marker back so retryRevokedGrantCleanup
      // retries at this user's next sign-in. A taken-over row belongs to the
      // other sign-in; do not steal its marker back.
      if (revoked) {
        await db
          .update(adminPlanGrants)
          .set({ appliedUserId: user.id, claimedAt: now() })
          .where(and(eq(adminPlanGrants.id, newest.id), isNull(adminPlanGrants.appliedAt)))
          .catch(() => undefined);
      }
      throw error;
    }
    if (revoked) {
      await db
        .update(adminPlanGrants)
        .set({ appliedUserId: null, claimedAt: null })
        .where(eq(adminPlanGrants.id, newest.id));
    }
  }
  return finalized.size;
}

async function wasRevoked(db: AdminGrantsDb, grantId: string): Promise<boolean> {
  const rows = await db
    .select({ id: adminPlanGrants.id })
    .from(adminPlanGrants)
    .where(
      and(
        eq(adminPlanGrants.id, grantId),
        isNull(adminPlanGrants.appliedAt),
        isNotNull(adminPlanGrants.revokedAt),
      ),
    )
    .orderBy(desc(adminPlanGrants.createdAt))
    .limit(1);
  return rows.length > 0;
}

/**
 * Durable cleanup for the revoke/apply race: a revoked row that still carries
 * applied_user_id (and no applied_at) means a grant was written for that user
 * and the compensating clear did not complete. Retry it here, on the user's
 * own sign-in, and release the marker once the clear succeeds.
 */
async function retryRevokedGrantCleanup(
  db: AdminGrantsDb,
  email: string,
  userId: string,
  grant: (input: SetManualPlanGrantInput) => Promise<unknown>,
): Promise<void> {
  const dangling = await db
    .select({
      id: adminPlanGrants.id,
      plan: adminPlanGrants.plan,
      grantedByUserId: adminPlanGrants.grantedByUserId,
      grantedByEmail: adminPlanGrants.grantedByEmail,
    })
    .from(adminPlanGrants)
    .where(
      and(
        eq(adminPlanGrants.email, email),
        isNotNull(adminPlanGrants.revokedAt),
        isNull(adminPlanGrants.appliedAt),
        eq(adminPlanGrants.appliedUserId, userId),
      ),
    )
    .orderBy(desc(adminPlanGrants.createdAt))
    .limit(ADMIN_USER_SEARCH_LIMIT);
  for (const row of dangling) {
    await grant({
      targetUserId: userId,
      plan: null,
      admin: { id: row.grantedByUserId, primaryEmail: row.grantedByEmail },
      onlyIfCurrent: { plan: row.plan, byUserId: row.grantedByUserId, pendingGrantId: row.id },
      supersedePending: false,
    });
    await db
      .update(adminPlanGrants)
      .set({ appliedUserId: null, claimedAt: null })
      .where(eq(adminPlanGrants.id, row.id));
  }
}

function isMissingDatabaseConfigError(error: unknown): boolean {
  return error instanceof Error && /DATABASE_URL is required/.test(error.message);
}
