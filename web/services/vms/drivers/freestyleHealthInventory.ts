import type { Freestyle, TlsRuleData, VmData } from "freestyle";
import type {
  ProviderInventoryVm,
  ProviderTlsRuleInventory,
  ProviderTlsRuleRef,
  ProviderVmInventory,
  VmControlProbe,
} from "../health/types";
import { sanitizeDetail } from "../health/sanitize";
import type { VmHealthInventory } from "./types";

/**
 * Read-only account inventory for the staff health sweep. Nothing here
 * starts, pauses, updates, or deletes a VM or rule: the listing calls are
 * plain GETs, and the probe is one raw `fs/stat` of `/` with no background
 * polling and no retry, so a hung VM costs exactly one bounded request.
 */
const PAGE_SIZE = 100;
/** 50 pages covers 5000 VMs or rules; past that the listing reports itself partial. */
const MAX_PAGES = 50;
const LIST_REQUEST_TIMEOUT_MS = 20_000;

type ClientFactory = (timeoutMs?: number, signal?: AbortSignal) => Freestyle;

export function freestyleHealthInventory(client: ClientFactory): VmHealthInventory {
  return {
    listAccountVms: (options) => listAccountVms(client, options),
    listAccountTlsRules: (options) => listAccountTlsRules(client, options),
    probeControl: (vmId, options) => probeControl(client, vmId, options),
  };
}

type ListOptions = { readonly deadlineAtMs: number; readonly signal?: AbortSignal };

async function listAccountVms(client: ClientFactory, options: ListOptions): Promise<ProviderVmInventory> {
  const vms: ProviderInventoryVm[] = [];
  const seen = new Set<string>();
  for (let page = 0; page < MAX_PAGES; page += 1) {
    if (Date.now() >= options.deadlineAtMs) return { vms, complete: false };
    const result = await client(LIST_REQUEST_TIMEOUT_MS, options.signal).vms.list({ limit: PAGE_SIZE, offset: page * PAGE_SIZE });
    for (const vm of result.vms) {
      // Offset paging over a changing list can repeat a VM across pages.
      if (seen.has(vm.id)) continue;
      seen.add(vm.id);
      vms.push(inventoryVm(vm));
    }
    if (result.vms.length < PAGE_SIZE || (page + 1) * PAGE_SIZE >= result.totalCount) {
      // A delete during offset paging shifts a VM onto a page already read;
      // a short count means some VM was never seen, so missing is unknown.
      return { vms, complete: seen.size >= result.totalCount };
    }
  }
  return { vms, complete: false };
}

export function inventoryVm(vm: VmData): ProviderInventoryVm {
  return {
    id: vm.id,
    state: vm.state,
    metadata: { ...(vm.metadata ?? {}) },
    snapshot: vm.sourceSnapshotSlug ?? vm.sourceSnapshotSlugAtCreate ?? vm.snapshotId ?? null,
    cpu: finiteOrNull(vm.resources?.cpu),
    memoryMib: finiteOrNull(vm.resources?.memory),
    storageMib: finiteOrNull(vm.resources?.storage),
    idleTimeoutSeconds: finiteOrNull(vm.idleTimeoutSeconds),
    vpcIds: (vm.vpcs ?? []).map((network) => network.vpcId ?? network.vpc).filter((id): id is string => Boolean(id)),
    createdAt: vm.createdAt,
    updatedAt: vm.updatedAt,
  };
}

async function listAccountTlsRules(client: ClientFactory, options: ListOptions): Promise<ProviderTlsRuleInventory> {
  const rules: ProviderTlsRuleRef[] = [];
  const seen = new Set<string>();
  let totalCount: number | null = null;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    if (Date.now() >= options.deadlineAtMs) break;
    const result = await client(LIST_REQUEST_TIMEOUT_MS, options.signal).tls.rules.list({ limit: PAGE_SIZE, offset: page * PAGE_SIZE });
    totalCount = result.totalCount;
    for (const rule of result.rules) {
      // Newest-first paging repeats a rule when one is created mid-walk.
      if (seen.has(rule.id)) continue;
      seen.add(rule.id);
      rules.push(tlsRuleRef(rule));
    }
    if (result.rules.length < PAGE_SIZE || (page + 1) * PAGE_SIZE >= result.totalCount) {
      return { totalCount: result.totalCount, rules, complete: seen.size >= result.totalCount };
    }
  }
  // No page at all is a failed read, not an account with zero rules.
  if (totalCount === null) throw new Error("TLS rule listing ran out of time before its first page");
  return { totalCount, rules, complete: false };
}

