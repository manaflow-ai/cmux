/**
 * Per-team Cloud VM entitlement override: a custom deal an admin sets on one
 * team (for example 8 people, $800/month, 40 machines, a 320 vCPU / 640 GB
 * pool, and machines up to 32 vCPU / 64 GB). It lives in the team's Stack
 * read-only metadata as `cmuxEntitlementOverride`, next to `cmuxVmPlan` and
 * `cmuxSeats`, so it reaches entitlements through the same team resolution
 * and identity snapshot. Only the server can write read-only metadata; the
 * admin API (`/api/admin/teams/entitlements`) is the one writer.
 *
 * Every field is optional. A null field keeps the plan default. The override
 * applies only while the team is on a paid plan other than Plus; it never
 * turns a free team into a paid one.
 */
export type TeamEntitlementOverride = {
  /** Saved-machine ceiling for the whole team, replacing 5 per paid seat. */
  readonly maxActiveVms: number | null;
  /** vCPUs the team's running machines share. */
  readonly poolVcpus: number | null;
  /** Memory the team's running machines share, in MB. */
  readonly poolMemoryMb: number | null;
  /** Largest machine any member may start, in MB; a size on the image ladder. */
  readonly maxMemoryMb: number | null;
  /** Plan name for the deal, e.g. "Team (custom)". Display only. */
  readonly planLabel: string | null;
  /** Agreed monthly price in US cents. Recorded only; Stripe billing is unchanged. */
  readonly monthlyPriceCents: number | null;
};

export const TEAM_ENTITLEMENT_OVERRIDE_METADATA_KEY = "cmuxEntitlementOverride";

/** Machine sizes an override may name: the image ladder, 4 GB through 64 GB. */
export const TEAM_OVERRIDE_MEMORY_OPTIONS_MB: readonly number[] = [4096, 8192, 16384, 24576, 32768, 65536];

export const TEAM_ENTITLEMENT_OVERRIDE_BOUNDS = {
  maxActiveVms: { min: 1, max: 1_000 },
  poolVcpus: { min: 1, max: 8_192 },
  poolMemoryMb: { min: 1_024, max: 16_384 * 1_024 },
  planLabelLength: 60,
  monthlyPriceCents: { min: 0, max: 100_000_000 },
} as const;

export class TeamEntitlementOverrideInvalidError extends Error {
  constructor(readonly field: string, message: string) {
    super(message);
    this.name = "TeamEntitlementOverrideInvalidError";
  }
}

/**
 * Strictly validate an override sent by an admin. Throws on unknown fields,
 * wrong types, or out-of-range values; returns null when every field is null
 * so an empty deal clears the override instead of storing a no-op.
 */
export function parseTeamEntitlementOverrideInput(raw: unknown): TeamEntitlementOverride | null {
  if (raw === null) return null;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new TeamEntitlementOverrideInvalidError("override", "override must be an object or null");
  }
  const record = raw as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (!OVERRIDE_KEYS.includes(key as keyof TeamEntitlementOverride)) {
      throw new TeamEntitlementOverrideInvalidError(key, `unknown field ${key}`);
    }
  }
  const bounds = TEAM_ENTITLEMENT_OVERRIDE_BOUNDS;
  const maxMemoryMb = boundedInteger(record, "maxMemoryMb", { min: 1, max: Number.MAX_SAFE_INTEGER });
  if (maxMemoryMb !== null && !TEAM_OVERRIDE_MEMORY_OPTIONS_MB.includes(maxMemoryMb)) {
    throw new TeamEntitlementOverrideInvalidError("maxMemoryMb", "maxMemoryMb must be a machine size on the image ladder");
  }
  const label = record.planLabel;
  if (label !== undefined && label !== null && typeof label !== "string") {
    throw new TeamEntitlementOverrideInvalidError("planLabel", "planLabel must be a string or null");
  }
  const planLabel = typeof label === "string" && label.trim() ? label.trim() : null;
  if (planLabel !== null && planLabel.length > bounds.planLabelLength) {
    throw new TeamEntitlementOverrideInvalidError("planLabel", `planLabel must be at most ${bounds.planLabelLength} characters`);
  }
  const override: TeamEntitlementOverride = {
    maxActiveVms: boundedInteger(record, "maxActiveVms", bounds.maxActiveVms),
    poolVcpus: boundedInteger(record, "poolVcpus", bounds.poolVcpus),
    poolMemoryMb: boundedInteger(record, "poolMemoryMb", bounds.poolMemoryMb),
    maxMemoryMb,
    planLabel,
    monthlyPriceCents: boundedInteger(record, "monthlyPriceCents", bounds.monthlyPriceCents),
  };
  return isEmptyOverride(override) ? null : override;
}

