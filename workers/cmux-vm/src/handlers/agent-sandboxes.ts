/**
 * The rules that make an agent key's sandboxes its own: the labels every VM it
 * creates gets, its live-VM and $/h budget, and revoking a VM's client sessions
 * when the VM goes. Shared by the VM handlers, the agent handlers and the reaper.
 */
import type { Named } from "@gdp-ts/core";
import { Clock, Effect } from "effect";
import { MAX_LABELS, type CreateVmRequest } from "../api.ts";
import { AgentStore } from "../db/agents.ts";
import { OwnershipStore, type PagePosition } from "../db/stores.ts";
import { estimatedSpendUsd, estimatedUsdPerHour, sizeOfCreate, spendWindows, type AgentBudget, type SpendSpan } from "../domain/agents.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import { badRequest, Forbidden, QuotaExceeded, unavailable } from "../errors.ts";
import type { TenantId } from "../lib/ids.ts";
import { CREATE_SEND_GRACE_MS } from "../limits/ledger.ts";
import { TenantLimits } from "../limits/service.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { visitOwnedVms, type OwnedVmPage } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient, type SizeRequest, type UpstreamVm } from "../upstream/client.ts";

const describeLabels = (labels: Readonly<Record<string, string>>) =>
  Object.entries(labels)
    .map(([key, value]) => `${key}=${value}`)
    .join(", ");

/** An agent key's create, with its labels added; a label that names another agent (or drops the issuer's) is 403. */
export const withAgentLabels = (principal: Principal, requested: CreateVmRequest) =>
  Effect.gen(function* () {
    const required = principal.requiredLabels;
    if (principal.agent === undefined || required === undefined) return requested;
    const asked = requested.labels ?? {};
    if (Object.entries(required).some(([key, value]) => key in asked && asked[key] !== value)) {
      return yield* Effect.fail(new Forbidden({ message: `This agent key creates only VMs labelled ${describeLabels(required)}` }));
    }
    const labels = { ...asked, ...required };
    if (Object.keys(labels).length > MAX_LABELS) {
      return yield* Effect.fail(badRequest(`An agent's VM carries ${Object.keys(required).length} labels of its own; ask for at most ${MAX_LABELS - Object.keys(required).length}`));
    }
    const merged: CreateVmRequest = { ...requested, labels };
    return merged;
  });

/**
 * A caller on a run cap (a CI trust row) creates only VMs that pause within the cap and are deleted as soon as they
 * stop: a smaller run cap it asks for stands, no cap or a longer one becomes the cap, and auto-delete is always 0.
 */
/**
 * A caller on a run cap (a CI trust row) creates VMs only at the default or an approved image's size: it cannot ask
 * for resources, cannot boot a tenant snapshot (whose size it would not know), and cannot resize (resize.ts). Its spend is then at most maxVms VMs of a size the operator chose, and the team
 * quota (maxVms) is admitted atomically, so concurrent creates cannot pass the read-then-create budget check together.
 */
export const ciSizeAllowed = (principal: Principal, requested: Pick<CreateVmRequest, "resources" | "snapshotId">) =>
  principal.maxRunSeconds !== undefined && (requested.resources !== undefined || requested.snapshotId !== undefined)
    ? Effect.fail(new Forbidden({ message: "A CI job creates VMs from the base or an approved image at its own size; omit resources and snapshotId" }))
    : Effect.void;

export const withRunCap = (principal: Principal, requested: CreateVmRequest): CreateVmRequest => {
  const cap = principal.maxRunSeconds;
  if (cap === undefined) return requested;
  const asked = requested.maxRunSeconds;
  return { ...requested, maxRunSeconds: asked !== undefined && asked > 0 && asked < cap ? asked : cap, autoDeleteSeconds: 0 };
};

/**
 * The refusal of a create past the live-VM cap, naming the holder, the cap and the current count. Paused VMs count
 * (they are live and resume without a create), so resuming one never passes a cap a create would not.
 */
