// Invited admin roster.
//
// A member row is an email that may open the admin surface once its owner
// signs in with that email verified (services/admin/routeAuth). Rows are
// never deleted: revoking sets revoked_at, and a later invite clears it so the
// row keeps its id and history.

import { and, desc, eq, isNotNull } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { adminMembers } from "../../db/schema";
import { isPlausibleEmail } from "./proGrants";

export type AdminMemberRecord = {
  readonly id: string;
  readonly email: string;
  readonly invitedByUserId: string;
  readonly invitedByEmail: string | null;
  readonly invitedAt: Date;
  readonly acceptedAt: Date | null;
  readonly revokedAt: Date | null;
  readonly lastSeenAt: Date | null;
};

export type AdminMemberRow = {
  readonly id: string;
  readonly email: string;
  readonly invitedByEmail: string | null;
  readonly invitedAt: string;
  readonly acceptedAt: string | null;
  readonly revokedAt: string | null;
  readonly lastSeenAt: string | null;
};

export type AdminMemberPatch = Partial<
  Pick<
    AdminMemberRecord,
    "invitedByUserId" | "invitedByEmail" | "invitedAt" | "acceptedAt" | "revokedAt" | "lastSeenAt"
  >
>;

/** Storage boundary for member rows; the drizzle implementation is below. */
export type AdminMembersStore = {
  list(): Promise<AdminMemberRecord[]>;
  findByEmail(email: string): Promise<AdminMemberRecord | null>;
  findById(id: string): Promise<AdminMemberRecord | null>;
  insert(values: {
    readonly email: string;
    readonly invitedByUserId: string;
    readonly invitedByEmail: string | null;
  }): Promise<AdminMemberRecord>;
  update(id: string, patch: AdminMemberPatch): Promise<AdminMemberRecord | null>;
  /** Applies the patch only while the row is still revoked; null when it is active (or gone). */
  reopen(id: string, patch: AdminMemberPatch): Promise<AdminMemberRecord | null>;
};

export class AdminMemberInvalidEmailError extends Error {
  constructor(readonly email: string) {
    super("Not a plausible email address");
    this.name = "AdminMemberInvalidEmailError";
  }
}

export class AdminMemberAlreadyActiveError extends Error {
  constructor(readonly member: AdminMemberRecord) {
    super("Email is already an active admin member");
    this.name = "AdminMemberAlreadyActiveError";
  }
}

export class AdminMemberNotFoundError extends Error {
  constructor(readonly memberId: string) {
    super("Admin member not found");
    this.name = "AdminMemberNotFoundError";
  }
}

export class AdminMemberSelfRevokeError extends Error {
  constructor(readonly memberId: string) {
    super("An admin cannot revoke their own membership");
    this.name = "AdminMemberSelfRevokeError";
  }
}

export function normalizeAdminMemberEmail(email: string): string {
  return email.trim().toLowerCase();
}

export function isAdminMemberActive(member: AdminMemberRecord | null | undefined): member is AdminMemberRecord {
  return Boolean(member && member.revokedAt === null);
}

export function adminMemberRow(member: AdminMemberRecord): AdminMemberRow {
  return {
    id: member.id,
    email: member.email,
    invitedByEmail: member.invitedByEmail,
    invitedAt: member.invitedAt.toISOString(),
    acceptedAt: member.acceptedAt?.toISOString() ?? null,
    revokedAt: member.revokedAt?.toISOString() ?? null,
    lastSeenAt: member.lastSeenAt?.toISOString() ?? null,
  };
}

export async function listAdminMembers(
  options: { readonly store?: AdminMembersStore } = {},
): Promise<AdminMemberRow[]> {
  const store = options.store ?? defaultAdminMembersStore();
  return (await store.list()).map(adminMemberRow);
}

/**
 * Creates the member, or reopens a revoked row for the same email. An active
 * row is a conflict. The returned `created` flag says whether a new row was
 * inserted.
 */
export async function inviteAdminMember(input: {
  readonly email: string;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly store?: AdminMembersStore;
  readonly now?: () => Date;
}): Promise<{ member: AdminMemberRecord; created: boolean }> {
  if (!isPlausibleEmail(input.email)) throw new AdminMemberInvalidEmailError(input.email);
  const store = input.store ?? defaultAdminMembersStore();
  const email = normalizeAdminMemberEmail(input.email);
  const inviter = { invitedByUserId: input.admin.id, invitedByEmail: input.admin.primaryEmail ?? null };
  const existing = await store.findByEmail(email);
  if (!existing) {
    return { member: await insertMember(store, email, inviter), created: true };
  }
  if (existing.revokedAt === null) throw new AdminMemberAlreadyActiveError(existing);
  // The reopen is conditional on revoked_at so two concurrent re-invites
  // cannot both succeed: the loser sees no row and reports the conflict.
  const reopened = await store.reopen(existing.id, {
    ...inviter,
    invitedAt: (input.now ?? (() => new Date()))(),
    acceptedAt: null,
    revokedAt: null,
    lastSeenAt: null,
  });
  if (reopened) return { member: reopened, created: false };
  const raced = await store.findById(existing.id);
  if (raced && raced.revokedAt === null) throw new AdminMemberAlreadyActiveError(raced);
  throw new AdminMemberNotFoundError(existing.id);
}

