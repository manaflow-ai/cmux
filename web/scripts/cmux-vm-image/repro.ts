/**
 * Reproducibility check (plans/cmux-next/vm-image.md 4.10): bake twice from
 * the lock (in parallel, two builders), then diff the SBOMs by
 * type+name+version and the file-hash manifests. Any difference fails except
 * the allow-list (REPRO_ALLOWED_DIFFS: the image stamp). Both snapshots are
 * deleted afterwards unless --keep-snapshots.
 *
 * Usage (from web/): bun ../images/cmux-vm/repro.ts --tag <tag> [--out-dir <dir>] [--keep-snapshots]
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { bake, type BakeResult } from "./bake";
import { argValue, freestyleClient, hasFlag, Ledger } from "./guest";
import { DEFAULT_LOCK_PATH, diffCounts, diffFileManifests, parseFileManifest, REPRO_ALLOWED_DIFFS, sbomComponentCounts } from "./lock";

export type ReproReport = {
  bakes: Array<{ name: string; snapshotId?: string; bakeMs?: unknown; error?: string }>;
  sbomComponents: [number, number];
  sbomDiffs: string[];
  manifestEntries: [number, number];
  manifestDiffs: string[];
  allowedDiffs: string[];
  passed: boolean;
};

export function compareBakes(a: BakeResult, b: BakeResult): Omit<ReproReport, "bakes"> {
  if (!a.sbomFile || !b.sbomFile || !a.manifestFile || !b.manifestFile) throw new Error("a bake produced no SBOM or manifest");
  const sa = sbomComponentCounts(JSON.parse(readFileSync(a.sbomFile, "utf8")));
  const sb = sbomComponentCounts(JSON.parse(readFileSync(b.sbomFile, "utf8")));
  const ma = parseFileManifest(readFileSync(a.manifestFile, "utf8"));
  const mb = parseFileManifest(readFileSync(b.manifestFile, "utf8"));
  const sbomDiffs = diffCounts(sa, sb);
  const files = diffFileManifests(ma, mb, REPRO_ALLOWED_DIFFS);
  const total = (m: Map<string, number>) => [...m.values()].reduce((x, y) => x + y, 0);
  return {
    sbomComponents: [total(sa), total(sb)],
    sbomDiffs,
    manifestEntries: [ma.size, mb.size],
    manifestDiffs: files.diffs,
    allowedDiffs: files.allowed,
    passed: sbomDiffs.length === 0 && files.diffs.length === 0,
  };
}

export async function main(argv = process.argv): Promise<number> {
  const tag = argValue("--tag", argv);
  if (!tag) throw new Error("usage: repro.ts --tag <tag> [--out-dir <dir>] [--keep-snapshots]");
  const outDir = path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}`);
  const lockPath = path.resolve(argValue("--lock", argv) ?? DEFAULT_LOCK_PATH);
  const common = { outDir, lockPath, updateLock: false, keepBuilder: false, promotion: false };
  const [a, b] = await Promise.all([bake({ ...common, tag: `${tag}-a` }), bake({ ...common, tag: `${tag}-b` })]);
  let report: ReproReport;
  try {
    report = { bakes: [a, b].map(({ name, snapshotId, bakeMs, error }) => ({ name, snapshotId, bakeMs, error })), ...compareBakes(a, b) };
  } catch (error) {
    report = { bakes: [a, b].map(({ name, snapshotId, bakeMs, error: e }) => ({ name, snapshotId, bakeMs, error: e })), sbomComponents: [0, 0], sbomDiffs: [String(error)], manifestEntries: [0, 0], manifestDiffs: [], allowedDiffs: [], passed: false };
  }
  if (!hasFlag("--keep-snapshots", argv)) {
    const fs = freestyleClient();
    const ledger = new Ledger(path.join(outDir, "resources.tsv"));
    for (const r of [a, b]) {
      if (!r.snapshotId) continue;
      try {
        await fs.vms.snapshots.delete(r.snapshotId);
        ledger.record(r.snapshotId, "snapshot", r.name, "deleted");
      } catch (error) {
        ledger.record(r.snapshotId, "snapshot", r.name, `delete-failed ${String(error).slice(0, 80)}`);
      }
    }
  }
  writeFileSync(path.join(outDir, `repro-${tag}.json`), `${JSON.stringify(report, null, 2)}\n`);
  console.log(`SBOM components ${report.sbomComponents.join(" vs ")}: ${report.sbomDiffs.length} differences`);
  console.log(`file manifest entries ${report.manifestEntries.join(" vs ")}: ${report.manifestDiffs.length} differences, ${report.allowedDiffs.length} allowed`);
  for (const line of [...report.sbomDiffs, ...report.manifestDiffs].slice(0, 80)) console.log(`  DIFF ${line}`);
  for (const line of report.allowedDiffs) console.log(`  allowed ${line}`);
  console.log(report.passed ? "REPRO PASSED" : "REPRO FAILED");
  return report.passed ? 0 : 1;
}
