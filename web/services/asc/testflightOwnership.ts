export const FOUNDER_TESTFLIGHT_GROUP_ID =
  "3ee84bfa-10ad-4f23-a45c-f9a3b037373e";

const PRO_OWNED_LEGACY_TESTFLIGHT_GROUP_IDS_METADATA_KEY =
  "cmuxProTestflightOwnedLegacyGroupIDs";

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

/**
 * Records an operator-audited legacy Pro enrollment. Selection happens in the
 * one-time backfill script; this writer never infers ownership from ASC group
 * overlap, which would conflate genuine Founders who also subscribe to Pro.
 */
export async function recordProOwnedLegacyTestflightGroup(
  user: ProTestflightOwnershipUser,
): Promise<boolean> {
  const metadata = user.clientReadOnlyMetadata
    && typeof user.clientReadOnlyMetadata === "object"
    && !Array.isArray(user.clientReadOnlyMetadata)
    ? { ...(user.clientReadOnlyMetadata as Record<string, unknown>) }
    : {};
  const ownedGroupIDs = proOwnedLegacyTestflightGroupIDs(metadata);
  if (ownedGroupIDs.includes(FOUNDER_TESTFLIGHT_GROUP_ID)) return false;

  metadata[PRO_OWNED_LEGACY_TESTFLIGHT_GROUP_IDS_METADATA_KEY] = [
    FOUNDER_TESTFLIGHT_GROUP_ID,
  ];
  await user.update({
    clientReadOnlyMetadata: metadata as TestflightOwnershipMetadata,
  });
  return true;
}
