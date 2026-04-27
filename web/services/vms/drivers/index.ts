import { E2BProvider } from "./e2b";
import { FreestyleProvider } from "./freestyle";
import type { ProviderId, VMProvider } from "./types";

export * from "./types";
export { E2BProvider, FreestyleProvider };

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
  // Freestyle is the default for interactive work. The route layer still resolves
  // the provider image from the manifest/env before any paid create.
  return "freestyle";
}
