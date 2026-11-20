import { DEFAULT_FREESTYLE_TLS_RULE_LIMIT } from "../../observability/providerRuleCapacity";
import type {
  DriftVm,
  HungVm,
  PausedRuleHolder,
  ProviderInventoryVm,
  ProviderTlsRuleInventory,
  ProviderTlsRuleRef,
  ProviderVmInventory,
  StuckVm,
  TlsBudget,
  TlsRuleOwner,
  VmAttentionReason,
  VmHealthCoverage,
  VmHealthDbRow,
  VmHealthOwner,
  VmHealthReport,
  VmHealthSweepError,
  VmProbeRecord,
  VmTransitionSighting,
  VmWorkload,
} from "./types";

/** Provider states that are moving between two resting states. */
const PROVIDER_TRANSITION_STATES: ReadonlySet<string> = new Set(["starting", "pausing"]);
/** DB statuses that claim a live provider VM. */
const DB_LIVE_STATUSES: ReadonlySet<string> = new Set(["running", "paused"]);
const MINUTE_MS = 60_000;
const DAY_MS = 24 * 60 * MINUTE_MS;
/** Every list is capped so one bad incident cannot make a snapshot unbounded. */
export const VM_HEALTH_LIST_CAP = 500;
export const VM_HEALTH_PAUSED_HOLDER_CAP = 50;
export const VM_HEALTH_TRANSITION_CAP = 2_000;
const TLS_WARNING_FRACTION = 0.85;

export type VmHealthThresholds = {
  /** A provider transition or DB provisioning row older than this is stuck. */
  readonly stuckAfterMs: number;
  /** Drift younger than this is an in-flight lifecycle call, not drift. */
  readonly driftGraceMs: number;
  /** A VM paused at least this long counts as holding idle TLS rules. */
  readonly pausedRuleHolderAfterMs: number;
  readonly tlsRuleLimit: number;
};

export const DEFAULT_VM_HEALTH_THRESHOLDS: VmHealthThresholds = {
  stuckAfterMs: 15 * MINUTE_MS,
  driftGraceMs: 10 * MINUTE_MS,
  pausedRuleHolderAfterMs: 7 * DAY_MS,
  tlsRuleLimit: DEFAULT_FREESTYLE_TLS_RULE_LIMIT,
};

export type VmHealthClassifierInput = {
  readonly now: Date;
  readonly startedAt: Date;
  readonly inventory: ProviderVmInventory | null;
  readonly tlsRules: ProviderTlsRuleInventory | null;
  readonly dbRows: readonly VmHealthDbRow[];
  readonly probes: readonly VmProbeRecord[];
  /** The previous report's hung VMs, so first-seen time survives across runs. */
  readonly previousHung: readonly Pick<HungVm, "vmId" | "firstSeenHungAt">[];
  /** The previous report's transition sightings (absent on reports written before they existed). */
  readonly previousTransitions?: readonly VmTransitionSighting[];
  readonly errors: readonly VmHealthSweepError[];
  readonly thresholds?: Partial<VmHealthThresholds>;
};

/** The workload a provider VM belongs to on the shared account. */
export function vmWorkload(metadata: Readonly<Record<string, string>>): VmWorkload {
  if (metadata.cmux === "cloud") return "cmux_cloud";
  const app = metadata.app?.trim();
  return app ? `app:${app.slice(0, 63)}` : "other";
}

