import { FreestyleProvider } from "./freestyle";
import {
  isProviderId,
  type AttachTransport,
  type ProviderId,
  type VmCapabilities,
  type VMProvider,
} from "./types";

export * from "./types";
export { FreestyleProvider };

let registry: Map<ProviderId, VMProvider> | null = null;

function buildRegistry(): Map<ProviderId, VMProvider> {
  const map = new Map<ProviderId, VMProvider>();
  map.set("freestyle", new FreestyleProvider());
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
  // Freestyle (the public platform) is the only provider; the env override
  // survives so an operator can still pin it explicitly.
  return "freestyle";
}

/**
 * The provider's capability set with defaults applied. Structural facts (does the
 * driver implement the method?) are the baseline; an explicit declaration on the
 * driver overrides them — a driver that implements `snapshot` only to throw
 * NotImplementedError declares `snapshot: false`. Capabilities with no structural
 * signal (`desktop`, `sizing`, `persistentHome`) default to false: a driver must
 * opt in to what it actually honors, so clients never see a verb that silently
 * drops its input.
 */
export function vmCapabilitiesFor(id: ProviderId): VmCapabilities {
  return vmCapabilitiesOf(getProvider(id));
}

/** Capability derivation for any driver instance (exported for tests and mocks). */
export function vmCapabilitiesOf(provider: VMProvider): VmCapabilities {
  const declared = provider.capabilities ?? {};
  const structuralTransports: AttachTransport[] = [];
  if (typeof provider.openCmuxRemote === "function") structuralTransports.push("cmux-remote");
  if (typeof provider.openAttach === "function") structuralTransports.push("websocket");
  if (typeof provider.openSSH === "function") structuralTransports.push("ssh");
  return {
    snapshot: declared.snapshot ?? true,
    restore: declared.restore ?? true,
    fork: declared.fork ?? typeof provider.fork === "function",
    exec: declared.exec ?? true,
    stats: declared.stats ?? typeof provider.getStats === "function",
    ports: declared.ports ?? typeof provider.openPort === "function",
    desktop: declared.desktop ?? false,
    sizing: declared.sizing ?? false,
    persistentHome: declared.persistentHome ?? false,
    attachTransports:
      declared.attachTransports ?? provider.attachTransports ?? structuralTransports,
  };
}
