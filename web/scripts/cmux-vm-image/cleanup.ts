/**
 * Delete what one image run created: every id its ledger (resources.tsv)
 * records as created and not yet deleted. Never lists or deletes anything
 * else on the account.
 *
 * Usage (from web/): bun ../images/cmux-vm/cleanup.ts --ledger <out-dir>/resources.tsv [--keep-snapshot]
 *
 * --keep-snapshot: the run's snapshot is recorded as kept (a dev channel candidate) and only
 * its VMs (builder, smoke clones) are deleted. Prints KEPT_SNAPSHOT <id> <name>.
 *
 * Or delete one kept image snapshot by exact id (cloud-vm-image-promote.yml delete_snapshot):
 *   bun ../images/cmux-vm/cleanup.ts --snapshot <sh-id>
 * Refuses an id, or the snapshot's name, that any images/cmux-vm/channels/*.json (pointer,
 * previous, history, prose) or backend/apps/api/wrangler.jsonc mentions, and a snapshot whose
 * name is not a cmuxnp-dev-vmimg- image; it names every reference it found.
 */
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { argValue, freestyleClient, Ledger } from "./guest";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
export const SNAPSHOT_ID = /^sh-[0-9a-f]{32}$/;
const DEV_IMAGE_PREFIX = "cmuxnp-dev-vmimg-";

/** The files whose snapshots serve or may be rolled back to, relative to the repo root. */
export function referenceFiles(root: string): string[] {
  const channels = path.join(root, "images/cmux-vm/channels");
  return [
    ...readdirSync(channels)
      .filter((name) => name.endsWith(".json"))
      .sort()
      .map((name) => `images/cmux-vm/channels/${name}`),
    "backend/apps/api/wrangler.jsonc",
  ];
}

/** `token` as a whole word, any case: a slug never matches a longer slug it is a prefix of. */
const wordPattern = (token: string) => new RegExp(`(?<![A-Za-z0-9_-])${token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![A-Za-z0-9_-])`, "i");

/** JSON paths of every key or string value that mentions `pattern` (decoded, so an escaped id still matches). */
function jsonPaths(value: unknown, pattern: RegExp, at: string, out: string[]): void {
  if (typeof value === "string") {
    if (pattern.test(value)) out.push(at || "(root)");
  } else if (Array.isArray(value)) {
    value.forEach((item, i) => jsonPaths(item, pattern, `${at}[${i}]`, out));
  } else if (value && typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      const where = at ? `${at}.${key}` : key;
      if (pattern.test(key)) out.push(`${where} (key)`);
      jsonPaths(item, pattern, where, out);
    }
  }
}