/** Pure: turn one sweep's observations into the stored report. */
export function classifyVmHealth(input: VmHealthClassifierInput): VmHealthReport {
  const thresholds = { ...DEFAULT_VM_HEALTH_THRESHOLDS, ...input.thresholds };
  const vms = input.inventory?.vms ?? [];
  const vmById = new Map(vms.map((vm) => [vm.id, vm]));
  const rowByProviderId = indexDbRows(input.dbRows);
  const ownerOf = (vmId: string) => ownerFromRow(rowByProviderId.get(vmId));

  const hung = classifyHung(input, vmById, rowByProviderId);
  const transitions = transitionSightings(input.now, vms, input.previousTransitions ?? []);
  const stuck = classifyStuck(input.now, transitions, vms, input.dbRows, thresholds, ownerOf);
  const drift = input.inventory ? classifyDrift(input.now, input.inventory, input.dbRows, rowByProviderId, thresholds) : [];
  const tls = input.tlsRules ? classifyTlsBudget(input.now, input.tlsRules, vms, thresholds, ownerOf) : null;
  const coverage = probeCoverage(input.inventory, input.probes);
  const reasons = attentionReasons({ hung, stuck, drift, tls, coverage, errors: input.errors });

  return {
    version: 1,
    generatedAt: input.now.toISOString(),
    durationMs: Math.max(0, input.now.getTime() - input.startedAt.getTime()),
    stateCounts: countBy(vms, (vm) => vm.state),
    workloadCounts: countBy(vms, (vm) => vmWorkload(vm.metadata)),
    coverage,
    hung: hung.slice(0, VM_HEALTH_LIST_CAP),
    stuck: stuck.slice(0, VM_HEALTH_LIST_CAP),
    transitions: transitions.slice(0, VM_HEALTH_TRANSITION_CAP),
    drift: drift.slice(0, VM_HEALTH_LIST_CAP),
    tls,
    errors: input.errors,
    attention: { needed: reasons.some(isAttentionReason), reasons },
  };
}

function indexDbRows(rows: readonly VmHealthDbRow[]): Map<string, VmHealthDbRow> {
  const byProviderId = new Map<string, VmHealthDbRow>();
  for (const row of rows) {
    const existing = byProviderId.get(row.providerVmId);
    // A provider id can appear on a destroyed row and a live one (a reused
    // id after restore); the live row is the owner that matters.
    if (!existing || (existing.status === "destroyed" && row.status !== "destroyed")) {
      byProviderId.set(row.providerVmId, row);
    }
  }
  return byProviderId;
}

function ownerFromRow(row: VmHealthDbRow | undefined): VmHealthOwner | null {
  if (!row) return null;
  return { cloudVmId: row.id, userId: row.userId, teamId: row.ownerTeamId || null };
}

function classifyHung(
  input: VmHealthClassifierInput,
  vmById: ReadonlyMap<string, ProviderInventoryVm>,
  rowByProviderId: ReadonlyMap<string, VmHealthDbRow>,
): HungVm[] {
  const firstSeen = new Map(input.previousHung.map((entry) => [entry.vmId, entry.firstSeenHungAt]));
  const probeByVm = new Map(input.probes.map((probe) => [probe.vmId, probe]));
  const hung: HungVm[] = [];
  for (const vm of vmById.values()) {
    const detail = hungDetail(probeByVm.get(vm.id), firstSeen.has(vm.id));
    if (detail === null) continue;
    const row = rowByProviderId.get(vm.id);
    hung.push({
      vmId: vm.id,
      workload: vmWorkload(vm.metadata),
      owner: ownerFromRow(row),
      snapshot: vm.snapshot,
      size: { cpu: vm.cpu, memoryMib: vm.memoryMib, storageMib: vm.storageMib },
      firstSeenHungAt: firstSeen.get(vm.id) ?? input.now.toISOString(),
      providerUpdatedAt: vm.updatedAt,
      dbUpdatedAt: row ? row.updatedAt.toISOString() : null,
      detail,
    });
  }
  // Longest-hung first: those are the ones an operator should look at.
  return hung.sort((a, b) => a.firstSeenHungAt.localeCompare(b.firstSeenHungAt) || a.vmId.localeCompare(b.vmId));
}

/**
 * Why a VM counts as hung this sweep, or null. A VM hung last sweep that this
 * sweep could not re-probe (time budget, probe error) stays hung with its
 * first-seen time; only an answer, a pause, or its deletion clears it.
 */
function hungDetail(probe: VmProbeRecord | undefined, wasHung: boolean): string | null {
  if (probe?.outcome === "hung") return probe.detail;
  if (!wasHung) return null;
  if (probe?.outcome === "skipped_budget") return "not re-probed this sweep (time budget)";
  if (probe?.outcome === "error") return `not re-probed this sweep (${probe.detail})`;
  return null;
}

/**
 * When each VM entered its current transition, by the first sweep that saw
 * it there. Provider timestamps are not used: Freestyle refreshes a live VM's
 * `updatedAt` with activity and may not move it when a transition starts, so
 * it could make a fresh transition look days old. Detection lags by at most
 * one sweep.
 */
