#!/usr/bin/env bun
/**
 * Deletes the Freestyle machines and snapshots a CI run created, so a run
 * that is cancelled, times out or crashes leaves nothing behind that bills.
 *
 * A script's own `finally` does not run when the runner kills it: GitHub
 * cancels a job with SIGINT, then SIGTERM, then SIGKILL, and a timeout ends
 * the same way. So the scripts that create a Freestyle VM in CI tag it with
 * the run (`ciVmTags`: metadata `cmux: ci`, `run: gh-<GITHUB_RUN_ID>-<GITHUB_RUN_ATTEMPT>`),
 * and the workflow runs this script in an `if: always()` step, which GitHub
 * runs after a cancel too. It deletes what carries that exact tag and nothing
 * else. The bake's builder (build-devbox-freestyle.ts) is found by its name
 * instead, `cmux-devbox-builder <run slug>`: the bake script is part of the
 * image's source digest, so tagging it would ask for a re-promotion. A name is
 * not proof of ownership in an account customers share, so a builder must also
 * have been created after the run started (--since), have booted from the
 * builder base, and carry no `cmux` metadata (every customer machine the
 * driver creates carries `cmux: cloud`). Snapshots need the --since window too.
 *
 * Usage:
 *   FREESTYLE_API_KEY=... bun scripts/cloud-vm/ci-leftovers.ts vms [--tag <run tag>]
 *       [--builder-of <run slug> --since <ISO time>] [--dry-run]
 *       Delete every VM tagged with this run (default: the current run's
 *       tag), and with --builder-of the bake builder named for that slug.
 *   FREESTYLE_API_KEY=... bun scripts/cloud-vm/ci-leftovers.ts snapshots --slug <cmux-devbox-RUN_ID-ATTEMPT>
 *       --since <ISO time> --manifest <manifest.json> [--manifest ...]
 *       [--manifest-if-readable <manifest.json>] [--ledger <promote log>] [--dry-run]
 *       Delete the snapshots this promotion run made (runSnapshotSelection),
 *       except any snapshot one of the given manifests names: what a run did
 *       not stage for promotion can never be promoted. A --manifest that cannot
 *       be read stops the cleanup; a --manifest-if-readable one (the
 *       checkout's, which a kill can cut off mid-write) is skipped with a
 *       warning, since a run whose manifest write was cut off staged nothing.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Metadata on every VM a CI run tags: `cmux: ci` plus `run: gh-<run id>-<attempt>`,
 * the key:value shape bench-freestyle-floor.ts lists by.
 */
export const CI_VM_KIND = "ci";

/**
 * Throwaway machines (never snapshotted) pause after this long without
 * network activity. Longer than any check that boots one runs in total (a
 * verify is minutes), so a live check is never paused even if the exec API's
 * traffic does not count as activity.
 */
export const THROWAWAY_VM_IDLE_TIMEOUT_SECONDS = 60 * 60;
/**
 * Throwaway machines are deleted this long after create, whatever they are
 * doing: the longest job that boots one (the image promotion) times out at
 * 180 minutes, so nothing alive still needs it.
 */
export const THROWAWAY_VM_TTL_SECONDS = 3 * 60 * 60;

/** `gh-<run id>-<attempt>` inside GitHub Actions; null anywhere else. */
export function ciRunTag(env: NodeJS.ProcessEnv = process.env): string | null {
  const runId = env.GITHUB_RUN_ID?.trim();
  if (!runId || !/^\d+$/.test(runId)) return null;
  const attempt = env.GITHUB_RUN_ATTEMPT?.trim();
  return `gh-${runId}-${attempt && /^\d+$/.test(attempt) ? attempt : "1"}`;
}

/** Create options that tag a VM with its CI run (none outside CI). */
export function ciVmTags(env: NodeJS.ProcessEnv = process.env): { metadata?: Record<string, string> } {
  const tag = ciRunTag(env);
  return tag ? { metadata: { cmux: CI_VM_KIND, run: tag } } : {};
}

/**
 * Create options for a machine that is booted only to be checked and then
 * deleted, never snapshotted: tagged with the run, paused when idle, and
 * deleted at a hard deadline even if nothing else ever cleans it up. Never use
 * these for a VM that becomes a snapshot: the pause and the deadline would
 * ride into every machine made from it.
 */
export function throwawayVmOptions(env: NodeJS.ProcessEnv = process.env): {
  idleTimeoutSeconds: number;
  ttlSeconds: number;
  metadata?: Record<string, string>;
} {
  return {
    idleTimeoutSeconds: THROWAWAY_VM_IDLE_TIMEOUT_SECONDS,
    ttlSeconds: THROWAWAY_VM_TTL_SECONDS,
    ...ciVmTags(env),
  };
}

