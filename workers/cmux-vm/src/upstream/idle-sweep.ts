/**
 * Idle sweep: deletes this environment's staging VMs that have not run for IDLE_DELETE_MS, across every tenant.
 *
 * Leo, 2026-11-27 00:45Z: "why do we have so many staging ones?" Every staging create used `idleTimeoutSeconds: 300`
 * and no `autoDeleteSeconds`, so each VM paused 5 min after its last use and then kept its disk forever: 1,142
 * `cmux-vm-staging-*` VMs at 01:23Z, 1,014 of them paused, none ever deleted. cmux#60081 gives every new staging and
 * preview create a provider `autoDeleteSeconds` of 24 h (src/upstream/live-create.ts autoDeleteFor). This sweep applies the
 * same rule to the VMs that exist: the provider does not report a VM's `autoDeleteSeconds`, so a VM made before that
 * change cannot be told from one made after it, and both are held to the one rule here.
 *
 * A VM is deleted only when all of these hold:
 *  - its metadata says `cmux_env` is this Worker's environment and `cmux_id` is a cmux VM id, and its slug is exactly the
 *    one a create of that id uses (`cmux-vm-<environment>-vm-<id>`): it is ours;
 *  - it is `paused` or `stopped`: a running, starting or pausing VM is never deleted, whatever its age;
 *  - its creation, last update and last network activity are all at least IDLE_DELETE_MS old: nothing has started,
 *    paused, resized or reached it for that long, the provider auto-delete's own "gone this long without running";
 *  - read again by its exact provider id right before the delete, it still meets every rule above (a start since the
 *    listing protects it).
 *
 * Only exact provider ids are deleted, never a slug pattern; the listing is complete before anything is deleted. The
 * ownership row settles as any provider-deleted VM's does (README, "If the provider deleted it first"). It runs only in
 * staging (src/cron-plan.ts): never production, where a user's paused machine is kept.
 */
import { Effect, Schema } from "effect";
import { UpstreamError } from "./client.ts";
import { makeUpstreamHttp } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";
import { orphanSlug } from "./orphan-sweep.ts";

/** How long a VM must have gone without running: cmux#60081's NON_PRODUCTION_AUTO_DELETE_SECONDS, 24 h. */
export const IDLE_DELETE_MS = 24 * 3600 * 1000;
const PAGE_SIZE = 50;
/** 2,000 VMs per run; a larger account is finished by later runs (the report says the listing was cut short). */
const MAX_PAGES = 40;
const CMUX_VM_ID = /^vm_[0-9a-hjkmnp-tv-z]{26}$/u;
const IDLE_STATES: ReadonlySet<string> = new Set(["paused", "stopped"]);

const ListedVm = Schema.Struct({
  id: Schema.String,
  slug: Schema.optional(Schema.NullOr(Schema.String)),
  state: Schema.String,
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.NullOr(Schema.String)),
  lastNetworkActivity: Schema.optional(Schema.NullOr(Schema.String)),
  resources: Schema.optional(Schema.NullOr(Schema.Struct({ cpu: Schema.Number, memory: Schema.Number }))),
  metadata: Schema.optional(Schema.NullOr(Schema.Record({ key: Schema.String, value: Schema.String }))),
});
type ListedVm = Schema.Schema.Type<typeof ListedVm>;
const ListPage = Schema.Struct({ vms: Schema.Array(ListedVm) });

export interface IdleVm {
  readonly upstreamId: string;
  readonly cmuxId: string;
  /** The `cmux_tenant` metadata, when the create recorded one. */
  readonly tenant: string | null;
  readonly state: string;
  /** The latest of created, updated and last network activity: when the VM last did anything. */
  readonly lastUsedAt: string;
}

export interface IdleSweepReport {
  /** VMs of this environment the provider listed. */
  readonly listed: number;
  /** False when the page cap stopped the listing; the rest is swept by a later run. */
  readonly complete: boolean;
  readonly idle: ReadonlyArray<IdleVm>;
  /** Provider ids deleted this run (a 404 counts: the VM is gone). */
  readonly deleted: ReadonlyArray<string>;
  /** Provider ids a re-read found in use again: kept. */
  readonly kept: ReadonlyArray<string>;
  /** Provider ids whose re-read or delete failed; the next run tries again. */
  readonly failed: ReadonlyArray<string>;
}

