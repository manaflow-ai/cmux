/**
 * Orphan sweep (cmux#35013): deletes provider VMs this environment made that no ownership row records, or whose row was
 * deleted long enough ago that its provider delete evidently did not take.
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
 *  - no ownership row protects its cmux id: none names it (reason `no_row`), or the row was deleted at least
 *    ORPHAN_DELETED_ROW_GRACE_MS ago (src/db/orphans.ts, reason `deleted_row`). A live row, committed or uncommitted,
 *    always protects it, and so does a row deleted more recently.
 *
 * Only exact provider ids from that listing are deleted, never a slug pattern. Listing is complete before anything is
 * deleted, so a delete never shifts the pages still to read.
 *
 * `sweepOrphanTunnels` does the same for device tunnels (migration 0018): see its comment.
 */
import { Effect, Option, Schema } from "effect";
import { parseDeviceId } from "../lib/ids.ts";
import { UpstreamError } from "./client.ts";
import { makeUpstreamHttp } from "./live-http.ts";
import { deviceTunnelSlug } from "./live-mesh.ts";
import type { UpstreamConfig } from "./live.ts";
import { upstreamName, upstreamNamePrefix } from "./naming.ts";
import { attachedOnlyTo } from "./tunnel-attachment.ts";

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
  /** `no_row`: no ownership row names it; `deleted_row`: its row was deleted and the VM is still there. */
  readonly reason: OrphanReason;
}

export type OrphanReason = "no_row" | "deleted_row";

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
  /** The cmux ids among these that an ownership row protects (src/db/orphans.ts recordedVmIds). */
  readonly recorded: (cmuxIds: ReadonlyArray<string>) => Effect.Effect<ReadonlySet<string>, E, R>;
  /** The cmux ids among these whose row is deleted, for each orphan's reason; without it every reason is `no_row`. */
  readonly deletedRows?: (cmuxIds: ReadonlyArray<string>) => Effect.Effect<ReadonlySet<string>, E, R>;
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
          vcpus: vm.resources?.cpu ?? null, memoryMib: vm.resources?.memory ?? null, reason: "no_row" });
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
    const unprotected = all.filter((vm) => !recorded.has(vm.cmuxId));
    const deletedRows = new Set<string>();
    if (options.deletedRows !== undefined) {
      for (let index = 0; index < unprotected.length; index += LOOKUP_BATCH) {
        for (const id of yield* options.deletedRows(unprotected.slice(index, index + LOOKUP_BATCH).map((vm) => vm.cmuxId))) deletedRows.add(id);
      }
    }
    const orphans: OrphanVm[] = unprotected.map((vm) => deletedRows.has(vm.cmuxId) ? { ...vm, reason: "deleted_row" } : vm);
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

const ListedTunnel = Schema.Struct({
  id: Schema.optional(Schema.NullOr(Schema.String)),
  tunnelId: Schema.optional(Schema.NullOr(Schema.String)),
  slug: Schema.optional(Schema.NullOr(Schema.String)),
  displayName: Schema.optional(Schema.NullOr(Schema.String)),
  attachments: Schema.optional(Schema.NullOr(Schema.Array(Schema.Struct({ vpcId: Schema.optional(Schema.NullOr(Schema.String)) })))),
});
/** The tunnel listing's bounds: one tunnel (its WireGuard config and attachments) and the whole reply, in characters. */
const MAX_TUNNEL_CHARS = 64 * 1024;
const MAX_LISTING_CHARS = 512 * 1024 * 1024;
const LIST_TIMEOUT_MS = 60_000;

/** A device tunnel at the provider, by the tenant and device its slug and name say made it. */
export interface TunnelOwner {
  readonly tenantId: string;
  readonly deviceId: string;
}

export interface OrphanTunnel extends TunnelOwner {
  readonly upstreamId: string;
  /** The networks the provider lists the tunnel attached to (null: an attachment with no network id). */
  readonly networks: ReadonlyArray<string | null>;
}

export interface TunnelSweepReport {
  /** Tunnels at this environment's device slugs the provider listed. */
  readonly listed: number;
  readonly orphans: ReadonlyArray<OrphanTunnel>;
  /**
   * Provider ids the lookup named but that are not attached to exactly their mesh's network
   * (src/upstream/tunnel-attachment.ts): never deleted, only reported.
   */
  readonly skipped: ReadonlyArray<string>;
  /** Provider ids deleted this run (a 404 counts: the tunnel is gone). */
  readonly deleted: ReadonlyArray<string>;
  /** Provider ids whose delete failed; the next run tries again. */
  readonly failed: ReadonlyArray<string>;
}

export interface TunnelSweepOptions<E, R> {
  /** List and report only. */
  readonly dryRun: boolean;
  /** Deletes per run (default 200). */
  readonly maxDeletes?: number;
  /**
   * The device ids among these whose tunnel nothing can use, each with its mesh's provider network id: no live device
   * row, and an enroll attempt that is resolved or whose intent is revoked (src/db/orphans.ts). A device with no attempt
   * row, or whose mesh's network is not recorded, is never named.
   */
  readonly sweepable: (owners: ReadonlyArray<TunnelOwner>) => Effect.Effect<ReadonlyMap<string, string>, E, R>;
}

