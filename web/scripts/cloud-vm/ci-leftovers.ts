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
 * image's source digest, so tagging it would ask for a re-promotion.
 *
 * Usage:
 *   FREESTYLE_API_KEY=... bun scripts/cloud-vm/ci-leftovers.ts vms [--tag <run tag>] [--builder-of <run slug>] [--dry-run]
 *       Delete every VM tagged with this run (default: the current run's
 *       tag), and with --builder-of the bake builder named for that slug.
 *   FREESTYLE_API_KEY=... bun scripts/cloud-vm/ci-leftovers.ts snapshots --slug <cmux-devbox-RUN_ID-ATTEMPT>
 *       --manifest <manifest.json> [--manifest ...] [--dry-run]
 *       Delete the snapshots this promotion run made (its bake, slugged <slug>,
 *       and its derived sizes, <slug>-<size>), slugged or not, except any
 *       snapshot one of the given manifests names: what a run did not stage
 *       for promotion can never be promoted.
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

/**
 * Runs `cleanup` once on SIGINT or SIGTERM, then exits 130 or 143. Covers a
 * Ctrl-C on a local run and a signal that reaches the script in CI; the
 * workflow's always() step covers the SIGKILL that nothing can catch.
 * Returns a function that removes the handlers.
 */
export function cleanupOnSignal(cleanup: () => Promise<void>): () => void {
  let started = false;
  const handler = (signal: NodeJS.Signals) => {
    if (started) return;
    started = true;
    console.error(`${signal}: cleaning up before exit`);
    void cleanup()
      .catch((error: unknown) => console.error(`cleanup on ${signal} failed: ${String(error)}`))
      .finally(() => process.exit(signal === "SIGINT" ? 130 : 143));
  };
  process.on("SIGINT", handler);
  process.on("SIGTERM", handler);
  return () => {
    process.off("SIGINT", handler);
    process.off("SIGTERM", handler);
  };
}

export type TaggedVm = { id: string; displayName?: string | null; metadata?: Record<string, string> | null };

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

/** The bake builder build-devbox-freestyle.ts names for this run's slug, and nothing else. */
export function builderVmsForRun<T extends TaggedVm>(vms: readonly T[], slug: string): T[] {
  requireRunSlug(slug);
  return vms.filter((vm) => vm.displayName === `cmux-devbox-builder ${slug}`);
}

export type SnapshotRow = { id: string; slug?: string | null; displayName?: string | null };

/**
 * The snapshots one promotion run made: the bake is slugged `<slug>` and its
 * derived sizes `<slug>-<size>`, and each is labelled `cmux devbox <its slug> (…)`
 * (build-devbox-freestyle.ts, derive-devbox-sizes.ts), which also finds one the
 * run snapshotted but never got to slug. A snapshot a manifest names is never
 * selected.
 */
export function runSnapshotSelection<T extends SnapshotRow>(
  snapshots: readonly T[],
  slug: string,
  protectedIds: ReadonlySet<string>,
): T[] {
  requireRunSlug(slug);
  const ownSlug = (value: string) => value === slug || value.startsWith(`${slug}-`);
  const ownLabel = (value: string) => value.startsWith(`cmux devbox ${slug} `) || value.startsWith(`cmux devbox ${slug}-`);
  return snapshots.filter(
    (row) =>
      !protectedIds.has(row.id) &&
      ((typeof row.slug === "string" && ownSlug(row.slug)) || (typeof row.displayName === "string" && ownLabel(row.displayName))),
  );
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
    const builders = builderOf
      ? builderVmsForRun(
          await listAll(async (offset) => {
            // Only machines booted from the builder base can be the builder.
            const base = process.env.CMUX_FREESTYLE_BUILDER_SNAPSHOT?.trim() || "freestyle/ubuntu-sm";
            const page = await fs.vms.list({ snapshotId: base, limit: 100, offset });
            return { rows: page.vms, total: page.totalCount };
          }),
          builderOf,
        )
      : [];
    doomed = [...tagged, ...builders].map((vm) => ({ id: vm.id, label: vm.displayName ?? "" }));
    console.log(`vms: ${tagged.length} tagged run=${tag}${builderOf ? `, ${builders.length} builder(s) of ${builderOf}` : ""}`);
    remove = (id) => fs.vms.delete(id);
  } else if (command === "snapshots") {
    const slug = option("--slug");
    if (!slug) throw new Error("snapshots: --slug is required");
    const manifestFiles = options("--manifest");
    if (manifestFiles.length === 0) throw new Error("snapshots: pass every deployed manifest with --manifest, so a promoted snapshot is never deleted");
    const { readImageManifest } = await import("../devbox-image-common");
    const protectedIds = new Set(manifestFiles.flatMap((file) => readImageManifest(file).images.map((row) => row.imageId)));
    const snapshots = await listAll(async (offset) => {
      const page = await fs.vms.snapshots.list({ limit: 100, offset });
      return { rows: page.snapshots, total: page.totalCount };
    });
    const own = runSnapshotSelection(snapshots, slug, protectedIds);
    console.log(`snapshots: ${own.length} made by ${slug} and named by no manifest`);
    doomed = own.map((row) => ({ id: row.id, label: row.slug || row.displayName || "" }));
    remove = (id) => fs.vms.snapshots.delete(id);
  } else {
    throw new Error("usage: ci-leftovers.ts vms [--tag T] [--builder-of S] [--dry-run] | snapshots --slug S --manifest F [--manifest F]... [--dry-run]");
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