export interface IdleSweepOptions {
  readonly nowMs: number;
  /** List and report only. */
  readonly dryRun: boolean;
  /**
   * Deletes per run (default 100): each is a re-read and a delete, so a run stays well inside the cron's subrequest
   * budget beside the orphan and tunnel sweeps. A backlog is finished by later runs, every 5 minutes.
   */
  readonly maxDeletes?: number;
}

/** The VM's last use in epoch ms (null when its creation time is unreadable), or null when it is not ours to sweep. */
const idleOf = (environment: string, vm: ListedVm, nowMs: number): IdleVm | null => {
  const metadata = vm.metadata ?? {};
  if (metadata["cmux_env"] !== environment) return null;
  const cmuxId = metadata["cmux_id"];
  if (cmuxId === undefined || !CMUX_VM_ID.test(cmuxId) || vm.slug !== orphanSlug(environment, cmuxId)) return null;
  if (!IDLE_STATES.has(vm.state)) return null;
  const created = Date.parse(vm.createdAt);
  if (!Number.isFinite(created)) return null;
  let last = created;
  for (const at of [vm.updatedAt, vm.lastNetworkActivity]) {
    if (at === undefined || at === null) continue;
    const ms = Date.parse(at);
    // An unreadable time is never read as old.
    if (!Number.isFinite(ms)) return null;
    last = Math.max(last, ms);
  }
  if (nowMs - last < IDLE_DELETE_MS) return null;
  return { upstreamId: vm.id, cmuxId, tenant: metadata["cmux_tenant"] ?? null, state: vm.state, lastUsedAt: new Date(last).toISOString() };
};

export const sweepIdleVms = (config: UpstreamConfig, options: IdleSweepOptions) =>
  Effect.gen(function* () {
    const http = makeUpstreamHttp(config);
    const environment = config.environment;
    // Beside src/cron-plan.ts, its own refusal: no other environment's VM is ever swept for being idle.
    if (environment !== "staging") {
      const none: IdleSweepReport = { listed: 0, complete: true, idle: [], deleted: [], kept: [], failed: [] };
      return none;
    }
    const idle = new Map<string, IdleVm>();
    let listed = 0;
    let complete = false;
    for (let page = 0; page < MAX_PAGES; page += 1) {
      const query = new URLSearchParams({ metadata: `cmux_env:${environment}`, limit: String(PAGE_SIZE), offset: String(page * PAGE_SIZE) });
      const body = yield* http.json("listIdleCandidates", "GET", `/v5/vms?${query.toString()}`).pipe(
        Effect.flatMap(Schema.decodeUnknown(ListPage)),
        Effect.mapError((error) => (error instanceof UpstreamError ? error : new UpstreamError({ operation: "listIdleCandidates", status: null }))),
      );
      for (const vm of body.vms) {
        // The filter is the provider's; the sweep checks it again and never trusts it alone.
        if ((vm.metadata ?? {})["cmux_env"] !== environment) continue;
        listed += 1;
        const found = idleOf(environment, vm, options.nowMs);
        if (found !== null) idle.set(vm.id, found);
      }
      if (body.vms.length < PAGE_SIZE) {
        complete = true;
        break;
      }
    }
    const all = [...idle.values()];
    const deleted: string[] = [];
    const kept: string[] = [];
    const failed: string[] = [];
    if (!options.dryRun) {
      for (const vm of all.slice(0, options.maxDeletes ?? 100)) {
        // Read again right before the delete: a VM started since the listing is kept.
        const now = yield* Effect.either(
          http.json("readIdleCandidate", "GET", `/v5/vms/${encodeURIComponent(vm.upstreamId)}`).pipe(Effect.flatMap(Schema.decodeUnknown(ListedVm))),
        );
        if (now._tag === "Left") {
          failed.push(vm.upstreamId);
          continue;
        }
        const still = idleOf(environment, now.right, options.nowMs);
        if (still === null || still.cmuxId !== vm.cmuxId) {
          kept.push(vm.upstreamId);
          continue;
        }
        const outcome = yield* Effect.either(
          http.json("deleteIdleVm", "DELETE", `/v5/vms/${encodeURIComponent(vm.upstreamId)}`).pipe(
            Effect.catchAll((error) => (error.status === 404 ? Effect.void : Effect.fail(error))),
          ),
        );
        (outcome._tag === "Right" ? deleted : failed).push(vm.upstreamId);
      }
    }
    const report: IdleSweepReport = { listed, complete, idle: all, deleted, kept, failed };
    return report;
  });