const overVmCap = (budget: AgentBudget, live: number) =>
  new QuotaExceeded({
    message: `This ${budget.holder ?? "agent key"} has ${live} live VMs, at its maxVms cap of ${budget.maxVms}; delete one, or resume a paused one instead of creating`,
    budget: "agent_vms",
  });

/**
 * Whether one more VM of `size` fits the agent key's budget: fewer live VMs than
 * maxVms, and the estimated USD/h of the live ones (as the provider reports their
 * size) plus the new one at most maxUsdPerHour. The live-VM count is then admitted
 * atomically as an agent slot (limits/agent-slots.ts): the team's VM quota is no
 * longer the bound (a paid team has no machine count), so the slot is. Answers the
 * slot to settle once the create ends (`settleAgentCreate`); undefined when the
 * caller has no agent budget.
 */
export const agentBudgetAllows = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, size: SizeRequest | undefined) =>
  Effect.gen(function* () {
    const budget = caller.value.agent;
    if (budget === undefined) return undefined;
    const capped = budget.maxRunningVms !== undefined || budget.maxUsdPerDay !== undefined || budget.maxUsdPerMonth !== undefined;
    const page = yield* liveBudgetVms(caller, scope, budget, capped);
    if (page.results.length >= budget.maxVms) return yield* Effect.fail(overVmCap(budget, page.results.length));
    // The new VM runs and costs from now: it must fit the running cap and the spend caps too.
    yield* runningAndSpendAllow(caller.value, budget, page.results, 1);
    const next = sizeOfCreate(size);
    const total = page.results.reduce((sum, vm) => sum + vm.usdPerHour, 0) + estimatedUsdPerHour(next.vcpus, next.memoryMib);
    if (total > budget.maxUsdPerHour + 1e-9) {
      return yield* Effect.fail(
        new QuotaExceeded({
          message: `This VM would bring the ${budget.holder ?? "agent key"}'s estimated cost to ${total.toFixed(2)} USD/h, over its maxUsdPerHour cap of ${budget.maxUsdPerHour} USD/h`,
          budget: "agent_usd_per_hour",
        }),
      );
    }
    // Admission is atomic in the tenant ledger (limits/agent-slots.ts): it counts, in one transaction, the VMs the
    // ownership table answers for this key (read here, with no provider calls) together with the creates and the
    // just-recorded VMs its slots hold, so concurrent creates cannot pass at maxVms - 1.
    const owned = yield* visitOwnedVms(caller, { limit: budget.maxVms + 1, after: null, labels: null }, (vm) => Effect.succeed(vm.value))
      .pipe(Effect.catchTag("StoreError", (error) => Effect.fail(unavailable(error))));
    const agent = agentSlotOwner(caller.value);
    const slotId = crypto.randomUUID();
    // A run-capped key's VMs are paused and deleted upstream within the cap, so a slot held for a create that may
    // exist lapses after it (plus the send grace), not after the 25 h a long-lived key's create may live.
    const runCap = caller.value.maxRunSeconds;
    const heldBoundMs = runCap === undefined ? undefined : runCap * 1000 + CREATE_SEND_GRACE_MS;
    const admitted = yield* (yield* TenantLimits)
      .admitAgentSlot(caller.value.tenantId, agent, budget.maxVms, owned.results, slotId, heldBoundMs)
      .pipe(Effect.mapError(unavailable));
    // Lost a race to a concurrent create: its slot fills the cap.
    if (!admitted) return yield* Effect.fail(overVmCap(budget, budget.maxVms));
    return { agent, slotId };
  });

/** One live VM of a budgeted key, as its caps count it. */
interface BudgetVm {
  readonly usdPerHour: number;
  /** Running or booting: it counts against maxRunningVms. */
  readonly running: boolean;
  readonly span: SpendSpan;
}

/** Paused, stopped or gone: not running, and costing nothing now. */
const idleStates = new Set(["paused", "pausing", "stopped", "stopping"]);

