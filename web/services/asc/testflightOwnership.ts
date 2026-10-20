import type { AccountDeletionUserMutationLease } from
  "../account/deletionLock";

export const FOUNDER_TESTFLIGHT_GROUP_ID =
  "3ee84bfa-10ad-4f23-a45c-f9a3b037373e";

const PRO_OWNED_LEGACY_TESTFLIGHT_GROUP_IDS_METADATA_KEY =
  "cmuxProTestflightOwnedLegacyGroupIDs";
const PRO_OWNED_LEGACY_TESTFLIGHT_EMAILS_METADATA_KEY =
  "cmuxProTestflightOwnedLegacyEmails";
const PRO_TESTFLIGHT_ENROLLMENT_EMAILS_METADATA_KEY =
  "cmuxProTestflightEnrollmentEmails";
const PRO_TESTFLIGHT_GRANTS_METADATA_KEY = "cmuxProTestflightGrants";

type TestflightOwnershipMetadata =
  | null
  | boolean
  | number
  | string
  | readonly TestflightOwnershipMetadata[]
  | { readonly [key: string]: TestflightOwnershipMetadata };

export type ProTestflightOwnershipUser = {
  readonly clientReadOnlyMetadata?: unknown;
  update(options: {
    clientReadOnlyMetadata: TestflightOwnershipMetadata;
  }): Promise<unknown>;
};

export type ProTestflightGrant = {
  readonly email: string;
  readonly source: "user";
};

export function proOwnedLegacyTestflightGroupIDs(
  metadata: unknown,
): readonly string[] {
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
    return [];
  }
  const value = (metadata as Record<string, unknown>)[
    PRO_OWNED_LEGACY_TESTFLIGHT_GROUP_IDS_METADATA_KEY
  ];
  if (!Array.isArray(value)) return [];
  return value.filter(
    (groupID): groupID is string => groupID === FOUNDER_TESTFLIGHT_GROUP_ID,
  );
}

export function proOwnedLegacyTestflightEmails(
  metadata: unknown,
): readonly string[] {
  return metadataEmails(
    metadata,
    PRO_OWNED_LEGACY_TESTFLIGHT_EMAILS_METADATA_KEY,
  );
}

export function proTestflightEnrollmentEmails(
  metadata: unknown,
): readonly string[] {
  return metadataEmails(metadata, PRO_TESTFLIGHT_ENROLLMENT_EMAILS_METADATA_KEY);
}

export function proTestflightGrants(metadata: unknown): readonly ProTestflightGrant[] {
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
    return [];
  }
  const value = (metadata as Record<string, unknown>)[
    PRO_TESTFLIGHT_GRANTS_METADATA_KEY
  ];
  if (!Array.isArray(value)) return [];

  const grants = new Map<string, ProTestflightGrant>();
  for (const candidate of value) {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
      continue;
    }
    const record = candidate as Record<string, unknown>;
    const email = normalizeEmail(record.email);
    if (!email || record.source !== "user") continue;
    grants.set(email, { email, source: "user" });
  }
  return [...grants.values()];
}

export type ProTestflightRemovalTarget = {
  readonly email: string;
  readonly ownedLegacyGroupIDs: readonly string[];
};

export function proTestflightRemovalTargets(
  currentEmail: string | null | undefined,
  metadata: unknown,
): readonly ProTestflightRemovalTarget[] {
  const current = normalizeEmail(currentEmail);
  const enrollmentEmails = proTestflightEnrollmentEmails(metadata);
  const grantEmails = proTestflightGrants(metadata).map((grant) => grant.email);
  const legacyEmails = proOwnedLegacyTestflightEmails(metadata);
  const legacyEmailSet = new Set(legacyEmails);
  const legacyGroupIDs = proOwnedLegacyTestflightGroupIDs(metadata);
  const emails = [
    ...new Set([
      ...(current ? [current] : []),
      ...grantEmails,
      ...enrollmentEmails,
      ...legacyEmails,
    ]),
  ];

  return emails.map((email) => ({
    email,
    ownedLegacyGroupIDs: legacyEmailSet.has(email) ? legacyGroupIDs : [],
  }));
}

