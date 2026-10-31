/**
 * Agent keys: short-lived API keys a cloud agent holds to start and clean up
 * its own sandboxes. An agent key reaches only VMs carrying its labels (always
 * `cmux.agent=<key id>`, plus any labels its issuer was confined to), every VM
 * it creates gets them, and it has a live-VM count and an estimated $/h budget.
 * When it expires or is revoked, the reaper deletes its VMs and their client
 * sessions.
 */
import type { Scope } from "./scopes.ts";

/** The label every VM of an agent carries; its value is the agent key's id. */
export const AGENT_LABEL = "cmux.agent";

/** The most an agent key may hold. Network, files, terminals, snapshots and admin stay with the issuer. */
export const AGENT_SCOPES: ReadonlyArray<Scope> = ["vm:read", "vm:write", "vm:exec"];

export const AGENT_DEFAULTS = { ttlSeconds: 4 * 3600, maxVms: 5, maxUsdPerHour: 2 } as const;
export const AGENT_LIMITS = {
  minTtlSeconds: 60,
  maxTtlSeconds: 24 * 3600,
  maxVms: 20,
  maxUsdPerHour: 50,
} as const;

/** An agent key's confinement and budget, as authentication hands it to handlers. */
export interface AgentBudget {
  readonly maxVms: number;
  readonly maxUsdPerHour: number;
}

/**
 * The estimate the $/h budget counts: the provider's list price is about
 * 0.26 USD/h for 4 vCPU and 8 GiB (plans/cmux-next/cloud-subagents-DESIGN.md),
 * split as 0.05 per vCPU-hour and 0.0075 per GiB-hour. Disk is not counted.
 */
export const USD_PER_VCPU_HOUR = 0.05;
export const USD_PER_GIB_HOUR = 0.0075;

export const estimatedUsdPerHour = (vcpus: number, memoryMib: number): number =>
  vcpus * USD_PER_VCPU_HOUR + (memoryMib / 1024) * USD_PER_GIB_HOUR;

/** The provider's base sizes (src/upstream/live.ts BASE_IMAGES), smallest first; the default is 4 vCPU / 8 GiB. */
const BASES: ReadonlyArray<{ readonly vcpus: number; readonly memoryMib: number; readonly diskMib: number }> = [
  { vcpus: 2, memoryMib: 4096, diskMib: 16384 },
  { vcpus: 4, memoryMib: 8192, diskMib: 32768 },
  { vcpus: 8, memoryMib: 16384, diskMib: 65536 },
  { vcpus: 16, memoryMib: 32768, diskMib: 131072 },
  { vcpus: 32, memoryMib: 65536, diskMib: 131072 },
];

/** The size a create with these floors ends at: the base it boots, grown to every requested floor. */
export const sizeOfCreate = (size: { readonly vcpus?: number | undefined; readonly memoryMib?: number | undefined; readonly diskMib?: number | undefined } | undefined) => {
  const unsized = size === undefined || (size.vcpus === undefined && size.memoryMib === undefined && size.diskMib === undefined);
  const fits = unsized
    ? [BASES[1]]
    : BASES.filter(
        (base) =>
          (size.vcpus === undefined || base.vcpus <= size.vcpus) &&
          (size.memoryMib === undefined || base.memoryMib <= size.memoryMib) &&
          (size.diskMib === undefined || base.diskMib <= size.diskMib),
      );
  const base = fits.at(-1) ?? BASES[0] ?? { vcpus: 4, memoryMib: 8192, diskMib: 32768 };
  return { vcpus: Math.max(base.vcpus, size?.vcpus ?? 0), memoryMib: Math.max(base.memoryMib, size?.memoryMib ?? 0) };
};

/** Linux user names a client session may name (useradd's portable set). */
export const LINUX_USER = /^[a-z_][a-z0-9_-]{0,31}$/u;
/** The Ubuntu base images' uid-1000 user, which the provider's SSH proxy also defaults to. */
export const DEFAULT_LINUX_USER = "ubuntu";
