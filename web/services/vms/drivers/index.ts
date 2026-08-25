import { BlaxelProvider } from "./blaxel";
import { DaytonaProvider } from "./daytona";
import { E2BProvider } from "./e2b";
import { FreestyleProvider } from "./freestyle";
import type { ProviderId, VMProvider } from "./types";

export * from "./types";
export { BlaxelProvider, DaytonaProvider, E2BProvider, FreestyleProvider };

let registry: Map<ProviderId, VMProvider> | null = null;

function buildRegistry(): Map<ProviderId, VMProvider> {
  const map = new Map<ProviderId, VMProvider>();
  map.set("e2b", new E2BProvider());
  map.set("freestyle", new FreestyleProvider());
  map.set("daytona", new DaytonaProvider());
  map.set("blaxel", new BlaxelProvider());
  return map;
}

export function getProvider(id: ProviderId): VMProvider {
  if (!registry) registry = buildRegistry();
  const p = registry.get(id);
  if (!p) throw new Error(`unknown VM provider: ${id}`);
  return p;
}

export function defaultProviderId(): ProviderId {
  const configured = process.env.CMUX_VM_DEFAULT_PROVIDER as ProviderId | undefined;
  if (configured === "e2b" || configured === "freestyle" || configured === "daytona" || configured === "blaxel") return configured;
  // Blaxel is the default interactive provider. Other providers remain available
  // as explicit overrides (or an explicitly configured deployment rollback), but
  // a bare `cmux vm new` must never silently fall back to Freestyle SSH.
  return "blaxel";
}
