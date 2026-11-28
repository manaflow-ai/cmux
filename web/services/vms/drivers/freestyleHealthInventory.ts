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
/** Keep account inventory quick without turning a health sweep into a request burst. */
const VM_PAGE_CONCURRENCY = 4;
const LIST_REQUEST_TIMEOUT_MS = 20_000;

type ClientFactory = (timeoutMs?: number, signal?: AbortSignal) => Freestyle;
type ProbeOptions = { readonly timeoutMs: number; readonly signal?: AbortSignal };

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
  if (Date.now() >= options.deadlineAtMs) return { vms, complete: false };

  // Read the first page alone: it supplies the account count that bounds the
  // remaining requests. Subsequent pages are independent offset reads, so a
  // small batch cuts wall time while the set de-duplication keeps a changing
  // inventory conservative.
  const readPage = (page: number) => client(LIST_REQUEST_TIMEOUT_MS, options.signal).vms.list({
    limit: PAGE_SIZE,
    offset: page * PAGE_SIZE,
  });
  const first = await readPage(0);
  const add = (result: Awaited<ReturnType<typeof readPage>>) => {
    for (const vm of result.vms) {
      // Offset paging over a changing list can repeat a VM across pages.
      if (seen.has(vm.id)) continue;
      seen.add(vm.id);
      vms.push(inventoryVm(vm));
    }
  };
  add(first);
  let totalCount = first.totalCount;
  let shortPage = first.vms.length < PAGE_SIZE;
  let nextPage = 1;
  while (!shortPage && totalCount > nextPage * PAGE_SIZE && nextPage < MAX_PAGES) {
    if (Date.now() >= options.deadlineAtMs) return { vms, complete: false };
    const pages = Array.from({ length: Math.min(VM_PAGE_CONCURRENCY, MAX_PAGES - nextPage) }, (_, index) => nextPage + index)
      .filter((page) => page * PAGE_SIZE < totalCount);
    if (pages.length === 0) break;
    const results = await Promise.all(pages.map(readPage));
    for (const result of results) {
      add(result);
      totalCount = Math.max(totalCount, result.totalCount);
      shortPage ||= result.vms.length < PAGE_SIZE;
    }
    nextPage += pages.length;
  }
  // A delete during offset paging shifts a VM onto a page already read; a
  // short count means some VM was never seen, so missing is unknown.
  return { vms, complete: nextPage * PAGE_SIZE >= totalCount && seen.size >= totalCount };
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
  options: ProbeOptions,
): Promise<VmControlProbe> {
  const started = Date.now();
  const stateTimeout = AbortSignal.timeout(options.timeoutMs);
  const stateSignal = options.signal ? AbortSignal.any([options.signal, stateTimeout]) : stateTimeout;
  const elapsed = () => Date.now() - started;
  let stateResponse: Response;
  try {
    stateResponse = await client(options.timeoutMs, stateSignal).fetch(`/v5/vms/${encodeURIComponent(vmId)}`, { method: "GET", signal: stateSignal });
  } catch (error) {
    return { outcome: "error", latencyMs: elapsed(), detail: sanitizeDetail(`state read: ${stateTimeout.aborted ? "timeout" : errorName(error)}`) };
  }
  if (stateResponse.status === 404) return { outcome: "gone", latencyMs: elapsed() };
  if (!stateResponse.ok) return { outcome: "error", latencyMs: elapsed(), detail: `state read: ${(await probeErrorResponse(stateResponse)).detail}` };
  const state = await stateResponse.json().then((body: unknown) => (body as { state?: unknown })?.state).catch(() => undefined);
  // Only a known state skips the probe; an unreadable body says nothing about the VM.
  if (typeof state !== "string") return { outcome: "error", latencyMs: elapsed(), detail: "state read: unreadable body" };
  if (state !== "running") return { outcome: "not_running", latencyMs: elapsed() };
  // The VM gets its full response window after the provider confirms it is running.
  if (stateSignal.aborted) return { outcome: "error", latencyMs: elapsed(), detail: "state read: interrupted" };
  return probeGuestFilesystem(client, vmId, options, elapsed);
}

async function probeGuestFilesystem(
  client: ClientFactory,
  vmId: string,
  options: ProbeOptions,
  elapsed: () => number,
): Promise<VmControlProbe> {
  const guestTimeout = AbortSignal.timeout(options.timeoutMs);
  const signal = options.signal ? AbortSignal.any([options.signal, guestTimeout]) : guestTimeout;
  let response: Response;
  try {
    response = await client(options.timeoutMs, signal).fetch(`/v5/vms/${encodeURIComponent(vmId)}/fs/stat?path=${encodeURIComponent("/")}`, { method: "GET", signal });
  } catch (error) {
    // A local deadline cannot tell whether the provider delivered this request to the guest.
    const detail = guestTimeout.aborted ? "fs/stat: request timed out" : sanitizeDetail(errorName(error));
    return { outcome: "error", latencyMs: elapsed(), detail };
  }
  if (response.ok) {
    await response.body?.cancel().catch(() => undefined);
    return { outcome: "ok", latencyMs: elapsed() };
  }
  if (response.status === 404) return { outcome: "gone", latencyMs: elapsed() };
  const { detail, guestUnresponsive } = await probeErrorResponse(response);
  return { outcome: guestUnresponsive ? "hung" : "error", latencyMs: elapsed(), detail };
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : "fetch_failed";
}

async function probeErrorResponse(response: Response): Promise<{ detail: string; guestUnresponsive: boolean }> {
  const body: unknown = await response.json().catch(() => null);
  const record = body && typeof body === "object" ? body as Record<string, unknown> : {};
  const code = typeof record.code === "string" ? record.code : "";
  const message = typeof record.message === "string" ? record.message : "";
  // Gate on a guest-specific error. Capacity conflicts and provider or proxy outages also use 409 and 5xx.
  const guestUnresponsive = ((response.status === 409 || response.status >= 500) && code === "VM_NON_RESPONSIVE")
    || (response.status === 409 && code === "CONFLICT" && /\bstale runtime instance\b.*\bresponsive=false\b/i.test(message));
  return { detail: sanitizeDetail([`${response.status}`, code, message].filter(Boolean).join(" ")), guestUnresponsive };
}

function finiteOrNull(value: number | null | undefined): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