async function insertMember(
  store: AdminMembersStore,
  email: string,
  inviter: { readonly invitedByUserId: string; readonly invitedByEmail: string | null },
): Promise<AdminMemberRecord> {
  try {
    return await store.insert({ email, ...inviter });
  } catch (error) {
    // Two admins inviting the same email at once: the unique index rejects the
    // second insert, which is the "already a member" case for that caller.
    if (isUniqueViolation(error)) {
      const raced = await store.findByEmail(email);
      if (raced) throw new AdminMemberAlreadyActiveError(raced);
    }
    throw error;
  }
}

export async function revokeAdminMember(input: {
  readonly memberId: string;
  readonly admin: { readonly id: string; readonly primaryEmail?: string | null };
  readonly store?: AdminMembersStore;
  readonly now?: () => Date;
}): Promise<AdminMemberRecord> {
  const store = input.store ?? defaultAdminMembersStore();
  const member = await store.findById(input.memberId);
  if (!member) throw new AdminMemberNotFoundError(input.memberId);
  const adminEmail = input.admin.primaryEmail ? normalizeAdminMemberEmail(input.admin.primaryEmail) : null;
  if (adminEmail !== null && adminEmail === member.email) {
    throw new AdminMemberSelfRevokeError(member.id);
  }
  if (!isAdminMemberActive(member)) return member;
  const revoked = await store.update(member.id, { revokedAt: (input.now ?? (() => new Date()))() });
  return revoked ?? member;
}

/** The unrevoked member row for a verified email, or null. */
export async function findActiveAdminMember(
  email: string,
  options: { readonly store?: AdminMembersStore } = {},
): Promise<AdminMemberRecord | null> {
  const store = options.store ?? defaultAdminMembersStore();
  const member = await store.findByEmail(normalizeAdminMemberEmail(email));
  return isAdminMemberActive(member) ? member : null;
}

/** Stamps accepted_at on the first visit and last_seen_at on every visit. */
export async function touchAdminMember(
  email: string,
  options: { readonly store?: AdminMembersStore; readonly now?: () => Date } = {},
): Promise<AdminMemberRecord | null> {
  const store = options.store ?? defaultAdminMembersStore();
  const member = await findActiveAdminMember(email, { store });
  if (!member) return null;
  const now = (options.now ?? (() => new Date()))();
  return await store.update(member.id, {
    lastSeenAt: now,
    ...(member.acceptedAt === null ? { acceptedAt: now } : {}),
  });
}

function isUniqueViolation(error: unknown): boolean {
  const seen = new Set<unknown>();
  let current: unknown = error;
  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current);
    if ((current as { code?: unknown }).code === "23505") return true;
    current = (current as { cause?: unknown }).cause;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Drizzle-backed store

export type AdminMembersDb = Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "update">;

export function drizzleAdminMembersStore(db: AdminMembersDb): AdminMembersStore {
  return {
    async list() {
      return await db.select().from(adminMembers).orderBy(desc(adminMembers.invitedAt));
    },
    async findByEmail(email) {
      const rows = await db.select().from(adminMembers).where(eq(adminMembers.email, email)).limit(1);
      return rows[0] ?? null;
    },
    async findById(id) {
      const rows = await db.select().from(adminMembers).where(eq(adminMembers.id, id)).limit(1);
      return rows[0] ?? null;
    },
    async insert(values) {
      const rows = await db.insert(adminMembers).values(values).returning();
      return rows[0]!;
    },
    async update(id, patch) {
      const rows = await db.update(adminMembers).set(patch).where(eq(adminMembers.id, id)).returning();
      return rows[0] ?? null;
    },
    async reopen(id, patch) {
      const rows = await db
        .update(adminMembers)
        .set(patch)
        .where(and(eq(adminMembers.id, id), isNotNull(adminMembers.revokedAt)))
        .returning();
      return rows[0] ?? null;
    },
  };
}

function defaultAdminMembersStore(): AdminMembersStore {
  return drizzleAdminMembersStore(cloudDb());
}
