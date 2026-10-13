import type { Freestyle, TlsRuleData, VmData } from "freestyle";
import type {
  ProviderInventoryVm,
  ProviderTlsRuleInventory,
  ProviderTlsRuleRef,
  ProviderVmInventory,
  VmControlProbe,
} from "../health/types";
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
const DETAIL_MAX_LENGTH = 200;

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
      return { vms, complete: true };
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
  let totalCount = 0;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    if (Date.now() >= options.deadlineAtMs) return { totalCount, rules, complete: false };
    const result = await client(LIST_REQUEST_TIMEOUT_MS, options.signal).tls.rules.list({ limit: PAGE_SIZE, offset: page * PAGE_SIZE });
    totalCount = result.totalCount;
    rules.push(...result.rules.map(tlsRuleRef));
    if (result.rules.length < PAGE_SIZE || rules.length >= totalCount) {
      return { totalCount, rules, complete: true };
    }
  }
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

async function probeControl(
  client: ClientFactory,
  vmId: string,
  options: { readonly timeoutMs: number; readonly signal?: AbortSignal },
): Promise<VmControlProbe> {
  const started = Date.now();
  const timeout = AbortSignal.timeout(options.timeoutMs);
  const signal = options.signal ? AbortSignal.any([options.signal, timeout]) : timeout;
  let response: Response;
  try {
    response = await client(options.timeoutMs, signal).fetch(
      `/v5/vms/${encodeURIComponent(vmId)}/fs/stat?path=${encodeURIComponent("/")}`,
      { method: "GET", signal },
    );
  } catch (error) {
    const latencyMs = Date.now() - started;
    if (timeout.aborted) return { outcome: "hung", latencyMs, detail: `timeout after ${options.timeoutMs}ms` };
    return { outcome: "error", latencyMs, detail: sanitizeDetail(error instanceof Error ? error.name : "fetch_failed") };
  }
  const latencyMs = Date.now() - started;
  if (response.ok) {
    await response.body?.cancel().catch(() => undefined);
    return { outcome: "ok", latencyMs };
  }
  if (response.status === 404) return { outcome: "gone", latencyMs };
  const detail = await errorDetail(response);
  // 409 is the stale-runtime conflict seen in the incident; 5xx and 504 are a
  // provider that took the request and could not reach the VM. 401, 403 and
  // 429 say nothing about the VM, so they are probe errors, not hangs.
  if (response.status === 409 || response.status >= 500) return { outcome: "hung", latencyMs, detail };
  return { outcome: "error", latencyMs, detail };
}

async function errorDetail(response: Response): Promise<string> {
  const body: unknown = await response.json().catch(() => null);
  const record = body && typeof body === "object" ? body as Record<string, unknown> : {};
  const code = typeof record.code === "string" ? record.code : "";
  const message = typeof record.message === "string" ? record.message : "";
  return sanitizeDetail([`${response.status}`, code, message].filter(Boolean).join(" "));
}

/** Provider prose only, bounded, with anything token-shaped removed. */
export function sanitizeDetail(text: string): string {
  return text
    .replace(/\b(bearer|token|key|secret)[=:\s]+\S+/gi, "$1=[redacted]")
    .replace(/\b[A-Za-z0-9_-]{32,}\b/g, "[redacted]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, DETAIL_MAX_LENGTH);
}

function finiteOrNull(value: number | null | undefined): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
