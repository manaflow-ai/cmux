import type { VmCreator } from "./creators";
import { vmCapabilitiesFor } from "./drivers";
import { vmImageKindFor } from "./images/resolver";
import type { BaseVmEntry, VmEntry } from "./workflows";

/** Fields promised by every REST machine producer, including restore and fork. */
export function publicVmCore(vm: VmEntry) {
  return {
    id: vm.providerVmId,
    provider: vm.provider,
    image: vm.image,
    imageVersion: vm.imageVersion,
    createdAt: vm.createdAt,
    capabilities: vmCapabilitiesFor(vm.provider),
  };
}

/** Metadata needed when a client appends a create or merges a detail into its list. */
function publicVmMetadata(vm: VmEntry, createdBy: VmCreator | null) {
  return {
    kind: vmImageKindFor(vm.provider, vm.image),
    displayName: vm.displayName,
    slug: vm.slug,
    createdBy,
    address: { ipv4: vm.addressIpv4 ?? null, ipv6: vm.addressIpv6 ?? null },
    agentUpdates: vm.agentUpdates,
    idlePauseMinutes: vm.idlePauseMinutes,
    cmuxTuiContract: vm.cmuxTuiContract,
  };
}

/** List/detail contract. List entitlements and pool accounting are explicit extensions. */
export function publicVmDetail(vm: VmEntry, createdBy: VmCreator | null) {
  return {
    ...publicVmCore(vm),
    ...publicVmMetadata(vm, createdBy),
    status: vm.status,
    idlePause: vm.idlePause,
    pauseReason: vm.pauseReason,
  };
}

/** Create has no status/expiry promise; size and attach remain route-specific extensions. */
export function publicVmCreated(vm: VmEntry, createdBy: VmCreator | null) {
  return {
    ...publicVmCore(vm),
    ...publicVmMetadata(vm, createdBy),
    ...(vm.resourceReservation ? {
      resources: vm.resourceReservation,
      resourceReservation: vm.resourceReservation,
    } : {}),
  };
}

/** Restore/fork intentionally return a lifecycle receipt, not an appendable list row. */
export function publicVmRestored(vm: VmEntry) {
  return { ...publicVmCore(vm), status: vm.status };
}

export function publicVmBase(vm: BaseVmEntry) {
  return {
    ...publicVmRestored(vm),
    kind: vmImageKindFor(vm.provider, vm.image),
    base: {
      id: vm.baseId,
      name: vm.baseName,
      generation: vm.generation,
      retainedProviderVmId: vm.retainedProviderVmId,
    },
  };
}

/** The dashboard is a reduced read model; it has no append/merge mutation lifecycle. */
export function publicVmDashboard(vm: VmEntry, teamId: string | null) {
  return {
    id: vm.providerVmId,
    name: vm.displayName ?? vm.slug ?? vm.providerVmId,
    status: vm.status,
    teamId,
  };
}

export type PublicVmCore = ReturnType<typeof publicVmCore>;
export type PublicVmDetail = ReturnType<typeof publicVmDetail>;
export type PublicVmCreated = ReturnType<typeof publicVmCreated>;
export type PublicVmRestored = ReturnType<typeof publicVmRestored>;
export type PublicVmBase = ReturnType<typeof publicVmBase>;
export type PublicVmDashboard = ReturnType<typeof publicVmDashboard>;
