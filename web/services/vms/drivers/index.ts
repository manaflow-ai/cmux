import { E2BProvider, DEFAULT_E2B_WS_TEMPLATE } from "./e2b";
import { FreestyleProvider, DEFAULT_FREESTYLE_SNAPSHOT_ID } from "./freestyle";
import type { ProviderId, VMProvider } from "./types";

export * from "./types";
export { DEFAULT_E2B_WS_TEMPLATE, DEFAULT_FREESTYLE_SNAPSHOT_ID, E2BProvider, FreestyleProvider };

let registry: Map<ProviderId, VMProvider> | null = null;

function buildRegistry(): Map<ProviderId, VMProvider> {
  const map = new Map<ProviderId, VMProvider>();
  map.set("e2b", new E2BProvider());
  map.set("freestyle", new FreestyleProvider());
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
  if (configured === "e2b" || configured === "freestyle") return configured;
  // Freestyle is the default for interactive work. The driver carries a baked
  // snapshot fallback, so this does not depend on dashboard env configuration.
  return "freestyle";
}