/** How long a signal handler's cleanup may take before the script exits anyway. */
export const SIGNAL_CLEANUP_TIMEOUT_MS = 20_000;

/**
 * Runs `cleanup` once on SIGINT or SIGTERM, then exits 130 or 143, after at
 * most `timeoutMs` even if the cleanup hangs. Covers a Ctrl-C on a local run
 * and a signal that reaches the script in CI; the workflow's always() step
 * covers the SIGKILL that nothing can catch. Returns a function that removes
 * the handlers.
 */
export function cleanupOnSignal(cleanup: () => Promise<void>, timeoutMs = SIGNAL_CLEANUP_TIMEOUT_MS): () => void {
  let started = false;
  // One closure per signal: the exit code must not depend on what the
  // runtime passes a listener.
  const handlerFor = (signal: "SIGINT" | "SIGTERM", exitCode: number) => () => {
    if (started) return;
    started = true;
    console.error(`${signal}: cleaning up before exit`);
    const deadline = setTimeout(() => {
      console.error(`cleanup on ${signal} did not finish in ${timeoutMs} ms; exiting (the workflow's cleanup step retries)`);
      process.exit(exitCode);
    }, timeoutMs);
    void cleanup()
      .catch((error: unknown) => console.error(`cleanup on ${signal} failed: ${String(error)}`))
      .finally(() => {
        clearTimeout(deadline);
        process.exit(exitCode);
      });
  };
  const onInt = handlerFor("SIGINT", 130);
  const onTerm = handlerFor("SIGTERM", 143);
  process.on("SIGINT", onInt);
  process.on("SIGTERM", onTerm);
  return () => {
    process.off("SIGINT", onInt);
    process.off("SIGTERM", onTerm);
  };
}

export type TaggedVm = {
  id: string;
  displayName?: string | null;
  metadata?: Record<string, string> | null;
  snapshotId?: string | null;
  /** The snapshot's name when the VM was created, `{owner}/{slug}` for a public base. */
  sourceSnapshotSlugAtCreate?: string | null;
  createdAt?: string | null;
};

/** Created at or after `since`; an unreadable time never counts. */
function createdSince(createdAt: string | null | undefined, since: Date): boolean {
  const created = createdAt ? Date.parse(createdAt) : Number.NaN;
  return Number.isFinite(created) && created >= since.getTime();
}

/** The VMs carrying exactly this run's tag; a list filter the API ignored cannot widen it. */
export function vmsTaggedForRun<T extends TaggedVm>(vms: readonly T[], tag: string): T[] {
  return vms.filter((vm) => vm.metadata?.cmux === CI_VM_KIND && vm.metadata?.run === tag);
}

/** A promotion run's slug: cmux-devbox-<GITHUB_RUN_ID>-<GITHUB_RUN_ATTEMPT> (cloud-vm-image-contract.yml). */
export const RUN_SNAPSHOT_SLUG = /^cmux-devbox-\d+-\d+$/;

function requireRunSlug(slug: string): void {
  if (!RUN_SNAPSHOT_SLUG.test(slug)) {
    throw new Error(`${slug} is not a promotion run's slug (cmux-devbox-<run id>-<attempt>)`);
  }
}

/**
 * The bake builder build-devbox-freestyle.ts made for this run's slug: its
 * exact name, booted from the builder base, created since the run started,
 * and no `cmux` metadata (customer machines carry `cmux: cloud`).
 */
export function builderVmsForRun<T extends TaggedVm>(vms: readonly T[], slug: string, base: string, since: Date): T[] {
  requireRunSlug(slug);
  return vms.filter(
    (vm) =>
      vm.displayName === `cmux-devbox-builder ${slug}` &&
      (vm.snapshotId === base || vm.sourceSnapshotSlugAtCreate === base) &&
      vm.metadata?.cmux === undefined &&
      createdSince(vm.createdAt, since),
  );
}

export type SnapshotRow = { id: string; slug?: string | null; displayName?: string | null; createdAt?: string | null };

/**
 * The snapshots one promotion run made, each proven two ways that a customer
 * cannot fake:
 * - its slug is the run's (`<slug>`, or `<slug>-<size>` for a derived size)
 *   and it was taken since the run started. Customers name snapshots through
 *   the cmux API, which sets only a display name, never a slug
 *   (drivers/freestyle.ts snapshot()); or
 * - the run's own log reported taking it (`ledgerIds`): the bake prints
 *   `SNAPSHOT_RESULT {...}` and derive-devbox-sizes.ts `SNAPSHOT_TAKEN <id>`
 *   right after each snapshot, before any slug is set, so one cut off before
 *   its slug is still found.
 * A display name alone is never enough. A snapshot a manifest names is never
 * selected.
 */