function transitionSightings(
  now: Date,
  vms: readonly ProviderInventoryVm[],
  previous: readonly VmTransitionSighting[],
): VmTransitionSighting[] {
  const seen = new Map(previous.map((entry) => [`${entry.vmId}:${entry.state}`, entry.firstSeenAt]));
  const sightings: VmTransitionSighting[] = [];
  for (const vm of vms) {
    if (!PROVIDER_TRANSITION_STATES.has(vm.state)) continue;
    sightings.push({ vmId: vm.id, state: vm.state, firstSeenAt: seen.get(`${vm.id}:${vm.state}`) ?? now.toISOString() });
  }
  return sightings;
}

function classifyStuck(
  now: Date,
  transitions: readonly VmTransitionSighting[],
  vms: readonly ProviderInventoryVm[],
  dbRows: readonly VmHealthDbRow[],
  thresholds: VmHealthThresholds,
  ownerOf: (vmId: string) => VmHealthOwner | null,
): StuckVm[] {
  const vmById = new Map(vms.map((vm) => [vm.id, vm]));
  const stuck: StuckVm[] = [];
  for (const sighting of transitions) {
    const ageMs = now.getTime() - Date.parse(sighting.firstSeenAt);
    if (ageMs < thresholds.stuckAfterMs) continue;
    stuck.push({
      vmId: sighting.vmId,
      source: "provider",
      state: sighting.state,
      workload: vmWorkload(vmById.get(sighting.vmId)?.metadata ?? {}),
      owner: ownerOf(sighting.vmId),
      since: sighting.firstSeenAt,
      minutes: Math.floor(ageMs / MINUTE_MS),
    });
  }
  for (const row of dbRows) {
    if (row.status !== "provisioning") continue;
    const ageMs = now.getTime() - row.updatedAt.getTime();
    if (ageMs < thresholds.stuckAfterMs) continue;
    stuck.push({
      vmId: row.providerVmId,
      source: "db",
      state: row.status,
      workload: "cmux_cloud",
      owner: ownerFromRow(row),
      since: row.updatedAt.toISOString(),
      minutes: Math.floor(ageMs / MINUTE_MS),
    });
  }
  return stuck.sort((a, b) => b.minutes - a.minutes || a.vmId.localeCompare(b.vmId));
}

/**
 * DB and provider disagree. Only cmux Cloud machines are compared: other
 * workloads on the account have no DB rows by design. Recent DB changes and
 * new provider VMs are left alone because a lifecycle call may be between its
 * provider call and its row update. The reconcile cron owns repair; this only
 * reports.
 */
function classifyDrift(
  now: Date,
  inventory: ProviderVmInventory,
  dbRows: readonly VmHealthDbRow[],
  rowByProviderId: ReadonlyMap<string, VmHealthDbRow>,
  thresholds: VmHealthThresholds,
): DriftVm[] {
  const vmById = new Map(inventory.vms.map((vm) => [vm.id, vm]));
  const drift: DriftVm[] = [];
  for (const row of dbRows) {
    if (!DB_LIVE_STATUSES.has(row.status)) continue;
    if (now.getTime() - row.updatedAt.getTime() < thresholds.driftGraceMs) continue;
    const vm = vmById.get(row.providerVmId);
    const kind = vm ? liveRowDrift(row.status, vm.state) : inventory.complete ? "provider_missing" : null;
    // A resting VM's `updatedAt` is when it came to rest, so a pause that just
    // landed is still in flight. A running VM's moves with activity: ignore it.
    if (!kind || (vm && vm.state !== "running" && isRecent(now, vm.updatedAt, thresholds.driftGraceMs))) continue;
    drift.push(driftEntry(row, vm, kind));
  }
  for (const vm of inventory.vms) {
    if (vmWorkload(vm.metadata) !== "cmux_cloud" || vm.state === "stopped") continue;
    if (isRecent(now, vm.createdAt, thresholds.driftGraceMs)) continue;
    const row = rowByProviderId.get(vm.id);
    if (row && row.status !== "destroyed") continue;
    if (row && now.getTime() - row.updatedAt.getTime() < thresholds.driftGraceMs) continue;
    drift.push(driftEntry(row, vm, row ? "db_destroyed_provider_present" : "provider_untracked"));
  }
  return drift.sort((a, b) => a.kind.localeCompare(b.kind) || a.vmId.localeCompare(b.vmId));
}

