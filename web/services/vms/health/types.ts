/**
 * Shapes for the staff-only Cloud VM health sweep. The sweep reads the whole
 * provider account (cmux Cloud machines and every other workload that shares
 * it), probes running machines, and stores one report per run. The page only
 * ever reads a stored report, so nothing here is computed on a page load.
 */

/** Provider VM states. Freestyle's set today; unknown future states pass through. */
export type ProviderVmState = "starting" | "running" | "pausing" | "paused" | "stopped" | (string & {});

/** One provider VM as the inventory listing returns it. No secrets, no guest data. */
export type ProviderInventoryVm = {
  readonly id: string;
  readonly state: ProviderVmState;
  readonly metadata: Readonly<Record<string, string>>;
  /** The snapshot slug it booted from (current name, else the name at create), or its id. */
  readonly snapshot: string | null;
  readonly cpu: number | null;
  readonly memoryMib: number | null;
  readonly storageMib: number | null;
  /** Null or negative means the VM never idles out. */
  readonly idleTimeoutSeconds: number | null;
  readonly vpcIds: readonly string[];
  readonly createdAt: string;
  readonly updatedAt: string;
};

export type ProviderVmInventory = {
  readonly vms: readonly ProviderInventoryVm[];
  /** False when paging stopped early (page cap, deadline); missing VMs are then unknown, not gone. */
  readonly complete: boolean;
};

/** One TLS rule reduced to what attribution needs. Domains and transforms are dropped. */
export type ProviderTlsRuleRef = {
  readonly id: string;
  readonly managed: boolean;
  readonly vmIds: readonly string[];
  readonly vpcIds: readonly string[];
};

export type ProviderTlsRuleInventory = {
  /** The provider's account-wide count, which is what the limit is measured against. */
  readonly totalCount: number;
  readonly rules: readonly ProviderTlsRuleRef[];
  readonly complete: boolean;
};

/**
 * A control-path probe. `hung` means the provider accepted the request but the
 * VM did not answer (timeout, 409 stale runtime, 5xx); `error` is a probe that
 * says nothing about the VM (401, 429, a network failure before the provider).
 */
export type VmControlProbe =
  | { readonly outcome: "ok"; readonly latencyMs: number }
  | { readonly outcome: "gone"; readonly latencyMs: number }
  /** Paused or moving since the inventory was read; not probed, so not woken. */
  | { readonly outcome: "not_running"; readonly latencyMs: number }
  | { readonly outcome: "hung"; readonly latencyMs: number; readonly detail: string }
  | { readonly outcome: "error"; readonly latencyMs: number; readonly detail: string };

export type VmProbeRecord =
  | ({ readonly vmId: string } & VmControlProbe)
  | { readonly vmId: string; readonly outcome: "skipped_budget" | "skipped_idle" };

/** The cmux DB row the sweep joins to a provider VM. */
export type VmHealthDbRow = {
  readonly id: string;
  readonly providerVmId: string;
  readonly userId: string;
  readonly ownerTeamId: string;
  readonly status: string;
  readonly imageId: string;
  readonly createdAt: Date;
  readonly updatedAt: Date;
};

/** `cmux_cloud` for metadata `cmux=cloud`, `app:<name>` for metadata `app=<name>`, else `other`. */
export type VmWorkload = string;

export type VmHealthOwner = {
  readonly cloudVmId: string;
  readonly userId: string;
  readonly teamId: string | null;
};

export type VmHealthSize = {
  readonly cpu: number | null;
  readonly memoryMib: number | null;
  readonly storageMib: number | null;
};

export type HungVm = {
  readonly vmId: string;
  readonly workload: VmWorkload;
  readonly owner: VmHealthOwner | null;
  readonly snapshot: string | null;
  readonly size: VmHealthSize;
  readonly firstSeenHungAt: string;
  readonly providerUpdatedAt: string;
  readonly dbUpdatedAt: string | null;
  readonly detail: string;
};

export type StuckVm = {
  readonly vmId: string;
  /** `provider` for a provider transition, `db` for a cmux row stuck provisioning. */
  readonly source: "provider" | "db";
  readonly state: string;
  readonly workload: VmWorkload;
  readonly owner: VmHealthOwner | null;
  readonly since: string;
  readonly minutes: number;
};

/** A VM seen mid-transition, remembered across sweeps so its age does not depend on provider timestamps. */
export type VmTransitionSighting = {
  readonly vmId: string;
  readonly state: string;
  readonly firstSeenAt: string;
};

export type VmDriftKind =
  | "provider_missing"
  | "db_running_provider_paused"
  | "db_paused_provider_running"
  | "db_destroyed_provider_present"
  | "provider_untracked";

export type DriftVm = {
  readonly vmId: string;
  readonly kind: VmDriftKind;
  readonly dbStatus: string | null;
  readonly providerState: string | null;
  readonly owner: VmHealthOwner | null;
  readonly dbUpdatedAt: string | null;
  readonly providerUpdatedAt: string | null;
};

export type TlsRuleOwner = VmWorkload | "account_level" | "vpc_unattributed" | "unknown_vm" | "managed";

export type PausedRuleHolder = {
  readonly vmId: string;
  readonly workload: VmWorkload;
  readonly owner: VmHealthOwner | null;
  readonly pausedSince: string;
  readonly rules: number;
};

export type TlsBudget = {
  readonly totalCount: number;
  readonly limit: number;
  readonly listed: number;
  readonly complete: boolean;
  readonly byOwner: Readonly<Record<TlsRuleOwner, number>>;
  readonly pausedOverDays: number;
  readonly pausedHolders: {
    readonly vmCount: number;
    readonly ruleCount: number;
    readonly top: readonly PausedRuleHolder[];
  };
};

export type VmAttentionReason =
  | { readonly code: "hung_vms"; readonly count: number }
  | { readonly code: "stuck_transitions"; readonly count: number }
  | { readonly code: "drift"; readonly count: number }
  | { readonly code: "tls_over_limit"; readonly count: number; readonly limit: number }
  | { readonly code: "tls_near_limit"; readonly count: number; readonly limit: number }
  | { readonly code: "sweep_incomplete"; readonly unprobed: number }
  | { readonly code: "sweep_errors"; readonly count: number };

export type VmHealthSweepError = {
  readonly stage: "previous_snapshot" | "inventory" | "tls_rules" | "db_rows";
  readonly message: string;
};

export type VmHealthCoverage = {
  readonly inventoryComplete: boolean;
  readonly running: number;
  readonly probed: number;
  readonly probeErrors: number;
  readonly skippedBudget: number;
  readonly skippedIdle: number;
  /** Paused or in transition by the time its probe ran; absent on older snapshots. */
  readonly skippedNotRunning?: number;
};

export type VmHealthReport = {
  readonly version: 1;
  readonly generatedAt: string;
  readonly durationMs: number;
  readonly stateCounts: Readonly<Record<string, number>>;
  readonly workloadCounts: Readonly<Record<string, number>>;
  readonly coverage: VmHealthCoverage;
  readonly hung: readonly HungVm[];
  readonly stuck: readonly StuckVm[];
  /** Every provider VM currently starting or pausing; the next sweep carries their first-seen times. */
  readonly transitions: readonly VmTransitionSighting[];
  readonly drift: readonly DriftVm[];
  readonly tls: TlsBudget | null;
  readonly errors: readonly VmHealthSweepError[];
  readonly attention: {
    readonly needed: boolean;
    readonly reasons: readonly VmAttentionReason[];
  };
};

export type StoredVmHealthReport = {
  readonly id: string;
  readonly createdAt: Date;
  readonly report: VmHealthReport;
};
