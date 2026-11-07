import { VM_PROVIDER_RESOURCE_BOUNDS } from "./machineSpec";

/**
 * A custom Cloud VM deal for one billing team, set by a cmux admin. Every
 * field is optional: a missing field keeps the plan default. The override
 * changes caps only; the team still needs a paid plan (Stripe or an admin
 * Team grant) to provision at all.
 *
 * Stored on the Stack team as `clientReadOnlyMetadata.cmuxVmEntitlementOverride`
 * (members can read their own deal, only the server can write it) and carried
 * on `AuthedTeam`, so it rides the same auth path and identity snapshot as
 * `cmuxVmPlan` and `cmuxSeats`.
 */
export type VmEntitlementOverride = {
  /** Saved-machine ceiling for the whole team, replacing seats x 5. */
  readonly maxActiveVms?: number;
  /** Shared vCPU pool for the team's active machines. */
  readonly poolVcpus?: number;
  /** Shared memory pool for the team's active machines. */
  readonly poolMemoryMb?: number;
  /** Largest machine a member may start, a row of the image ladder. vCPUs follow the ladder. */
  readonly maxMemoryMb?: number;
  /** Name shown for the deal, for example "Acme Team". */
  readonly planLabel?: string;
  /** Agreed monthly price in US cents, for display and records. */
  readonly monthlyPriceCents?: number;
};

export const VM_ENTITLEMENT_OVERRIDE_METADATA_KEY = "cmuxVmEntitlementOverride";

/** Upper bounds that keep a typo from granting an unbounded fleet. */
export const VM_ENTITLEMENT_OVERRIDE_LIMITS = {
  maxActiveVms: 1000,
  poolVcpus: 8000,
  poolMemoryMb: 16000 * 1024,
  planLabelLength: 64,
  monthlyPriceCents: 100_000_000,
} as const;

/**
 * Machine sizes the override may name as its ceiling, memory in MB. Kept in
 * step with VM_MEMORY_OPTIONS_MB in entitlements.ts (asserted by a test);
 * duplicated here so this module has no runtime import of entitlements.
 */
export const VM_ENTITLEMENT_OVERRIDE_MEMORY_OPTIONS_MB: readonly number[] = [4096, 8192, 16384, 24576, 32768, 65536];

const NUMERIC_FIELDS = ["maxActiveVms", "poolVcpus", "poolMemoryMb", "maxMemoryMb", "monthlyPriceCents"] as const;
const OVERRIDE_FIELDS = [...NUMERIC_FIELDS, "planLabel"] as const;

export type VmEntitlementOverrideValidation =
  | { readonly ok: true; readonly override: VmEntitlementOverride | null }
  | { readonly ok: false; readonly field: string; readonly message: string };

/**
 * Validate an admin-supplied override. Unknown keys are rejected so a
 * misspelled field never silently keeps the plan default. An object with no
 * fields normalizes to null (no override).
 */
export function validateVmEntitlementOverride(raw: unknown): VmEntitlementOverrideValidation {
  if (raw === null || raw === undefined) return { ok: true, override: null };
  if (typeof raw !== "object" || Array.isArray(raw)) {
    return { ok: false, field: "override", message: "must be an object or null" };
  }
  const input = raw as Record<string, unknown>;
  for (const key of Object.keys(input)) {
    if (!(NUMERIC_FIELDS as readonly string[]).includes(key) && key !== "planLabel") {
      return { ok: false, field: key, message: "is not an override field" };
    }
  }
  const out: { -readonly [K in keyof VmEntitlementOverride]: VmEntitlementOverride[K] } = {};
  for (const field of NUMERIC_FIELDS) {
    const value = input[field];
    if (value === undefined || value === null) continue;
    const error = numericFieldError(field, value);
    if (error) return { ok: false, field, message: error };
    out[field] = value as number;
  }
  if (input.planLabel !== undefined && input.planLabel !== null) {
    if (typeof input.planLabel !== "string") {
      return { ok: false, field: "planLabel", message: "must be a string" };
    }
    const label = input.planLabel.trim();
    if (label.length > VM_ENTITLEMENT_OVERRIDE_LIMITS.planLabelLength) {
      return { ok: false, field: "planLabel", message: `must be at most ${VM_ENTITLEMENT_OVERRIDE_LIMITS.planLabelLength} characters` };
    }
    if (label) out.planLabel = label;
  }
  const poolError = poolFitsLargestMachineError(out);
  if (poolError) return { ok: false, field: poolError.field, message: poolError.message };
  return { ok: true, override: Object.keys(out).length > 0 ? out : null };
}

