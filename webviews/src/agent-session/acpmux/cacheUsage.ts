// The prompt cache fields acpmux puts on a Claude chat's usage_update (`_meta.acpmux`, from
// claude_stdio): its expiry, whether acpmux compacts before the next prompt once it lapsed
// ("When You Return"), the last call's hit ratio and the last miss's likely cause. React-free:
// the client (direct.ts) keeps them on its usage; the context card and composer chip read them.
import type { AcpmuxCacheMiss, AcpmuxSnapshot } from "./model";

type ContextUsage = NonNullable<NonNullable<AcpmuxSnapshot["summary"]>["usage"]>;

const MISS_CAUSES: ReadonlySet<string> = new Set<AcpmuxCacheMiss["cause"]>([
  "expired",
  "compaction",
  "model",
  "effort",
  "unknown",
]);

/// The prompt cache's fields of a usage_update's `_meta.acpmux` (claude_stdio), as the usage keeps
/// them: each only when present and well formed, so a report without one drops the old value. A
/// miss whose cause this page does not know yet reads "unknown".
export function cacheUsageMeta(
  meta: unknown,
): Pick<ContextUsage, "cacheExpiresAt" | "compactOnReturn" | "cacheHit" | "cacheMiss"> {
  const read = (meta && typeof meta === "object" ? meta : {}) as Record<string, unknown>;
  const expiresAt = Number(read.cacheExpiresAt);
  const hit = read.cacheHit;
  const miss =
    read.cacheMiss && typeof read.cacheMiss === "object" ? (read.cacheMiss as Record<string, unknown>) : undefined;
  const missAt = Number(miss?.at);
  const cause: AcpmuxCacheMiss["cause"] = MISS_CAUSES.has(String(miss?.cause))
    ? (miss?.cause as AcpmuxCacheMiss["cause"])
    : "unknown";
  return {
    ...(Number.isFinite(expiresAt) && expiresAt > 0 ? { cacheExpiresAt: expiresAt } : {}),
    ...(read.compactOnReturn === true ? { compactOnReturn: true } : {}),
    ...(typeof hit === "number" && Number.isFinite(hit) && hit >= 0 && hit <= 1 ? { cacheHit: hit } : {}),
    ...(miss && Number.isFinite(missAt) && missAt > 0 ? { cacheMiss: { cause, at: missAt } } : {}),
  };
}