const budgetVmOf = (found: UpstreamVm, createdAt: Date): BudgetVm => {
  const usdPerHour = estimatedUsdPerHour(found.resources.cpu, found.resources.memory);
  const running = !idleStates.has(found.state);
  // A paused or stopped VM's last change is (at latest) its pause: it has cost nothing since. A later change only
  // moves the end later, so the estimate errs high.
  const updated = Date.parse(found.updatedAt);
  const toMs = running ? null : Math.max(createdAt.getTime(), Number.isFinite(updated) ? updated : createdAt.getTime());
  return { usdPerHour, running, span: { usdPerHour, fromMs: createdAt.getTime(), toMs } };
};

/**
 * The key's live VMs, each with its size, whether it runs, and its span for the spend estimate: the newest maxVms + 1
 * when `all` is false (enough to refuse a create over maxVms), else every one, page by page, so an older running VM
 * is counted after maxVms was lowered. A VM gone at the provider (404) does not run; it is priced at the default size
 * from its create to now, since it may have run until it vanished.
 */
const liveBudgetVms = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, budget: AgentBudget, all: boolean) =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    const nowMs = yield* Clock.currentTimeMillis;
    const base = sizeOfCreate(undefined);
    const baseUsdPerHour = estimatedUsdPerHour(base.vcpus, base.memoryMib);
    const limit = all ? LIVE_PAGE : budget.maxVms + 1;
    const results: Array<BudgetVm> = [];
    let after: PagePosition | null = null;
    for (let pages = 0; ; pages++) {
      if (pages === LIVE_PAGES) {
        // Past this many VMs the caps cannot be counted: refuse, naming what was counted, rather than pass blind.
        return yield* Effect.fail(
          new QuotaExceeded({
            message: `This ${budget.holder ?? "agent key"} has more than ${results.length} live VMs, too many to count against its running and spend caps; delete some first`,
            budget: "agent_running_vms",
          }),
        );
      }
      const page: OwnedVmPage<BudgetVm> = yield* visitOwnedVms(caller, { limit, after, labels: null }, (vm, owns, row) =>
        upstream.getVmForWrite(vm, { owns, scope }).pipe(
          Effect.map((found) => budgetVmOf(found, row.createdAt)),
          Effect.catchAll((error) =>
            error.status === 404
              ? Effect.succeed<BudgetVm>({ usdPerHour: 0, running: false, span: { usdPerHour: baseUsdPerHour, fromMs: row.createdAt.getTime(), toMs: nowMs } })
              : Effect.fail(unavailable(error)),
          ),
        ),
      ).pipe(Effect.catchTag("StoreError", (error) => Effect.fail(unavailable(error))));
      results.push(...page.results);
      if (!all || page.fetched < limit || page.last === null) return { results };
      after = page.last;
    }
  });

/** Rows per page, and pages, read when every live VM must be counted (5000 VMs, ten times the largest maxVms). */
const LIVE_PAGE = 500;
const LIVE_PAGES = 10;

const usd = (value: number) => value.toFixed(2);

/**
 * The running cap and the spend caps, for `starting` more VMs to run (1 for a create, a start or a resume): fewer than
 * maxRunningVms running now, and the key's estimated spend this UTC day and month under maxUsdPerDay and
 * maxUsdPerMonth. Spend counts the live VMs (`live`) and the VMs deleted this month, each at its list price for its
 * time in the window (domain/agents.ts estimatedSpendUsd). A deleted VM is priced at the default size. Each refusal
 * names the holder, the cap and its current value. Read, then act: two concurrent starts can pass at the cap together.
 */