/** JSONC string escapes decoded (\uXXXX, \/), so a reference cannot hide behind one. */
const decodeEscapes = (text: string) => text.replace(/\\u([0-9a-fA-F]{4})/g, (_, hex: string) => String.fromCharCode(parseInt(hex, 16))).replace(/\\\//g, "/");

/**
 * Every place in the reference files that mentions one of `tokens` (a snapshot id or name), as
 * "<file>: <json path>" for channel files and "<file>:<line> <var>" for wrangler.jsonc.
 * Fails closed: a channel file that does not parse is a reference for every token.
 */
export function snapshotReferences(root: string, tokens: ReadonlyArray<string>): string[] {
  const refs: string[] = [];
  for (const rel of referenceFiles(root)) {
    const text = readFileSync(path.join(root, rel), "utf8");
    if (rel.endsWith(".json")) {
      let doc: unknown;
      try {
        doc = JSON.parse(text);
      } catch (error) {
        refs.push(`${rel}: (file does not parse: ${String(error).slice(0, 80)}) so nothing in it can be ruled out`);
        continue;
      }
      for (const token of tokens) {
        const paths: string[] = [];
        jsonPaths(doc, wordPattern(token), "", paths);
        for (const p of paths) refs.push(`${rel}: ${p} mentions ${token}`);
      }
    } else {
      const lines = decodeEscapes(text).split("\n");
      for (const token of tokens) {
        const pattern = wordPattern(token);
        lines.forEach((line, i) => {
          if (!pattern.test(line)) return;
          const keys = [...line.matchAll(/"([A-Za-z0-9_]+)":\s*"([^"]*)"/g)].filter((m) => pattern.test(m[2]!)).map((m) => m[1]);
          refs.push(`${rel}:${i + 1} ${keys.length ? keys.join(", ") : "(text)"} mentions ${token}`);
        });
      }
    }
  }
  return refs;
}

type SnapshotApi = {
  get(id: string): Promise<{ id: string; slug?: string | null; displayName?: string | null }>;
  delete(id: string): Promise<void>;
};

/** freestyle's FreestyleApiError carries the HTTP status; its message is the API's prose. */
const notFound = (error: unknown) => (error as { status?: unknown } | null)?.status === 404 || /not.?found/i.test(String(error));

/** Deletes one image snapshot by exact id after the reference checks; 0 deleted or already gone, 1 refused or failed. */
export async function deleteSnapshot(
  id: string,
  deps: { root: string; snapshots: () => SnapshotApi; log: (line: string) => void; error: (line: string) => void },
): Promise<number> {
  if (!SNAPSHOT_ID.test(id)) {
    deps.error(`refusing ${JSON.stringify(id)}: not a snapshot id (sh- and 32 hex digits)`);
    return 1;
  }
  const byId = snapshotReferences(deps.root, [id]);
  if (byId.length) {
    deps.error(`refusing to delete ${id}: it is referenced`);
    for (const ref of byId) deps.error(`  ${ref}`);
    return 1;
  }
  const snapshots = deps.snapshots();
  let snapshot: Awaited<ReturnType<SnapshotApi["get"]>>;
  try {
    snapshot = await snapshots.get(id);
  } catch (error) {
    if (notFound(error)) {
      deps.log(`already gone snapshot ${id}`);
      return 0;
    }
    deps.error(`could not read snapshot ${id}: ${String(error).slice(0, 200)}`);
    return 1;
  }
  const names = [...new Set([snapshot.slug, snapshot.displayName].filter((n): n is string => typeof n === "string" && n.length > 0))];
  if (!names.length || !names.every((n) => n.startsWith(DEV_IMAGE_PREFIX))) {
    deps.error(`refusing to delete ${id}: named ${names.join(", ") || "nothing"}; only ${DEV_IMAGE_PREFIX}* image snapshots are deleted here`);
    return 1;
  }
  const byName = snapshotReferences(deps.root, names);
  if (byName.length) {
    deps.error(`refusing to delete ${id} (${names.join(", ")}): its name is referenced`);
    for (const ref of byName) deps.error(`  ${ref}`);
    return 1;
  }
  deps.log(`reference check passed: ${id} (${names.join(", ")}) is in no channel file and not in wrangler.jsonc`);
  try {
    await snapshots.delete(id);
    deps.log(`deleted snapshot ${id} (${names.join(", ")})`);
    return 0;
  } catch (error) {
    if (notFound(error)) {
      deps.log(`already gone snapshot ${id}`);
      return 0;
    }
    deps.error(`could not delete snapshot ${id}: ${String(error).slice(0, 200)}`);
    return 1;
  }
}

export async function main(argv = process.argv): Promise<number> {
  const snapshotId = argValue("--snapshot", argv);
  if (snapshotId !== undefined) {
    return deleteSnapshot(snapshotId, {
      root: REPO_ROOT,
      snapshots: () => freestyleClient().vms.snapshots,
      log: (line) => console.log(line),
      error: (line) => console.error(line),
    });
  }
  const file = argValue("--ledger", argv);
  if (!file) throw new Error("usage: cleanup.ts --ledger <resources.tsv> [--keep-snapshot] | --snapshot <sh-id>");
  const ledger = new Ledger(path.resolve(file));
  if (argv.includes("--keep-snapshot")) {
    for (const row of ledger.live().filter((r) => r.kind === "snapshot")) {
      ledger.record(row.id, row.kind, row.name, "kept");
      console.log(`KEPT_SNAPSHOT ${row.id} ${row.name}`);
    }
  }
  const live = ledger.live();
  if (live.length === 0) {
    console.log("nothing to delete");
    return 0;
  }
  const fs = freestyleClient();
  let failed = 0;
  // VMs first: a snapshot may still back a running clone.
  for (const row of [...live].sort((a, b) => (a.kind === b.kind ? 0 : a.kind === "vm" ? -1 : 1))) {
    try {
      if (row.kind === "vm") await fs.vms.delete(row.id);
      else await fs.vms.snapshots.delete(row.id);
      ledger.record(row.id, row.kind, row.name, "deleted");
      console.log(`deleted ${row.kind} ${row.id} (${row.name})`);
    } catch (error) {
      const message = String(error);
      if (/not.?found|404/i.test(message)) {
        ledger.record(row.id, row.kind, row.name, "deleted");
        console.log(`already gone ${row.kind} ${row.id}`);
      } else {
        failed++;
        console.error(`could not delete ${row.kind} ${row.id}: ${message.slice(0, 200)}`);
      }
    }
  }
  return failed === 0 ? 0 : 1;
}