/**
 * Read the override from team read-only metadata. Lenient: a malformed field
 * is dropped (falls back to the plan default) rather than failing auth for
 * every member of the team.
 */
export function teamEntitlementOverrideFromMetadata(metadata: unknown): TeamEntitlementOverride | null {
  if (!metadata || typeof metadata !== "object") return null;
  return teamEntitlementOverrideFromUnknown(
    (metadata as Record<string, unknown>)[TEAM_ENTITLEMENT_OVERRIDE_METADATA_KEY],
  );
}

/** Lenient parse of a stored override (Stack metadata or an identity snapshot row). */
export function teamEntitlementOverrideFromUnknown(raw: unknown): TeamEntitlementOverride | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const record = raw as Record<string, unknown>;
  const bounds = TEAM_ENTITLEMENT_OVERRIDE_BOUNDS;
  const maxMemoryMb = lenientInteger(record.maxMemoryMb, { min: 1, max: Number.MAX_SAFE_INTEGER });
  const planLabel = typeof record.planLabel === "string" && record.planLabel.trim()
    ? record.planLabel.trim().slice(0, bounds.planLabelLength)
    : null;
  const override: TeamEntitlementOverride = {
    maxActiveVms: lenientInteger(record.maxActiveVms, bounds.maxActiveVms),
    poolVcpus: lenientInteger(record.poolVcpus, bounds.poolVcpus),
    poolMemoryMb: lenientInteger(record.poolMemoryMb, bounds.poolMemoryMb),
    maxMemoryMb: maxMemoryMb !== null && TEAM_OVERRIDE_MEMORY_OPTIONS_MB.includes(maxMemoryMb) ? maxMemoryMb : null,
    planLabel,
    monthlyPriceCents: lenientInteger(record.monthlyPriceCents, bounds.monthlyPriceCents),
  };
  return isEmptyOverride(override) ? null : override;
}

/** Whether the override changes any machine limit (label and price do not). */
export function overrideChangesLimits(override: TeamEntitlementOverride | null | undefined): boolean {
  return !!override && (
    override.maxActiveVms !== null ||
    override.poolVcpus !== null ||
    override.poolMemoryMb !== null ||
    override.maxMemoryMb !== null
  );
}

/** The field only when the team has a deal, so identities without one keep their shape. */
export function withEntitlementOverride<Key extends string>(
  key: Key,
  override: TeamEntitlementOverride | null | undefined,
): { [K in Key]?: TeamEntitlementOverride } {
  return (override ? { [key]: override } : {}) as { [K in Key]?: TeamEntitlementOverride };
}

const OVERRIDE_KEYS: readonly (keyof TeamEntitlementOverride)[] = [
  "maxActiveVms",
  "poolVcpus",
  "poolMemoryMb",
  "maxMemoryMb",
  "planLabel",
  "monthlyPriceCents",
];

function isEmptyOverride(override: TeamEntitlementOverride): boolean {
  return OVERRIDE_KEYS.every((key) => override[key] === null);
}

function boundedInteger(
  record: Record<string, unknown>,
  field: string,
  bounds: { readonly min: number; readonly max: number },
): number | null {
  const value = record[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < bounds.min || value > bounds.max) {
    throw new TeamEntitlementOverrideInvalidError(field, `${field} must be an integer from ${bounds.min} to ${bounds.max}`);
  }
  return value;
}

function lenientInteger(value: unknown, bounds: { readonly min: number; readonly max: number }): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= bounds.min && value <= bounds.max
    ? value
    : null;
}