const runningAndSpendAllow = (principal: Principal, budget: AgentBudget, live: ReadonlyArray<BudgetVm>, starting: number) =>
  Effect.gen(function* () {
    const holder = budget.holder ?? "agent key";
    if (budget.maxRunningVms !== undefined) {
      const running = live.filter((vm) => vm.running).length;
      if (running + starting > budget.maxRunningVms) {
        return yield* Effect.fail(
          new QuotaExceeded({
            message: `This ${holder} has ${running} running VMs, at its maxRunningVms cap of ${budget.maxRunningVms}; pause or stop one first`,
            budget: "agent_running_vms",
          }),
        );
      }
    }
    if (budget.maxUsdPerDay === undefined && budget.maxUsdPerMonth === undefined) return;
    const nowMs = yield* Clock.currentTimeMillis;
    const { dayStartMs, monthStartMs } = spendWindows(nowMs);
    const labels = principal.requiredLabels ?? {};
    const store = yield* OwnershipStore;
    const base = sizeOfCreate(undefined);
    const baseUsdPerHour = estimatedUsdPerHour(base.vcpus, base.memoryMib);
    const spans: ReadonlyArray<SpendSpan> = live.map((vm) => vm.span);
    const caps = [
      { cap: budget.maxUsdPerDay, since: dayStartMs, name: "maxUsdPerDay", period: "today (UTC)", tag: "agent_usd_per_day" as const },
      { cap: budget.maxUsdPerMonth, since: monthStartMs, name: "maxUsdPerMonth", period: "this month (UTC)", tag: "agent_usd_per_month" as const },
    ];
    for (const { cap, since, name, period, tag } of caps) {
      if (cap === undefined) continue;
      const deletedSeconds = yield* store.deletedVmSecondsSince(principal.tenantId, labels, new Date(since)).pipe(Effect.mapError(unavailable));
      const spent = estimatedSpendUsd(spans, since, nowMs) + (baseUsdPerHour * deletedSeconds) / 3600;
      if (spent >= cap) {
        return yield* Effect.fail(
          new QuotaExceeded({
            message: `This ${holder} has spent an estimated ${usd(spent)} USD ${period}, at its ${name} cap of ${cap} USD; it resets at the next UTC ${name === "maxUsdPerDay" ? "day" : "month"}`,
            budget: tag,
          }),
        );
      }
    }
  });

/**
 * A start or resume by a budgeted key (a team key) of a VM that is not running: it must fit the key's running cap and
 * spend caps, as a create does. `current` reads the VM's state; a key with none of those caps set passes without it,
 * and a VM already running passes.
 */
export const agentStartAllows = <C, E, R>(
  caller: Named<C, Principal>,
  scope: KeyHasScope<C, "vm:write">,
  current: Effect.Effect<UpstreamVm, E, R>,
) =>
  Effect.gen(function* () {
    const budget = caller.value.agent;
    if (budget === undefined) return;
    if (budget.maxRunningVms === undefined && budget.maxUsdPerDay === undefined && budget.maxUsdPerMonth === undefined) return;
    if (!idleStates.has((yield* current).state)) return;
    const page = yield* liveBudgetVms(caller, scope, budget, true);
    yield* runningAndSpendAllow(caller.value, budget, page.results, 1);
  });

/** Whose live-VM budget an agent slot counts against: one per key (or CI trust row). */
export const agentSlotOwner = (principal: Principal): string => actorRef(principal.actor);

/** Revokes every live client session of a VM (deleting each provider identity); how many were revoked. */
export const revokeVmClientSessions = (tenantId: TenantId, vmId: string) =>
  Effect.gen(function* () {
    const agents = yield* AgentStore;
    const upstream = yield* UpstreamClient;
    const sessions = yield* agents.liveClientSessions(tenantId, vmId).pipe(Effect.mapError(unavailable));
    let revoked = 0;
    for (const session of sessions) {
      yield* upstream.deleteIdentity(session.upstreamIdentityId).pipe(Effect.mapError(unavailable));
      const at = new Date(yield* Clock.currentTimeMillis);
      yield* agents.markClientSessionRevoked(tenantId, session.id, at).pipe(Effect.mapError(unavailable));
      revoked += 1;
    }
    return revoked;
  });
