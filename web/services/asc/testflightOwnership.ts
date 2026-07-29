export const FOUNDER_TESTFLIGHT_GROUP_ID =
  "3ee84bfa-10ad-4f23-a45c-f9a3b037373e";

const PRO_OWNED_LEGACY_TESTFLIGHT_GROUP_IDS_METADATA_KEY =
  "cmuxProTestflightOwnedLegacyGroupIDs";
const PRO_OWNED_LEGACY_TESTFLIGHT_EMAILS_METADATA_KEY =
  "cmuxProTestflightOwnedLegacyEmails";

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
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
    return [];
  }
  const value = (metadata as Record<string, unknown>)[
    PRO_OWNED_LEGACY_TESTFLIGHT_EMAILS_METADATA_KEY
  ];
  if (!Array.isArray(value)) return [];
  return [
    ...new Set(value.flatMap((email) => {
      const normalized = normalizeEmail(email);
      return normalized ? [normalized] : [];
    })),
  ];
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
  const legacyEmails = proOwnedLegacyTestflightEmails(metadata);
  const legacyGroupIDs = proOwnedLegacyTestflightGroupIDs(metadata);
  const emails = [...new Set([...(current ? [current] : []), ...legacyEmails])];

  return emails.map((email) => ({
    email,
    ownedLegacyGroupIDs: legacyEmails.includes(email) ? legacyGroupIDs : [],
  }));
}

/**
 * Records an operator-audited legacy Pro enrollment. Selection happens in the
 * one-time backfill script; this writer never infers ownership from ASC group
 * overlap, which would conflate genuine Founders who also subscribe to Pro.
 */
export async function recordProOwnedLegacyTestflightGroup(
  user: ProTestflightOwnershipUser,
  legacyEmail: string,
): Promise<boolean> {
  const normalizedLegacyEmail = normalizeEmail(legacyEmail);
  if (!normalizedLegacyEmail) {
    throw new Error("Legacy TestFlight ownership requires a valid email");
  }
  const metadata = user.clientReadOnlyMetadata
    && typeof user.clientReadOnlyMetadata === "object"
    && !Array.isArray(user.clientReadOnlyMetadata)
    ? { ...(user.clientReadOnlyMetadata as Record<string, unknown>) }
    : {};
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
  await user.update({
    clientReadOnlyMetadata: metadata as TestflightOwnershipMetadata,
  });
  return true;
}

function normalizeEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  if (!email || !email.includes("@") || /\s/.test(email)) return null;
  return email;
}