function liveRowDrift(dbStatus: string, providerState: string): DriftVm["kind"] | null {
  const providerResting = providerState === "paused" || providerState === "stopped";
  if (dbStatus === "running" && providerResting) return "db_running_provider_paused";
  if (dbStatus === "paused" && providerState === "running") return "db_paused_provider_running";
  return null;
}

function driftEntry(row: VmHealthDbRow | undefined, vm: ProviderInventoryVm | undefined, kind: DriftVm["kind"]): DriftVm {
  return {
    vmId: vm?.id ?? row?.providerVmId ?? "",
    kind,
    dbStatus: row?.status ?? null,
    providerState: vm?.state ?? null,
    owner: ownerFromRow(row),
    dbUpdatedAt: row ? row.updatedAt.toISOString() : null,
    providerUpdatedAt: vm?.updatedAt ?? null,
  };
}

function classifyTlsBudget(
  now: Date,
  inventory: ProviderTlsRuleInventory,
  vms: readonly ProviderInventoryVm[],
  thresholds: VmHealthThresholds,
  ownerOf: (vmId: string) => VmHealthOwner | null,
): TlsBudget {
  const vmById = new Map(vms.map((vm) => [vm.id, vm]));
  const vpcWorkload = new Map<string, VmWorkload>();
  for (const vm of vms) {
    for (const vpcId of vm.vpcIds) if (!vpcWorkload.has(vpcId)) vpcWorkload.set(vpcId, vmWorkload(vm.metadata));
  }
  const byOwner: Record<string, number> = {};
  const pausedRules = new Map<string, number>();
  for (const rule of inventory.rules) {
    const owner = tlsRuleOwner(rule, vmById, vpcWorkload);
    byOwner[owner] = (byOwner[owner] ?? 0) + 1;
    const holder = pausedHolderOf(now, rule, vmById, thresholds.pausedRuleHolderAfterMs);
    if (holder) pausedRules.set(holder, (pausedRules.get(holder) ?? 0) + 1);
  }
  const holders: PausedRuleHolder[] = [...pausedRules].map(([vmId, rules]) => {
    const vm = vmById.get(vmId)!;
    return { vmId, workload: vmWorkload(vm.metadata), owner: ownerOf(vmId), pausedSince: vm.updatedAt, rules };
  });
  holders.sort((a, b) => b.rules - a.rules || a.pausedSince.localeCompare(b.pausedSince));
  return {
    totalCount: inventory.totalCount,
    limit: thresholds.tlsRuleLimit,
    listed: inventory.rules.length,
    complete: inventory.complete,
    byOwner: byOwner as Record<TlsRuleOwner, number>,
    pausedOverDays: Math.round(thresholds.pausedRuleHolderAfterMs / DAY_MS),
    pausedHolders: {
      vmCount: holders.length,
      ruleCount: holders.reduce((sum, holder) => sum + holder.rules, 0),
      top: holders.slice(0, VM_HEALTH_PAUSED_HOLDER_CAP),
    },
  };
}

/** Who a rule's slot is charged to: the VM it dies with, else its network, else the account. */
export function tlsRuleOwner(
  rule: ProviderTlsRuleRef,
  vmById: ReadonlyMap<string, ProviderInventoryVm>,
  vpcWorkload: ReadonlyMap<string, VmWorkload>,
): TlsRuleOwner {
  if (rule.managed) return "managed";
  if (rule.vmIds.length > 0) {
    const vm = rule.vmIds.map((id) => vmById.get(id)).find((candidate) => candidate !== undefined);
    return vm ? vmWorkload(vm.metadata) : "unknown_vm";
  }
  if (rule.vpcIds.length > 0) {
    const workload = rule.vpcIds.map((id) => vpcWorkload.get(id)).find((candidate) => candidate !== undefined);
    return workload ?? "vpc_unattributed";
  }
  return "account_level";
}