export function runSnapshotSelection<T extends SnapshotRow>(
  snapshots: readonly T[],
  slug: string,
  protectedIds: ReadonlySet<string>,
  since: Date,
  ledgerIds: ReadonlySet<string> = new Set(),
): T[] {
  requireRunSlug(slug);
  const ownSlug = (value: string) => value === slug || (value.startsWith(slug) && SIZE_SUFFIX.test(value.slice(slug.length)));
  return snapshots.filter(
    (row) =>
      !protectedIds.has(row.id) &&
      (ledgerIds.has(row.id) || (typeof row.slug === "string" && ownSlug(row.slug) && createdSince(row.createdAt, since))),
  );
}

const SIZE_SUFFIX = /^-(?:sm|md|lg|lgx|xl|2xl)$/;

/** Snapshot ids a run's log says it took (SNAPSHOT_RESULT / SNAPSHOT_TAKEN lines). */
export function ledgerSnapshotIds(log: string): Set<string> {
  const ids = new Set<string>();
  for (const line of log.split("\n")) {
    const taken = /^SNAPSHOT_TAKEN (sh-[0-9a-f]{32})\s*$/.exec(line.trim());
    if (taken) ids.add(taken[1]);
    const result = /^SNAPSHOT_RESULT (\{.*\})\s*$/.exec(line.trim());
    if (result) {
      try {
        const id = (JSON.parse(result[1]) as { snapshotId?: unknown }).snapshotId;
        if (typeof id === "string" && /^sh-[0-9a-f]{32}$/.test(id)) ids.add(id);
      } catch {
        // A line cut off mid-write proves nothing.
      }
    }
  }
  return ids;
}

/**
 * The image ids a manifest names, or null when the file cannot be read as one
 * (a write cut off by a kill). Pure JSON, so the cleanup needs no module that
 * could fail to load.
 */
export function manifestImageIds(text: string): Set<string> | null {
  try {
    const parsed = JSON.parse(text) as { images?: unknown };
    if (!Array.isArray(parsed.images)) return null;
    return new Set(parsed.images.flatMap((row) => (typeof (row as { imageId?: unknown })?.imageId === "string" ? [(row as { imageId: string }).imageId] : [])));
  } catch {
    return null;
  }
}

/** --since: an ISO time, less a margin for clock skew between the runner and the provider. */
export function parseSince(value: string | undefined, skewMs = 5 * 60_000): Date {
  const parsed = value ? Date.parse(value) : Number.NaN;
  if (!Number.isFinite(parsed)) throw new Error(`--since must be an ISO time, got ${value ?? "(nothing)"}`);
  return new Date(parsed - skewMs);
}

/** Freestyle answers 404 for something already gone; that counts as deleted. */
function isNotFound(error: unknown): boolean {
  const status = (error as { status?: unknown; statusCode?: unknown } | null)?.status ?? (error as { statusCode?: unknown } | null)?.statusCode;
  if (typeof status === "number") return status === 404;
  return /\b404\b|not[ _]found/i.test(error instanceof Error ? error.message : String(error));
}

export type DeleteOutcome = { deleted: string[]; failed: string[] };

