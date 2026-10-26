/**
 * Which hostnames a tenant may route (cx-b4h.6). Pure rules plus the
 * deployment's domain configuration; the database facts (who verified what)
 * are read by src/proofs/tls-rule.ts.
 *
 * A tenant may route only:
 * - a managed hostname: one label `<name>--<tenant tag>` directly under the
 *   deployment's managed zone (CMUX_VM_MANAGED_DOMAIN_ZONE). The tag is derived
 *   from the tenant id, so two tenants can never name the same managed host and
 *   no reservation table is needed. The managed zone itself, wildcards over it
 *   and every other name under it are refused;
 * - a custom domain the tenant verified (a TXT challenge it created), or one
 *   label below it. When two tenants verified nested domains, the most specific
 *   verified domain decides who may route a name.
 */
import { Context, Effect, Layer } from "effect";
import type { TenantId } from "../lib/ids.ts";

const LABEL = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u;

/** A lowercase DNS name of at least two labels, or null. No trailing dot, no IP literals, no wildcards. */
export const hostnameOf = (value: string): string | null => {
  const lower = value.toLowerCase();
  if (lower.length === 0 || lower.length > 253 || /[^a-z0-9.-]/u.test(lower) || !lower.includes(".")) return null;
  const labels = lower.split(".");
  if (!labels.every((label) => label.length <= 63 && LABEL.test(label))) return null;
  // A name whose last label is numeric is an IPv4 literal or nothing routable.
  if (/^[0-9]+$/u.test(labels[labels.length - 1] ?? "")) return null;
  return lower;
};

/** A rule's domain: one exact hostname, or `*.` plus a hostname (one label of wildcard). `*` alone is refused. */
export type RuleDomain = { readonly kind: "exact"; readonly hostname: string } | { readonly kind: "wildcard"; readonly base: string };

export const ruleDomainOf = (value: string): RuleDomain | null => {
  if (value.startsWith("*.")) {
    const base = hostnameOf(value.slice(2));
    return base === null ? null : { kind: "wildcard", base };
  }
  const hostname = hostnameOf(value);
  return hostname === null ? null : { kind: "exact", hostname };
};

export const ruleDomainText = (domain: RuleDomain): string => (domain.kind === "exact" ? domain.hostname : `*.${domain.base}`);

/** The name itself and each parent with at least two labels, most specific first. */
export const ancestorsOf = (hostname: string): ReadonlyArray<string> => {
  const labels = hostname.split(".");
  const out: string[] = [];
  for (let index = 0; index <= labels.length - 2; index += 1) out.push(labels.slice(index).join("."));
  return out;
};

/** The parent of a hostname with at least three labels, or null. */
export const parentOf = (hostname: string): string | null => {
  const dot = hostname.indexOf(".");
  const parent = dot < 0 ? null : hostname.slice(dot + 1);
  return parent !== null && parent.includes(".") ? parent : null;
};

export const isUnder = (hostname: string, zone: string): boolean => hostname === zone || hostname.endsWith(`.${zone}`);

/** Deployment configuration for domains. Configuration, not secrets. */
export interface DomainPolicyService {
  /** The zone managed hostnames live under; null disables managed hostnames. */
  readonly managedZone: string | null;
  /** The hostname custom domains point at (CNAME); null when the deployment does not publish one. */
  readonly edgeHost: string | null;
  /** The nameserver `_acme-challenge.<domain>` is delegated to for wildcard certificates; null when not published. */
  readonly certificateNameserver: string | null;
}

export class DomainPolicy extends Context.Tag("cmux-vm/DomainPolicy")<DomainPolicy, DomainPolicyService>() {}

export interface DomainPolicyConfig {
  readonly managedZone?: string | undefined;
  readonly edgeHost?: string | undefined;
  readonly certificateNameserver?: string | undefined;
}

/** Malformed values disable the feature they configure; they are never widened. */
export const makeDomainPolicy = (config: DomainPolicyConfig): DomainPolicyService => ({
  managedZone: config.managedZone === undefined ? null : hostnameOf(config.managedZone.trim()),
  edgeHost: config.edgeHost === undefined ? null : hostnameOf(config.edgeHost.trim()),
  certificateNameserver: config.certificateNameserver === undefined ? null : hostnameOf(config.certificateNameserver.trim()),
});

export const domainPolicyLayer = (config: DomainPolicyConfig): Layer.Layer<DomainPolicy> => Layer.succeed(DomainPolicy, makeDomainPolicy(config));

/** Ten hex characters of SHA-256 over the tenant id: stable, and distinct per tenant in practice (40 bits). */
export const tenantTag = (tenantId: TenantId): Effect.Effect<string> =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(`cmux-vm-managed-host:${tenantId}`))).pipe(
    Effect.map((digest) => Array.from(new Uint8Array(digest).slice(0, 5), (byte) => byte.toString(16).padStart(2, "0")).join("")),
  );

/** The suffix every managed hostname of this tenant ends with (`--<tag>.<zone>`), or null when managed hostnames are off. */
export const managedSuffixOf = (policy: DomainPolicyService, tenantId: TenantId): Effect.Effect<string | null> =>
  policy.managedZone === null ? Effect.succeed(null) : Effect.map(tenantTag(tenantId), (tag) => `--${tag}.${policy.managedZone}`);

/** Whether `hostname` is exactly one managed label of this tenant under the managed zone. */
export const isManagedHostnameOf = (hostname: string, suffix: string): boolean => {
  if (!hostname.endsWith(suffix)) return false;
  const name = hostname.slice(0, -suffix.length);
  const label = `${name}${suffix.slice(0, suffix.indexOf("."))}`;
  return name.length > 0 && !name.includes(".") && LABEL.test(name) && label.length <= 63;
};
