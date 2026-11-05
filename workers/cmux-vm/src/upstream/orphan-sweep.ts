/**
 * Orphan sweep (cmux#35013): deletes provider VMs this environment made that no ownership row records.
 *
 * A create makes the VM at the provider first and records its ownership row after. Whenever that second step never
 * happens (the receipt check failed, the database write failed, the Worker died in between), the VM runs and bills
 * with nothing that lists, pauses or reaps it. Until cmux#35012 every production create from a product team did this.
 *
 * A VM is an orphan only when all of these hold:
 *  - its metadata says `cmux_env` is this Worker's environment and `cmux_id` is a cmux VM id, and its slug is exactly the
 *    one a create of that id uses (`cmux-vm-<environment>-vm-<id>`): it is ours;
 *  - it was created at least ORPHAN_MIN_AGE_MS ago, longer than a create request's idempotency lease and send grace
 *    (src/limits/ledger.ts, 10 minutes each), so no create that could still record it is running;
 *  - no ownership row of any state (live, uncommitted or deleted) names its cmux id.
 *
 * Only exact provider ids from that listing are deleted, never a slug pattern. Listing is complete before anything is
 * deleted, so a delete never shifts the pages still to read.
 */
import { Effect, Schema } from "effect";
import { UpstreamError } from "./client.ts";
import { makeUpstreamHttp } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";

/** The youngest VM the sweep may delete; a caller can ask for older, never younger. */
export const ORPHAN_MIN_AGE_MS = 15 * 60_000;
const PAGE_SIZE = 50;
/** 2,000 VMs per run; a larger account is finished by later runs (the report says the listing was cut short). */
const MAX_PAGES = 40;
const CMUX_VM_ID = /^vm_[0-9a-hjkmnp-tv-z]{26}$/u;
/** Ownership lookups per query. */
const LOOKUP_BATCH = 100;

const ListedVm = Schema.Struct({
  id: Schema.String,
  slug: Schema.optional(Schema.NullOr(Schema.String)),
  state: Schema.String,
  createdAt: Schema.String,
  resources: Schema.optional(Schema.NullOr(Schema.Struct({ cpu: Schema.Number, memory: Schema.Number }))),
  metadata: Schema.optional(Schema.NullOr(Schema.Record({ key: Schema.String, value: Schema.String }))),
});
const ListPage = Schema.Struct({ vms: Schema.Array(ListedVm) });

export interface OrphanVm {
  readonly upstreamId: string;
  readonly cmuxId: string;
  /** The `cmux_tenant` metadata, when the create recorded one. */
  readonly tenant: string | null;
  readonly state: string;
  readonly createdAt: string;
  /** vCPUs and memory (MiB) the provider reports, for the cost a deletion stops. */
  readonly vcpus: number | null;
  readonly memoryMib: number | null;
}

export interface OrphanSweepReport {
  /** VMs of this environment the provider listed. */
  readonly listed: number;
  /** False when the page cap stopped the listing; the rest is swept by a later run. */
  readonly complete: boolean;
  readonly orphans: ReadonlyArray<OrphanVm>;
  /** Provider ids deleted this run (a 404 counts: the VM is gone). */
  readonly deleted: ReadonlyArray<string>;
  /** Provider ids whose delete failed; the next run tries again. */
  readonly failed: ReadonlyArray<string>;
}

export interface OrphanSweepOptions<E, R> {
  readonly nowMs: number;
  /** At least ORPHAN_MIN_AGE_MS; a smaller value is raised to it. */
  readonly minAgeMs?: number;
  /** List and report only. */
  readonly dryRun: boolean;
  /** Deletes per run (default 200). */
  readonly maxDeletes?: number;
  /** The cmux ids among these that have an ownership row of any state. */
  readonly recorded: (cmuxIds: ReadonlyArray<string>) => Effect.Effect<ReadonlySet<string>, E, R>;
}

export const orphanSlug = (environment: string, cmuxId: string) => `cmux-vm-${environment}-${cmuxId.replace("_", "-")}`;

export const sweepOrphanVms = <E, R>(config: UpstreamConfig, options: OrphanSweepOptions<E, R>) =>
  Effect.gen(function* () {
    const http = makeUpstreamHttp(config);
    const environment = config.environment;
    const minAgeMs = Math.max(options.minAgeMs ?? ORPHAN_MIN_AGE_MS, ORPHAN_MIN_AGE_MS);
    const candidates = new Map<string, OrphanVm>();
    let listed = 0;
    let complete = false;
    for (let page = 0; page < MAX_PAGES; page += 1) {
      const query = new URLSearchParams({ metadata: `cmux_env:${environment}`, limit: String(PAGE_SIZE), offset: String(page * PAGE_SIZE) });
      const body = yield* http.json("listOrphanCandidates", "GET", `/v5/vms?${query.toString()}`).pipe(
        Effect.flatMap(Schema.decodeUnknown(ListPage)),
        Effect.mapError((error) => (error instanceof UpstreamError ? error : new UpstreamError({ operation: "listOrphanCandidates", status: null }))),
      );
      for (const vm of body.vms) {
        const metadata = vm.metadata ?? {};
        // The filter is the provider's; the sweep checks it again and never trusts it alone.
        if (metadata["cmux_env"] !== environment) continue;
        listed += 1;
        const cmuxId = metadata["cmux_id"];
        if (cmuxId === undefined || !CMUX_VM_ID.test(cmuxId) || vm.slug !== orphanSlug(environment, cmuxId)) continue;
        const createdMs = Date.parse(vm.createdAt);
        if (!Number.isFinite(createdMs) || options.nowMs - createdMs < minAgeMs) continue;
        candidates.set(vm.id, { upstreamId: vm.id, cmuxId, tenant: metadata["cmux_tenant"] ?? null, state: vm.state, createdAt: vm.createdAt,
          vcpus: vm.resources?.cpu ?? null, memoryMib: vm.resources?.memory ?? null });
      }
      if (body.vms.length < PAGE_SIZE) {
        complete = true;
        break;
      }
    }
    const all = [...candidates.values()];
    const recorded = new Set<string>();
    for (let index = 0; index < all.length; index += LOOKUP_BATCH) {
      for (const id of yield* options.recorded(all.slice(index, index + LOOKUP_BATCH).map((vm) => vm.cmuxId))) recorded.add(id);
    }
    const orphans = all.filter((vm) => !recorded.has(vm.cmuxId));
    const deleted: string[] = [];
    const failed: string[] = [];
    if (!options.dryRun) {
      for (const vm of orphans.slice(0, options.maxDeletes ?? 200)) {
        // Asked again right before the delete: a create retried since the listing may have recorded this VM.
        const recordedNow = yield* Effect.either(options.recorded([vm.cmuxId]));
        if (recordedNow._tag === "Left") {
          failed.push(vm.upstreamId);
          continue;
        }
        if (recordedNow.right.has(vm.cmuxId)) continue;
        const outcome = yield* Effect.either(
          http.json("deleteOrphanVm", "DELETE", `/v5/vms/${encodeURIComponent(vm.upstreamId)}`).pipe(
            Effect.catchAll((error) => (error.status === 404 ? Effect.void : Effect.fail(error))),
          ),
        );
        (outcome._tag === "Right" ? deleted : failed).push(vm.upstreamId);
      }
    }
    const report: OrphanSweepReport = { listed, complete, orphans, deleted, failed };
    return report;
  });
