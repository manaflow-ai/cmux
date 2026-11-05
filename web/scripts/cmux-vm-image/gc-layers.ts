/**
 * Garbage-collects cached layer snapshots (layers.ts: cmuxnp-dev-vmimg-sys-<key> and -agt-<key>). Every change to a
 * layer's inputs leaves its old snapshot behind; this keeps:
 *   - the newest `--keep` of each layer (by creation time),
 *   - every snapshot a channel file, backend/apps/api/wrangler.jsonc or workers/cmux-vm/wrangler.jsonc
 *     (VM_BOOT_IMAGES) names, by id or slug, at this checkout,
 *   - every snapshot a recently booted one (`--recent-hours`, a bake in flight) is,
 *   - and every layer any kept snapshot or any dev image still on the account was built on, following the parent
 *     layer each layered snapshot's label records (layers.ts layerLabel), so no image loses its parent.
 * A snapshot with no recorded parent (baked before labels) keeps every layer older than itself. Only layer
 * snapshots are ever deleted; app images belong to cleanup.ts and the promote workflow.
 *
 * Usage (from web/): bun ../images/cmux-vm/gc-layers.ts [--keep 3] [--recent-hours 6] [--dry-run]
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { referenceFiles } from "./cleanup";
import { argValue, freestyleClient, hasFlag } from "./guest";
import { LAYER_PREFIX, labelParent, type LayerName } from "./layers";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

export type GcSnapshot = { id: string; slug?: string | null; displayName?: string | null; createdAt: string; lastUsedAt?: string | null };

const layerOf = (s: GcSnapshot): LayerName | undefined =>
  (Object.keys(LAYER_PREFIX) as LayerName[]).find((layer) => s.slug?.startsWith(LAYER_PREFIX[layer]));

/** Snapshot ids and cmuxnp- names the reference files mention. */
export function referencedTokens(root: string): Set<string> {
  const files = [...referenceFiles(root), "workers/cmux-vm/wrangler.jsonc"];
  const tokens = new Set<string>();
  for (const file of files) {
    let text: string;
    try {
      text = readFileSync(path.join(root, file), "utf8");
    } catch {
      continue;
    }
    for (const m of text.matchAll(/sh-[0-9a-f]{32}|cmuxnp-[a-z0-9-]+/g)) tokens.add(m[0]);
  }
  return tokens;
}

/** The plan: which layer snapshots stay (with why) and which go. Pure, for the tests. */
export function planLayerGc(all: readonly GcSnapshot[], refs: ReadonlySet<string>, options: { keep: number; recentMs: number; now: number }): { keep: Map<string, string>; remove: GcSnapshot[] } {
  const byId = new Map(all.map((s) => [s.id, s]));
  const keep = new Map<string, string>();
  const mark = (id: string, why: string) => {
    if (!keep.has(id)) keep.set(id, why);
  };
  for (const layer of Object.keys(LAYER_PREFIX) as LayerName[]) {
    const mine = all.filter((s) => layerOf(s) === layer).sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
    mine.slice(0, options.keep).forEach((s, i) => mark(s.id, `newest ${i + 1} of ${layer}`));
  }
  for (const s of all) {
    if (refs.has(s.id) || (s.slug && refs.has(s.slug))) mark(s.id, "referenced");
    const used = s.lastUsedAt ? Date.parse(s.lastUsedAt) : Number.NaN;
    if (layerOf(s) && options.now - used < options.recentMs) mark(s.id, "booted recently");
  }
  // Every ancestor of a kept snapshot, and of every image still on the account: deleting a layer under a live
  // image is never this tool's call. A label names the parent layer by slug (layers.ts layerLabel). A snapshot
  // with no recorded parent (an overlay or image baked before labels, or one whose label did not fit) could have
  // been built on any layer older than itself, so every such layer stays.
  const devImage = (s: GcSnapshot) => !layerOf(s) && Boolean(s.slug?.startsWith("cmuxnp-dev-vmimg-"));
  const queue = [...keep.keys(), ...all.filter(devImage).map((s) => s.id)];
  const seen = new Set<string>();
  for (let id = queue.shift(); id; id = queue.shift()) {
    if (seen.has(id)) continue;
    seen.add(id);
    const s = byId.get(id);
    if (!s || layerOf(s) === "system") continue;
    const parent = labelParent(s.displayName);
    const p = parent ? all.find((x) => x.slug === parent) : undefined;
    if (p) {
      mark(p.id, `parent of ${s.slug ?? s.id}`);
      queue.push(p.id);
      continue;
    }
    const born = Date.parse(s.createdAt);
    for (const older of all) {
      if (layerOf(older) && Date.parse(older.createdAt) < born && !keep.has(older.id)) {
        mark(older.id, `older than ${s.slug ?? s.id}, whose parent is not recorded`);
        queue.push(older.id);
      }
    }
  }
  return { keep, remove: all.filter((s) => layerOf(s) && !keep.has(s.id)) };
}

export async function main(argv = process.argv): Promise<number> {
  const keepN = Number(argValue("--keep", argv) ?? "3");
  const recentHours = Number(argValue("--recent-hours", argv) ?? "6");
  if (!Number.isInteger(keepN) || keepN < 1) throw new Error("--keep must be a whole number of at least 1");
  const fs = freestyleClient();
  const all: GcSnapshot[] = [];
  for (let offset = 0; ; offset += 100) {
    const page = await fs.vms.snapshots.list({ limit: 100, offset });
    all.push(...(page.snapshots as GcSnapshot[]));
    if (page.snapshots.length < 100 || all.length >= page.totalCount) break;
  }
  const plan = planLayerGc(all, referencedTokens(REPO_ROOT), { keep: keepN, recentMs: recentHours * 3600_000, now: Date.now() });
  for (const [id, why] of plan.keep) {
    const s = all.find((x) => x.id === id);
    if (s && layerOf(s)) console.log(`keep ${id} ${s.slug} (${why})`);
  }
  let failed = 0;
  for (const s of plan.remove) {
    if (hasFlag("--dry-run", argv)) {
      console.log(`would delete ${s.id} ${s.slug}`);
      continue;
    }
    try {
      await fs.vms.snapshots.delete(s.id);
      console.log(`deleted ${s.id} ${s.slug}`);
    } catch (error) {
      failed++;
      console.error(`could not delete ${s.id} ${s.slug}: ${String(error).slice(0, 200)}`);
    }
  }
  console.log(`LAYER_GC kept=${[...plan.keep.keys()].filter((id) => all.some((s) => s.id === id && layerOf(s))).length} removed=${plan.remove.length - failed} failed=${failed}`);
  return failed ? 1 : 0;
}