/** A pool smaller than one machine at the deal's ceiling could never admit that machine. */
function poolFitsLargestMachineError(
  override: VmEntitlementOverride,
): { readonly field: string; readonly message: string } | null {
  if (override.maxMemoryMb === undefined) return null;
  if (override.poolMemoryMb !== undefined && override.poolMemoryMb < override.maxMemoryMb) {
    return { field: "poolMemoryMb", message: "must hold at least one machine at maxMemoryMb" };
  }
  const machineVcpus = override.maxMemoryMb / 2048;
  if (override.poolVcpus !== undefined && override.poolVcpus < machineVcpus) {
    return { field: "poolVcpus", message: `must hold at least one machine at maxMemoryMb (${machineVcpus} vCPUs)` };
  }
  return null;
}

/** The override stored on a team, or null when absent or malformed. */
export function vmEntitlementOverrideFromMetadata(metadata: unknown): VmEntitlementOverride | null {
  if (!metadata || typeof metadata !== "object") return null;
  return vmEntitlementOverrideFromUnknown((metadata as Record<string, unknown>)[VM_ENTITLEMENT_OVERRIDE_METADATA_KEY]);
}

/**
 * Parse a stored override (metadata or identity snapshot); malformed means
 * none. Keys this version does not know are dropped rather than voiding the
 * deal, so a server that predates a new field keeps the rest during a deploy.
 */
export function vmEntitlementOverrideFromUnknown(raw: unknown): VmEntitlementOverride | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const known = Object.fromEntries(
    Object.entries(raw as Record<string, unknown>).filter(([key]) => (OVERRIDE_FIELDS as readonly string[]).includes(key)),
  );
  const parsed = validateVmEntitlementOverride(known);
  return parsed.ok ? parsed.override : null;
}

function numericFieldError(field: (typeof NUMERIC_FIELDS)[number], value: unknown): string | null {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) return "must be an integer";
  switch (field) {
    case "maxActiveVms":
      return value >= 1 && value <= VM_ENTITLEMENT_OVERRIDE_LIMITS.maxActiveVms
        ? null : `must be between 1 and ${VM_ENTITLEMENT_OVERRIDE_LIMITS.maxActiveVms}`;
    case "poolVcpus":
      return value >= VM_PROVIDER_RESOURCE_BOUNDS.vcpus.min && value <= VM_ENTITLEMENT_OVERRIDE_LIMITS.poolVcpus
        ? null : `must be between ${VM_PROVIDER_RESOURCE_BOUNDS.vcpus.min} and ${VM_ENTITLEMENT_OVERRIDE_LIMITS.poolVcpus}`;
    case "poolMemoryMb":
      if (value % 1024 !== 0) return "must be a whole number of GB";
      return value >= VM_PROVIDER_RESOURCE_BOUNDS.memoryMb.min && value <= VM_ENTITLEMENT_OVERRIDE_LIMITS.poolMemoryMb
        ? null : `must be between ${VM_PROVIDER_RESOURCE_BOUNDS.memoryMb.min} and ${VM_ENTITLEMENT_OVERRIDE_LIMITS.poolMemoryMb}`;
    case "maxMemoryMb":
      return VM_ENTITLEMENT_OVERRIDE_MEMORY_OPTIONS_MB.includes(value)
        ? null : `must be one of ${VM_ENTITLEMENT_OVERRIDE_MEMORY_OPTIONS_MB.join(", ")}`;
    case "monthlyPriceCents":
      return value >= 0 && value <= VM_ENTITLEMENT_OVERRIDE_LIMITS.monthlyPriceCents
        ? null : `must be between 0 and ${VM_ENTITLEMENT_OVERRIDE_LIMITS.monthlyPriceCents}`;
  }
}