function pausedHolderOf(
  now: Date,
  rule: ProviderTlsRuleRef,
  vmById: ReadonlyMap<string, ProviderInventoryVm>,
  pausedAfterMs: number,
): string | null {
  if (rule.managed) return null;
  for (const vmId of rule.vmIds) {
    const vm = vmById.get(vmId);
    if (!vm || (vm.state !== "paused" && vm.state !== "stopped")) continue;
    const ageMs = ageSince(now, vm.updatedAt);
    if (ageMs !== null && ageMs >= pausedAfterMs) return vm.id;
  }
  return null;
}

function probeCoverage(inventory: ProviderVmInventory | null, probes: readonly VmProbeRecord[]): VmHealthCoverage {
  const counts: Partial<Record<VmProbeRecord["outcome"], number>> = {};
  for (const probe of probes) counts[probe.outcome] = (counts[probe.outcome] ?? 0) + 1;
  const skippedBudget = counts.skipped_budget ?? 0;
  const skippedIdle = counts.skipped_idle ?? 0;
  const skippedNotRunning = counts.not_running ?? 0;
  return {
    inventoryComplete: inventory?.complete ?? false,
    running: inventory?.vms.filter((vm) => vm.state === "running").length ?? 0,
    probed: probes.length - skippedBudget - skippedIdle - skippedNotRunning,
    probeErrors: counts.error ?? 0,
    skippedBudget,
    skippedIdle,
    skippedNotRunning,
  };
}

/**
 * Probe errors (401, 429, a refused state read) say nothing about VMs. A few
 * are noise from a busy shared account; past this share of running VMs the
 * sweep cannot vouch for the fleet.
 */
const PROBE_ERROR_ATTENTION_FRACTION = 0.05;

function unprobedForAttention(coverage: VmHealthCoverage): number {
  const errorsMatter = coverage.probeErrors > Math.max(2, coverage.running * PROBE_ERROR_ATTENTION_FRACTION);
  return coverage.skippedBudget + (errorsMatter ? coverage.probeErrors : 0);
}

function attentionReasons(input: {
  readonly hung: readonly HungVm[];
  readonly stuck: readonly StuckVm[];
  readonly drift: readonly DriftVm[];
  readonly tls: TlsBudget | null;
  readonly coverage: VmHealthCoverage;
  readonly errors: readonly VmHealthSweepError[];
}): VmAttentionReason[] {
  const reasons: VmAttentionReason[] = [];
  if (input.hung.length > 0) reasons.push({ code: "hung_vms", count: input.hung.length });
  if (input.stuck.length > 0) reasons.push({ code: "stuck_transitions", count: input.stuck.length });
  // A cmux-tagged VM with no row here may belong to another environment on
  // the shared account; it is listed, but does not by itself page anyone.
  const drift = input.drift.filter((entry) => entry.kind !== "provider_untracked").length;
  if (drift > 0) reasons.push({ code: "drift", count: drift });
  const tls = input.tls;
  if (tls && tls.totalCount >= tls.limit) {
    reasons.push({ code: "tls_over_limit", count: tls.totalCount, limit: tls.limit });
  } else if (tls && tls.totalCount >= tls.limit * TLS_WARNING_FRACTION) {
    reasons.push({ code: "tls_near_limit", count: tls.totalCount, limit: tls.limit });
  }
  const unprobed = unprobedForAttention(input.coverage);
  if (unprobed > 0 || !input.coverage.inventoryComplete) reasons.push({ code: "sweep_incomplete", unprobed });
  if (input.errors.length > 0) reasons.push({ code: "sweep_errors", count: input.errors.length });
  return reasons;
}

/** A near-limit TLS budget is a warning on the page; it does not by itself need an operator. */
function isAttentionReason(reason: VmAttentionReason): boolean {
  return reason.code !== "tls_near_limit";
}

function countBy<T>(items: readonly T[], key: (item: T) => string): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const item of items) {
    const value = key(item);
    counts[value] = (counts[value] ?? 0) + 1;
  }
  return counts;
}

function ageSince(now: Date, iso: string): number | null {
  const time = Date.parse(iso);
  return Number.isFinite(time) ? now.getTime() - time : null;
}

function isRecent(now: Date, iso: string, windowMs: number): boolean {
  const age = ageSince(now, iso);
  return age !== null && age < windowMs;
}