/** The tenant and device a listed tunnel's slug and display name name, when both are exactly what a device create sends. */
const ownerOf = (environment: UpstreamConfig["environment"], tunnel: Schema.Schema.Type<typeof ListedTunnel>): TunnelOwner | null => {
  const prefix = `cmux-tun-${environment}-`;
  const slug = tunnel.slug ?? "";
  if (!slug.startsWith(prefix)) return null;
  const deviceId = slug.slice(prefix.length).replace("-", "_");
  if (Option.isNone(parseDeviceId(deviceId)) || deviceTunnelSlug(environment, deviceId) !== slug) return null;
  const name = tunnel.displayName ?? "";
  const namePrefix = upstreamNamePrefix(environment);
  const suffix = ` ${deviceId}`;
  if (!name.startsWith(namePrefix) || !name.endsWith(suffix)) return null;
  const tenantId = name.slice(namePrefix.length, name.length - suffix.length);
  if (tenantId.length === 0 || upstreamName(environment, tenantId, deviceId) !== name) return null;
  return { tenantId, deviceId };
};

/**
 * Deletes device tunnels nothing can use. A device create sends its tunnel's slug, `cmux-tun-<environment>-<device id>`,
 * with a device id fresh per attempt. A revoke (or an enroll's reconcile) resolves an attempt whose tunnel the provider
 * did not have once INTENT_SEND_GRACE_MS passed, and a create the provider processes after that still makes the
 * tunnel; when its reply is lost too, no request is left to delete it. This sweep is what does: it lists the provider's
 * tunnels, keeps those at this environment's device slug whose display name is exactly the create's (tenant and
 * device), and deletes each whose device has no live device row and whose attempt is resolved or whose intent is
 * revoked. A resolved attempt never commits a device row (`commitDeviceIntent` needs it unresolved), and a revoked
 * intent never commits, so no device can come to use a tunnel this deletes; each is asked again right before its delete.
 * Before any delete it also checks the rule every found-tunnel delete checks (src/upstream/tunnel-attachment.ts): the
 * tunnel is attached to exactly its mesh's network. One that is not (a revoke refused it for that reason, and its
 * tombstone named it here) is skipped and reported, never deleted.
 * The provider does not page the listing, so it is read as it streams (src/upstream/json-items.ts) rather than through
 * the 1 MiB cap of a whole reply: a large account's listing never disables the sweep. Only exact provider ids from it are
 * deleted.
 */
export const sweepOrphanTunnels = <E, R>(config: UpstreamConfig, options: TunnelSweepOptions<E, R>) =>
  Effect.gen(function* () {
    const http = makeUpstreamHttp(config);
    // The provider does not page this listing: it is read as it streams, keeping only this environment's device tunnels.
    const listed = yield* http.items(
      "listOrphanTunnels",
      "/v5/tunnels",
      "tunnels",
      (item): OrphanTunnel | null => {
        const tunnel = Schema.decodeUnknownOption(ListedTunnel)(item);
        if (Option.isNone(tunnel)) return null;
        const owner = ownerOf(config.environment, tunnel.value);
        const upstreamId = tunnel.value.id ?? tunnel.value.tunnelId ?? null;
        if (owner === null || upstreamId === null) return null;
        return { ...owner, upstreamId, networks: (tunnel.value.attachments ?? []).map((attachment) => attachment.vpcId ?? null) };
      },
      { timeoutMs: LIST_TIMEOUT_MS, maxItemChars: MAX_TUNNEL_CHARS, maxChars: MAX_LISTING_CHARS },
    );
    const candidates = new Map<string, OrphanTunnel>();
    for (const tunnel of listed) if (tunnel !== null) candidates.set(tunnel.upstreamId, tunnel);
    const all = [...candidates.values()];
    const sweepable = new Map<string, string>();
    for (let index = 0; index < all.length; index += LOOKUP_BATCH) {
      for (const [device, network] of yield* options.sweepable(all.slice(index, index + LOOKUP_BATCH))) sweepable.set(device, network);
    }
    const named = all.filter((tunnel) => sweepable.has(tunnel.deviceId));
    // The same exact-network rule as the revoke's lookup: a tunnel not attached to exactly its mesh's network is never
    // deleted here, whatever its intent's state.
    const onItsMesh = (tunnel: OrphanTunnel, network: string | undefined) =>
      network !== undefined && attachedOnlyTo(tunnel.networks.map((vpcId) => ({ vpcId })), network);
    const orphans = named.filter((tunnel) => onItsMesh(tunnel, sweepable.get(tunnel.deviceId)));
    const skipped = named.filter((tunnel) => !onItsMesh(tunnel, sweepable.get(tunnel.deviceId))).map((tunnel) => tunnel.upstreamId);
    const deleted: string[] = [];
    const failed: string[] = [];
    if (!options.dryRun) {
      for (const tunnel of orphans.slice(0, options.maxDeletes ?? 200)) {
        const still = yield* Effect.either(options.sweepable([tunnel]));
        if (still._tag === "Left") {
          failed.push(tunnel.upstreamId);
          continue;
        }
        if (!still.right.has(tunnel.deviceId)) continue;
        if (!onItsMesh(tunnel, still.right.get(tunnel.deviceId))) {
          skipped.push(tunnel.upstreamId);
          continue;
        }
        const outcome = yield* Effect.either(
          http.json("deleteOrphanTunnel", "DELETE", `/v5/tunnels/${encodeURIComponent(tunnel.upstreamId)}`).pipe(
            Effect.catchAll((error) => (error.status === 404 ? Effect.void : Effect.fail(error))),
          ),
        );
        (outcome._tag === "Right" ? deleted : failed).push(tunnel.upstreamId);
      }
    }
    const report: TunnelSweepReport = { listed: all.length, orphans, skipped, deleted, failed };
    return report;
  });