/** The ids a rule dies with or names. Domain, transform and auth config never leave this function. */
export function tlsRuleRef(rule: TlsRuleData): ProviderTlsRuleRef {
  const vmIds = new Set<string>();
  const vpcIds = new Set<string>();
  for (const dependency of rule.dependencies ?? []) {
    if (dependency.kind === "vm") vmIds.add(dependency.id);
    else if (dependency.kind === "vpc") vpcIds.add(dependency.id);
  }
  for (const endpoint of [rule.source, rule.destination]) {
    if (endpoint?.vmId) vmIds.add(endpoint.vmId);
    if (endpoint?.vpcId) vpcIds.add(endpoint.vpcId);
  }
  return { id: rule.id, managed: rule.managed === true, vmIds: [...vmIds], vpcIds: [...vpcIds] };
}

/**
 * One bounded control-path probe. The VM's state is re-read first with a plain
 * GET that never wakes it: the inventory can be minutes old by the time a
 * probe runs, and a file system call on a VM paused since then would resume
 * it. A failed state read is a probe error (the API, not the VM, is in
 * trouble), so a provider outage is never reported as a fleet of hung VMs.
 */
async function probeControl(
  client: ClientFactory,
  vmId: string,
  options: { readonly timeoutMs: number; readonly signal?: AbortSignal },
): Promise<VmControlProbe> {
  const started = Date.now();
  const timeout = AbortSignal.timeout(options.timeoutMs);
  const signal = options.signal ? AbortSignal.any([options.signal, timeout]) : timeout;
  const api = client(options.timeoutMs, signal);
  const elapsed = () => Date.now() - started;
  let stateResponse: Response;
  try {
    stateResponse = await api.fetch(`/v5/vms/${encodeURIComponent(vmId)}`, { method: "GET", signal });
  } catch (error) {
    return { outcome: "error", latencyMs: elapsed(), detail: sanitizeDetail(`state read: ${timeout.aborted ? "timeout" : errorName(error)}`) };
  }
  if (stateResponse.status === 404) return { outcome: "gone", latencyMs: elapsed() };
  if (!stateResponse.ok) return { outcome: "error", latencyMs: elapsed(), detail: `state read: ${await errorDetail(stateResponse)}` };
  const state = await stateResponse.json().then((body: unknown) => (body as { state?: unknown })?.state).catch(() => undefined);
  // Only a known state skips the probe; an unreadable body says nothing about the VM.
  if (typeof state !== "string") return { outcome: "error", latencyMs: elapsed(), detail: "state read: unreadable body" };
  if (state !== "running") return { outcome: "not_running", latencyMs: elapsed() };
  let response: Response;
  try {
    response = await api.fetch(`/v5/vms/${encodeURIComponent(vmId)}/fs/stat?path=${encodeURIComponent("/")}`, { method: "GET", signal });
  } catch (error) {
    if (timeout.aborted) return { outcome: "hung", latencyMs: elapsed(), detail: `timeout after ${options.timeoutMs}ms` };
    return { outcome: "error", latencyMs: elapsed(), detail: sanitizeDetail(errorName(error)) };
  }
  if (response.ok) {
    await response.body?.cancel().catch(() => undefined);
    return { outcome: "ok", latencyMs: elapsed() };
  }
  if (response.status === 404) return { outcome: "gone", latencyMs: elapsed() };
  const detail = await errorDetail(response);
  // 409 is the stale-runtime conflict seen in the incident; 5xx is a provider
  // that reached for the VM and could not get an answer. 401, 403 and 429 say
  // nothing about the VM, so they are probe errors, not hangs.
  if (response.status === 409 || response.status >= 500) return { outcome: "hung", latencyMs: elapsed(), detail };
  return { outcome: "error", latencyMs: elapsed(), detail };
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : "fetch_failed";
}

async function errorDetail(response: Response): Promise<string> {
  const body: unknown = await response.json().catch(() => null);
  const record = body && typeof body === "object" ? body as Record<string, unknown> : {};
  const code = typeof record.code === "string" ? record.code : "";
  const message = typeof record.message === "string" ? record.message : "";
  return sanitizeDetail([`${response.status}`, code, message].filter(Boolean).join(" "));
}

function finiteOrNull(value: number | null | undefined): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