export async function recordProTestflightEnrollmentEmail(
  user: ProTestflightOwnershipUser,
  enrollmentEmail: string,
  lease: AccountDeletionUserMutationLease,
): Promise<boolean> {
  const normalizedEmail = requiredEmail(
    enrollmentEmail,
    "Pro TestFlight enrollment requires a valid email",
  );
  const metadata = mutableMetadata(user.clientReadOnlyMetadata);
  const enrollmentEmails = proTestflightEnrollmentEmails(metadata);
  const nextEmails = [
    ...new Set([...enrollmentEmails, normalizedEmail]),
  ];
  const grants = proTestflightGrants(metadata);
  const nextGrantEmails = [
    ...new Set([...grants.map((grant) => grant.email), ...nextEmails]),
  ];
  const nextGrants = nextGrantEmails.map((email) => ({
    email,
    source: "user" as const,
  }));
  const emailsChanged = nextEmails.length !== enrollmentEmails.length;
  const grantsChanged = nextGrants.length !== grants.length ||
    nextGrants.some((grant, index) =>
      grant.email !== grants[index]?.email || grant.source !== grants[index]?.source
    );
  if (!emailsChanged && !grantsChanged) return false;

  metadata[PRO_TESTFLIGHT_ENROLLMENT_EMAILS_METADATA_KEY] = nextEmails;
  metadata[PRO_TESTFLIGHT_GRANTS_METADATA_KEY] = nextGrants;
  await lease.refresh();
  await user.update({
    clientReadOnlyMetadata: metadata as TestflightOwnershipMetadata,
  });
  return true;
}

export function metadataAfterProTestflightRemoval(
  metadata: unknown,
  removedEmail: string,
): TestflightOwnershipMetadata {
  const email = requiredEmail(
    removedEmail,
    "Pro TestFlight removal requires a valid email",
  );
  const next = mutableMetadata(metadata);
  setOrDeleteMetadataArray(
    next,
    PRO_TESTFLIGHT_ENROLLMENT_EMAILS_METADATA_KEY,
    proTestflightEnrollmentEmails(next).filter((candidate) => candidate !== email),
  );
  setOrDeleteMetadataArray(
    next,
    PRO_TESTFLIGHT_GRANTS_METADATA_KEY,
    proTestflightGrants(next).filter((grant) => grant.email !== email),
  );

  const legacyEmails = proOwnedLegacyTestflightEmails(next).filter(
    (candidate) => candidate !== email,
  );
  setOrDeleteMetadataArray(
    next,
    PRO_OWNED_LEGACY_TESTFLIGHT_EMAILS_METADATA_KEY,
    legacyEmails,
  );
  if (legacyEmails.length === 0) {
    delete next[PRO_OWNED_LEGACY_TESTFLIGHT_GROUP_IDS_METADATA_KEY];
  }
  return next as TestflightOwnershipMetadata;
}

/**
 * Records an operator-audited legacy Pro enrollment. Selection happens in the
 * one-time backfill script; this writer never infers ownership from ASC group
 * overlap, which would conflate genuine Founders who also subscribe to Pro.
 */
export async function recordProOwnedLegacyTestflightGroup(
  user: ProTestflightOwnershipUser,
  legacyEmail: string,
  lease: AccountDeletionUserMutationLease,
): Promise<boolean> {
  const normalizedLegacyEmail = requiredEmail(
    legacyEmail,
    "Legacy TestFlight ownership requires a valid email",
  );
  const metadata = mutableMetadata(user.clientReadOnlyMetadata);
  const ownedGroupIDs = proOwnedLegacyTestflightGroupIDs(metadata);
  const ownedEmails = proOwnedLegacyTestflightEmails(metadata);
  const hasGroup = ownedGroupIDs.includes(FOUNDER_TESTFLIGHT_GROUP_ID);
  const hasEmail = ownedEmails.includes(normalizedLegacyEmail);
  if (hasGroup && hasEmail) return false;

  metadata[PRO_OWNED_LEGACY_TESTFLIGHT_GROUP_IDS_METADATA_KEY] = [
    FOUNDER_TESTFLIGHT_GROUP_ID,
  ];
  metadata[PRO_OWNED_LEGACY_TESTFLIGHT_EMAILS_METADATA_KEY] = [
    ...ownedEmails,
    ...(hasEmail ? [] : [normalizedLegacyEmail]),
  ];
  await lease.refresh();
  await user.update({
    clientReadOnlyMetadata: metadata as TestflightOwnershipMetadata,
  });
  return true;
}

function metadataEmails(metadata: unknown, key: string): readonly string[] {
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
    return [];
  }
  const value = (metadata as Record<string, unknown>)[key];
  if (!Array.isArray(value)) return [];
  return [
    ...new Set(value.flatMap((email) => {
      const normalized = normalizeEmail(email);
      return normalized ? [normalized] : [];
    })),
  ];
}

function mutableMetadata(metadata: unknown): Record<string, unknown> {
  return metadata && typeof metadata === "object" && !Array.isArray(metadata)
    ? { ...(metadata as Record<string, unknown>) }
    : {};
}

function setOrDeleteMetadataArray(
  metadata: Record<string, unknown>,
  key: string,
  values: readonly TestflightOwnershipMetadata[],
): void {
  if (values.length > 0) metadata[key] = values;
  else delete metadata[key];
}

function requiredEmail(value: unknown, message: string): string {
  const email = normalizeEmail(value);
  if (!email) throw new Error(message);
  return email;
}

function normalizeEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  if (!email || !email.includes("@") || /\s/.test(email)) return null;
  return email;
}
