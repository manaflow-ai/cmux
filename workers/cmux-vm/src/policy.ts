/**
 * Per-tenant policy: which tenants are dev/test, VM quotas, rate limits and
 * upload size. Configuration, not secrets: it comes from Worker vars.
 *
 * A tenant is dev/test when the Worker is not the production deployment
 * (local, preview and staging hold only dev/test machines), or when its id is
 * listed in DEV_TEST_TENANT_IDS on production. Dev/test VMs may not ask for an
 * idle timeout over 300 seconds and default to 300. Every other production VM
 * is a product machine: it defaults to -1 (never pause for idleness), because
 * the web app's CloudDO decides when product machines pause.
 */
import { Context, Layer } from "effect";
import type { TenantId } from "./lib/ids.ts";
import type { RateClass, RateRule } from "./limits/ledger.ts";

export type Environment = "local" | "preview" | "staging" | "production";

export const DEV_TEST_MAX_IDLE_SECONDS = 300;
export const PRODUCT_DEFAULT_IDLE_SECONDS = -1;

export interface TenantPolicyService {
  readonly environment: Environment;
  readonly isDevTest: (tenantId: TenantId) => boolean;
  /** Live VMs a tenant may hold. */
  readonly maxVms: (tenantId: TenantId) => number;
  /** Live snapshots per tenant; a budget separate from VMs. */
  readonly maxSnapshots: (tenantId: TenantId) => number;
  readonly rate: (rateClass: RateClass) => RateRule;
  /** Largest file upload accepted, in bytes. */
  readonly maxUploadBytes: number;
}

export class TenantPolicy extends Context.Tag("cmux-vm/TenantPolicy")<TenantPolicy, TenantPolicyService>() {}

export interface PolicyConfig {
  readonly environment: Environment;
  readonly devTestTenantIds?: ReadonlyArray<string>;
  /** Live VMs per tenant for every tenant (tests); overrides the defaults. */
  readonly maxVms?: number;
  /** Per-tenant live VM limits, by Stack team id, from TENANT_VM_QUOTAS. */
  readonly vmQuotas?: Readonly<Record<string, number>>;
  /** Live snapshots per tenant, for every tenant (tests and overrides). */
  readonly maxSnapshots?: number;
  readonly ratePerMinute?: Partial<Record<RateClass, number>>;
  readonly maxUploadBytes?: number;
}

/**
 * Defaults until plan-based limits exist. TODO(cx-b4h, billing owner Lawrence
 * Chen): take maxVms from the tenant's plan (web/services/vms/entitlements.ts
 * maxActiveVms) once the entitlement source is reachable from this Worker.
 */
export const DEFAULT_MAX_VMS = 20;
export const DEFAULT_DEV_TEST_MAX_VMS = 20;
/** Warm-start pools keep many snapshots per team; snapshots cost storage, not compute. */
export const DEFAULT_MAX_SNAPSHOTS = 100;
export const DEFAULT_RATE_PER_MINUTE: Readonly<Record<RateClass, number>> = { read: 600, write: 60, exec: 300, files: 300 };
/** Workers accept request bodies up to 100 MB on most plans; stay under it. */
export const DEFAULT_MAX_UPLOAD_BYTES = 96 * 1024 * 1024;

export const makeTenantPolicy = (config: PolicyConfig): TenantPolicyService => {
  const listed = new Set(config.devTestTenantIds ?? []);
  const isDevTest = (tenantId: TenantId) => config.environment !== "production" || listed.has(tenantId);
  return {
    environment: config.environment,
    isDevTest,
    maxVms: (tenantId) =>
      config.maxVms ?? config.vmQuotas?.[tenantId] ?? (isDevTest(tenantId) ? DEFAULT_DEV_TEST_MAX_VMS : DEFAULT_MAX_VMS),
    maxSnapshots: () => config.maxSnapshots ?? DEFAULT_MAX_SNAPSHOTS,
    rate: (rateClass) => ({ perMinute: config.ratePerMinute?.[rateClass] ?? DEFAULT_RATE_PER_MINUTE[rateClass] }),
    maxUploadBytes: config.maxUploadBytes ?? DEFAULT_MAX_UPLOAD_BYTES,
  };
};

export const tenantPolicyLayer = (config: PolicyConfig): Layer.Layer<TenantPolicy> => Layer.succeed(TenantPolicy, makeTenantPolicy(config));

/** Parses the ENVIRONMENT var; anything unknown is treated as production, the strictest setting. */
export const parseEnvironment = (value: string | undefined): Environment =>
  value === "local" || value === "preview" || value === "staging" ? value : "production";

/** Parses DEV_TEST_TENANT_IDS: comma or whitespace separated Stack team ids. */
export const parseTenantList = (value: string | undefined): ReadonlyArray<string> =>
  (value ?? "").split(/[\s,]+/u).filter((entry) => entry.length > 0);

/**
 * Parses TENANT_VM_QUOTAS, a JSON object of Stack team id to live VM limit
 * (for example a team that needs more than the default). Bad entries are
 * ignored, never widened.
 */
export const parseVmQuotas = (value: string | undefined): Readonly<Record<string, number>> => {
  if (value === undefined || value.trim() === "") return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    return {};
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return {};
  return Object.fromEntries(
    Object.entries(parsed).filter(
      (entry): entry is [string, number] => typeof entry[1] === "number" && Number.isInteger(entry[1]) && entry[1] >= 0 && entry[1] <= 10_000,
    ),
  );
};

/** The idle timeout to create with, or an error message when the request is not allowed. */
export const resolveIdleTimeout = (
  policy: TenantPolicyService,
  tenantId: TenantId,
  requested: number | undefined,
): { readonly ok: true; readonly seconds: number } | { readonly ok: false; readonly message: string } => {
  if (!policy.isDevTest(tenantId)) return { ok: true, seconds: requested ?? PRODUCT_DEFAULT_IDLE_SECONDS };
  if (requested === undefined) return { ok: true, seconds: DEV_TEST_MAX_IDLE_SECONDS };
  if (requested < 1 || requested > DEV_TEST_MAX_IDLE_SECONDS) {
    return { ok: false, message: `Dev/test VMs need an idle timeout between 1 and ${DEV_TEST_MAX_IDLE_SECONDS} seconds` };
  }
  return { ok: true, seconds: requested };
};
