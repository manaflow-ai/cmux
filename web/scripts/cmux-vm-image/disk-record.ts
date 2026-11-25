/**
 * The fresh image's disk use, read in the guest after clean and before the snapshot (bake.ts finalizeAndCollect),
 * so nobody has to start a VM to learn what a new machine's root filesystem holds. RFD 0068 item 8.
 *
 * - DISK_RECORD_COMMAND: `df -B1M -T /`, `df -i /` and `du -x -BM --max-depth=2 /` (one filesystem, depth 2,
 *   each under a timeout), in sections parseDiskOutput reads.
 * - The record (DiskRecord) goes into bake-<name>.json as `disk`, alone as disk-<name>.json in the out dir,
 *   and into the dev channel candidate (cloud-vm-image-bake.yml), so channels/dev.json history carries it.
 * - images/cmux-vm/fresh-disk.json is the record until a bake has written one: measured by hand, labelled so.
 * - renderDiskSection/replaceDiskSection write a table between two marker comments in a Markdown file; the
 *   next run replaces it.
 *
 * Usage (from web/): bun scripts/cmux-vm-image/disk-record.ts --doc <file.md> [--record <disk.json>]
 *   Without --record: the current dev image's record from channels/dev.json, else fresh-disk.json.
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/** No import of guest.ts's argValue: that module loads the provider SDK, and this one runs without it. */
const argValue = (name: string): string | undefined => {
  const i = process.argv.indexOf(name);
  return i === -1 ? undefined : process.argv[i + 1];
};
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
export const FRESH_DISK_FILE = "images/cmux-vm/fresh-disk.json";
const DEV_CHANNEL = "images/cmux-vm/channels/dev.json";
export const DISK_BEGIN = "<!-- cmux-vm-image-disk:begin -->";
export const DISK_END = "<!-- cmux-vm-image-disk:end -->";
/** du lines kept in the record (largest first); the doc shows fewer. */
const RECORD_DU_LINES = 200;
const DOC_DU_LINES = 25;

export type DiskRecord = {
  schema: 1;
  /** The image's snapshot name; null for a record not taken by a bake. */
  image: string | null;
  measured_at: string;
  /** "bake": bake.ts after clean, before the snapshot. "fresh-vm": by hand on a VM booted from the image. */
  source: "bake" | "fresh-vm";
  note?: string;
  root: { type: string; total_mib: number; used_mib: number; available_mib: number; use_pct: number };
  inodes: { total: number; used: number; free: number; use_pct: number } | null;
  /** `du -x -BM --max-depth=2 /`, largest first. */
  du_mib: { path: string; mib: number }[];
};

/** One exec: every tool bounded, the root filesystem only, and an exit of 0 so a slow du still yields df. */
export const DISK_RECORD_COMMAND = [
  "export LC_ALL=C",
  "echo @@df",
  "timeout 30 df -B1M -T / || true",
  "echo @@df-i",
  "timeout 30 df -i / || true",
  "echo @@du",
  "timeout 180 du -x -BM --max-depth=2 / 2>/dev/null; echo \"@@du-exit $?\"",
].join("; ");

function sections(output: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  let current: string[] | undefined;
  for (const line of output.split("\n")) {
    const marker = /^@@(df|df-i|du)$/.exec(line.trim());
    if (marker) {
      current = [];
      out.set(marker[1], current);
    } else if (line.startsWith("@@du-exit")) {
      out.set("du-exit", [line.slice("@@du-exit".length).trim()]);
      current = undefined;
    } else if (current && line.trim()) current.push(line);
  }
  return out;
}

/** The row of a df table for `/` (df wraps a long device name onto its own line; joining the rows undoes it). */
function dfRow(lines: string[] | undefined, what: string): string[] {
  if (!lines || lines.length < 2) throw new Error(`${what}: no output`);
  const fields = lines.slice(1).join(" ").trim().split(/\s+/);
  if (fields.at(-1) !== "/") throw new Error(`${what}: not the root filesystem: ${lines.slice(1).join(" ")}`);
  return fields;
}

const int = (s: string | undefined, what: string): number => {
  const n = Number((s ?? "").replace(/[%M]$/, ""));
  if (!Number.isInteger(n) || n < 0) throw new Error(`${what}: ${JSON.stringify(s)} is not a count`);
  return n;
};