/** Deletes each id, treating 404 as done; never throws, so one failure does not strand the rest. */
export async function deleteAll(
  ids: readonly string[],
  remove: (id: string) => Promise<void>,
  log: (line: string) => void = console.log,
): Promise<DeleteOutcome> {
  const outcome: DeleteOutcome = { deleted: [], failed: [] };
  for (const id of ids) {
    try {
      await remove(id);
      outcome.deleted.push(id);
      log(`deleted ${id}`);
    } catch (error) {
      if (isNotFound(error)) {
        outcome.deleted.push(id);
        log(`already gone ${id}`);
      } else {
        outcome.failed.push(id);
        log(`could not delete ${id}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }
  return outcome;
}

async function listAll<T>(page: (offset: number) => Promise<{ rows: T[]; total: number }>, pageSize = 100): Promise<T[]> {
  const rows: T[] = [];
  for (let offset = 0; ; offset += pageSize) {
    const next = await page(offset);
    rows.push(...next.rows);
    if (next.rows.length < pageSize || rows.length >= next.total) return rows;
  }
}

async function main(argv: string[]): Promise<void> {
  const [command, ...rest] = argv;
  const option = (name: string) => {
    const index = rest.indexOf(name);
    return index >= 0 ? rest[index + 1] : undefined;
  };
  const options = (name: string) => rest.flatMap((value, index) => (value === name && rest[index + 1] ? [rest[index + 1]] : []));
  const dryRun = rest.includes("--dry-run");
  const apiKey = process.env.FREESTYLE_API_KEY?.trim();
  if (!apiKey) throw new Error("FREESTYLE_API_KEY is required");
  const { Freestyle } = await import("freestyle");
  const fs = new Freestyle({ apiKey, baseUrl: process.env.FREESTYLE_API_URL?.trim() || undefined });

  let doomed: { id: string; label: string }[];
  let remove: (id: string) => Promise<void>;
  if (command === "vms") {
    const tag = option("--tag") ?? ciRunTag();
    if (!tag) throw new Error("vms: no --tag and no GITHUB_RUN_ID to derive one from");
    const tagged = vmsTaggedForRun(
      await listAll(async (offset) => {
        const page = await fs.vms.list({ metadata: `cmux:${CI_VM_KIND},run:${tag}`, limit: 100, offset });
        return { rows: page.vms, total: page.totalCount };
      }),
      tag,
    );
    const builderOf = option("--builder-of");
    let builders: TaggedVm[] = [];
    if (builderOf) {
      const since = parseSince(option("--since"));
      const base = process.env.CMUX_FREESTYLE_BUILDER_SNAPSHOT?.trim() || "freestyle/ubuntu-sm";
      const fromBase = await listAll(async (offset) => {
        const page = await fs.vms.list({ snapshotId: base, limit: 100, offset });
        return { rows: page.vms, total: page.totalCount };
      });
      builders = builderVmsForRun(fromBase, builderOf, base, since);
    }
    doomed = [...tagged, ...builders].map((vm) => ({ id: vm.id, label: vm.displayName ?? "" }));
    console.log(`vms: ${tagged.length} tagged run=${tag}${builderOf ? `, ${builders.length} builder(s) of ${builderOf}` : ""}`);
    remove = (id) => fs.vms.delete(id);
  } else if (command === "snapshots") {
    const slug = option("--slug");
    if (!slug) throw new Error("snapshots: --slug is required");
    const manifestFiles = options("--manifest");
    if (manifestFiles.length === 0) throw new Error("snapshots: pass every deployed manifest with --manifest, so a promoted snapshot is never deleted");
    const since = parseSince(option("--since"));
    const { existsSync, readFileSync } = await import("node:fs");
    const protectedIds = new Set<string>();
    for (const file of manifestFiles) {
      const ids = manifestImageIds(readFileSync(file, "utf8"));
      if (!ids) throw new Error(`${file} is not an image manifest; keeping every snapshot`);
      for (const id of ids) protectedIds.add(id);
    }
    for (const file of options("--manifest-if-readable")) {
      const ids = existsSync(file) ? manifestImageIds(readFileSync(file, "utf8")) : null;
      if (!ids) {
        console.warn(`::warning::${file} is missing or cut off; this run staged nothing from it`);
        continue;
      }
      for (const id of ids) protectedIds.add(id);
    }
    const ledgerIds = new Set(options("--ledger").flatMap((file) => (existsSync(file) ? [...ledgerSnapshotIds(readFileSync(file, "utf8"))] : [])));
    const snapshots = await listAll(async (offset) => {
      const page = await fs.vms.snapshots.list({ limit: 100, offset });
      return { rows: page.snapshots, total: page.totalCount };
    });
    const own = runSnapshotSelection(snapshots, slug, protectedIds, since, ledgerIds);
    console.log(`snapshots: ${own.length} made by ${slug} (${ledgerIds.size} in its log) and named by no manifest`);
    doomed = own.map((row) => ({ id: row.id, label: row.slug || row.displayName || "" }));
    remove = (id) => fs.vms.snapshots.delete(id);
  } else {
    throw new Error("usage: ci-leftovers.ts vms [--tag T] [--builder-of S --since ISO] [--dry-run] | snapshots --slug S --since ISO --manifest F [--manifest F]... [--manifest-if-readable F] [--ledger F] [--dry-run]");
  }
  if (dryRun) {
    for (const row of doomed) console.log(`would delete ${row.id} (${row.label})`);
    return;
  }
  const outcome = await deleteAll(doomed.map((row) => row.id), remove);
  // A leftover that could not be deleted is still billing: fail so it is seen.
  if (outcome.failed.length > 0) {
    console.error(`::error::could not delete ${outcome.failed.length}: ${outcome.failed.join(", ")}`);
    process.exitCode = 1;
  }
}

const isEntryPoint = process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntryPoint) await main(process.argv.slice(2));
