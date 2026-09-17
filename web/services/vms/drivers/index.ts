import { DaytonaProvider } from "./daytona";
import { E2BProvider } from "./e2b";
import { FreestyleProvider } from "./freestyle";
import { isProviderId, type ProviderId, type VmCapabilities, type VMProvider } from "./types";

export * from "./types";
export { DaytonaProvider, E2BProvider, FreestyleProvider };

let registry: Map<ProviderId, VMProvider> | null = null;

function buildRegistry(): Map<ProviderId, VMProvider> {
  const map = new Map<ProviderId, VMProvider>();
  map.set("e2b", new E2BProvider());
  map.set("freestyle", new FreestyleProvider());
  map.set("daytona", new DaytonaProvider());
  return map;
}

export function getProvider(id: ProviderId): VMProvider {
  if (!registry) registry = buildRegistry();
  const p = registry.get(id);
  if (!p) throw new Error(`unknown VM provider: ${id}`);
  return p;
}

/**
 * The provider whose persistent home volumes the reaper scans, or null when no
 * registered driver exposes a volume inventory. Volumes were a single-provider
 * feature; the seam stays so the reaper wakes up on its own if a driver
 * implements `listVolumes` again.
 */
export function volumeCapableProviderId(): ProviderId | null {
  if (!registry) registry = buildRegistry();
  for (const [id, provider] of registry) {
    if (typeof provider.listVolumes === "function") return id;
  }
  return null;
}

export function defaultProviderId(): ProviderId {
  const configured = process.env.CMUX_VM_DEFAULT_PROVIDER;
  if (isProviderId(configured)) return configured;
  // Freestyle (the public platform) is the default interactive provider. E2B and
  // Daytona remain available as explicit overrides, or as an explicitly
  // configured deployment rollback, but never as a silent fallback.
  return "freestyle";
}

/** The provider's capability set with defaults applied: an absent flag means supported,
 *  and `fork` follows the method's existence unless declared. */
export function vmCapabilitiesFor(id: ProviderId): VmCapabilities {
  const provider = getProvider(id);
  const declared = provider.capabilities ?? {};
  return {
    snapshot: declared.snapshot ?? true,
    restore: declared.restore ?? true,
    fork: declared.fork ?? typeof provider.fork === "function",
  };
}