/** Parses DISK_RECORD_COMMAND's output. Throws when df is missing; a du that timed out leaves what it printed. */
export function parseDiskOutput(output: string, meta: Pick<DiskRecord, "image" | "measured_at" | "source"> & { note?: string }): DiskRecord {
  const s = sections(output);
  // Filesystem Type 1M-blocks Used Available Use% Mounted on
  const df = dfRow(s.get("df"), "df -B1M -T /");
  const [type, total, used, available, pct] = df.slice(-6, -1);
  const root = { type, total_mib: int(total, "df total"), used_mib: int(used, "df used"), available_mib: int(available, "df available"), use_pct: int(pct, "df use") };
  let inodes: DiskRecord["inodes"] = null;
  // Filesystem Inodes IUsed IFree IUse% Mounted on; a filesystem without inode counts prints "-".
  const dfi = s.get("df-i");
  if (dfi && dfi.length >= 2) {
    const [itotal, iused, ifree, ipct] = dfRow(dfi, "df -i /").slice(-5, -1);
    if (itotal !== "-") inodes = { total: int(itotal, "inodes"), used: int(iused, "inodes used"), free: int(ifree, "inodes free"), use_pct: int(ipct, "inodes use") };
  }
  const du_mib = (s.get("du") ?? [])
    .map((line) => /^(\d+)M\s+(\/.*)$/.exec(line.trim()))
    .filter((m): m is RegExpExecArray => m !== null)
    .map((m) => ({ path: m[2], mib: Number(m[1]) }))
    .sort((a, b) => b.mib - a.mib || a.path.localeCompare(b.path))
    .slice(0, RECORD_DU_LINES);
  const duExit = s.get("du-exit")?.[0];
  const note = [meta.note, duExit && duExit !== "0" && `du exited ${duExit}${duExit === "124" ? " (timed out; its list is partial)" : ""}`].filter(Boolean).join("; ");
  return { schema: 1, image: meta.image, measured_at: meta.measured_at, source: meta.source, ...(note ? { note } : {}), root, inodes, du_mib };
}

const n = (x: number) => x.toLocaleString("en-US");

/** The Markdown section, markers included. */
export function renderDiskSection(record: DiskRecord): string {
  const { root, inodes } = record;
  const where = record.source === "bake" ? `by the bake of \`${record.image}\`, after clean and before the snapshot` : "on a fresh default VM, not by the bake";
  const du = record.du_mib.slice(0, DOC_DU_LINES);
  return [
    DISK_BEGIN,
    "<!-- Generated by web/scripts/cmux-vm-image/disk-record.ts from the image's disk record; the next run replaces this section. -->",
    "",
    `Fresh image disk use, measured ${record.measured_at} ${where}.${record.note ? ` ${record.note}.` : ""}`,
    "",
    "| Root filesystem | Type | Total | Used | Available | Use | Inodes used |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
    `| \`/\` | ${root.type} | ${n(root.total_mib)} MiB | ${n(root.used_mib)} MiB | ${n(root.available_mib)} MiB | ${root.use_pct}% | ${inodes ? `${n(inodes.used)} of ${n(inodes.total)} (${inodes.use_pct}%)` : "not measured"} |`,
    "",
    `| Directory (\`du -x\`, depth 2${record.du_mib.length > du.length ? `, largest ${du.length}` : ""}) | MiB |`,
    "| --- | ---: |",
    ...du.map((d) => `| \`${d.path}\` | ${n(d.mib)} |`),
    DISK_END,
  ].join("\n");
}

/** Replaces the section between the markers; a file without them gets the section appended. */
export function replaceDiskSection(doc: string, section: string): string {
  const begin = doc.indexOf(DISK_BEGIN);
  const end = doc.indexOf(DISK_END);
  if (begin === -1 && end === -1) return `${doc.replace(/\n*$/, "\n\n")}${section}\n`;
  if (begin === -1 || end === -1 || end < begin) throw new Error(`the disk section's markers are broken (${DISK_BEGIN} ... ${DISK_END})`);
  return doc.slice(0, begin) + section + doc.slice(end + DISK_END.length);
}

/** The current dev image's disk record from channels/dev.json, else the hand-measured fresh-disk.json. */
export function currentDiskRecord(dev: { snapshot_id?: string; history?: { snapshot_id?: string; disk?: DiskRecord }[] }, fallback: DiskRecord): DiskRecord {
  return dev.history?.find((h) => h.snapshot_id === dev.snapshot_id)?.disk ?? fallback;
}

// Bun-only `import.meta.main` is not in TypeScript's ImportMeta type (promote-record.ts).
if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const doc = argValue("--doc");
  if (!doc) {
    console.error("usage: disk-record.ts --doc <file.md> [--record <disk.json>]");
    process.exit(2);
  }
  const read = (f: string) => JSON.parse(readFileSync(f, "utf8"));
  const recordFile = argValue("--record");
  const record: DiskRecord = recordFile ? read(recordFile) : currentDiskRecord(read(path.join(REPO_ROOT, DEV_CHANNEL)), read(path.join(REPO_ROOT, FRESH_DISK_FILE)));
  writeFileSync(doc, replaceDiskSection(readFileSync(doc, "utf8"), renderDiskSection(record)));
  console.log(`wrote the disk section of ${doc} from ${record.source === "bake" ? record.image : FRESH_DISK_FILE}`);
}
