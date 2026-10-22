/**
 * Time to first build on a new Cloud machine, before and after the dev tree (dev-tree.ts),
 * measured the same way on every `--dev-tree` bake (cloud-vm-image-bake.yml):
 *   before: machines of an image without the tree (the dev channel's): libclang from the live
 *           mirror, the clone, Zig, Rust, then `cargo build -p cmux-tui` (setUpDevTree)
 *   after:  machines of the new image: fetch and fast-forward, then the same build
 * Both sides build one commit: --ref (the workflow passes GITHUB_SHA, the commit the bake baked), or
 * the branch head when omitted; a run that built another commit fails. At bake time the image already
 * has that commit, so "after" is a new image's best case: an older image fetches and rebuilds what changed.
 * Every run is a fresh machine; its create to daemon ready (smoke.ts measureClone) and the root file
 * system's used bytes at create are recorded too. Every machine is deleted whatever happens.
 *
 * Usage (from web/):
 *   bun ../images/cmux-vm/first-build.ts --mode before|after --snapshot <sh-id> --tag <tag> [--ref <sha>] [--runs 3] [--out-dir <dir>]
 *   bun ../images/cmux-vm/first-build.ts --report <before.json> <after.json>
 * --report prints the Markdown table and needs no Freestyle access (nor web's dependencies: the
 * measuring modules load only for a measurement).
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { DevTreeLock } from "./lock";
import type { Vm } from "./guest";

type Mode = "before" | "after";
type Run = { vmId: string; createToReadyMs: number; rootUsedBytes: number; phasesMs: Record<string, number>; totalMs: number; head: string; bytes: Record<string, number> };
type Stat = { n: number; p50: number; min: number; max: number };
export type FirstBuildReport = {
  mode: Mode;
  snapshotId: string;
  firstBuild: string;
  runs: Run[];
  failed: string[];
  skipped?: string;
  error?: string;
  summary?: { totalMs: Stat; createToReadyMs: Stat; rootUsedBytes: Stat; phasesMs: Record<string, Stat> };
};

function stat(values: number[]): Stat {
  const sorted = [...values].sort((a, b) => a - b);
  return { n: sorted.length, p50: sorted[Math.ceil(sorted.length / 2) - 1] ?? Number.NaN, min: sorted[0] ?? Number.NaN, max: sorted.at(-1) ?? Number.NaN };
}

export function summarize(runs: readonly Run[]): FirstBuildReport["summary"] {
  const phases = [...new Set(runs.flatMap((r) => Object.keys(r.phasesMs)))];
  return {
    totalMs: stat(runs.map((r) => r.totalMs)),
    createToReadyMs: stat(runs.map((r) => r.createToReadyMs)),
    rootUsedBytes: stat(runs.map((r) => r.rootUsedBytes)),
    phasesMs: Object.fromEntries(phases.map((p) => [p, stat(runs.map((r) => r.phasesMs[p] ?? Number.NaN).filter(Number.isFinite))])),
  };
}

async function timeRun(vm: Vm, vmId: string, mode: Mode, tree: DevTreeLock, ref: string, createToReadyMs: number, log: (line: string) => void): Promise<Run> {
  const { run } = await import("./guest");
  const { devTreePhase, devTreeSizes, setUpDevTree, updateDevTree, uploadDevTreeScript } = await import("./dev-tree");
  const { sq } = await import("./lock");
  const rootUsedBytes = Number((await run(vm, "df -B1 --output=used / | tail -1")).stdout.trim());
  await uploadDevTreeScript(vm);
  const phasesMs: Record<string, number> = {};
  let head: string;
  if (mode === "before") {
    const apt = `export DEBIAN_FRONTEND=noninteractive; apt-get update -q >/dev/null && apt-get install -y -q --no-install-recommends ${tree.aptRoots.map(sq).join(" ")} >/dev/null && echo apt-ok`;
    phasesMs.apt = (await devTreePhase(vm, "apt", apt, 20 * 60_000)).ms;
    head = await setUpDevTree(vm, tree, ref, phasesMs, log);
  } else {
    head = await updateDevTree(vm, tree, ref, phasesMs, log);
  }
  if (ref && head !== ref) throw new Error(`built ${head}, not ${ref}`);
  const totalMs = Object.values(phasesMs).reduce((a, b) => a + b, 0);
  return { vmId, createToReadyMs, rootUsedBytes, phasesMs, totalMs, head, bytes: await devTreeSizes(vm, tree) };
}

export async function measure(options: { mode: Mode; snapshotId: string; tag: string; ref: string; runs: number; outDir: string }): Promise<FirstBuildReport> {
  const { measureClone } = await import("./smoke");
  const { deleteVm, freestyleClient, Ledger, run } = await import("./guest");
  const { readInputsLock, sq } = await import("./lock");
  const { devTreeLock, FIRST_BUILD } = await import("./dev-tree");
  mkdirSync(options.outDir, { recursive: true });
  const tree = devTreeLock(readInputsLock());
  const ledger = new Ledger(path.join(options.outDir, "resources.tsv"));
  const fs = freestyleClient();
  const report: FirstBuildReport = { mode: options.mode, snapshotId: options.snapshotId, firstBuild: `cd ${tree.dir}/cmux-tui && ${FIRST_BUILD.join(" ")}`, runs: [], failed: [] };
  const clones: Array<{ vm: Vm; vmId: string; name: string; readyMs: number }> = [];
  try {
    // One at a time, as smoke.ts creates: concurrent creates would skew create to ready.
    for (let i = 1; i <= options.runs; i++) {
      const { clone, row } = await measureClone(fs, ledger, `cmuxnp-dev-vmimg-${options.tag}-fb-${options.mode}-${i}`, options.snapshotId);
      clones.push({ ...clone, readyMs: Number(row.createToReadyMs) });
      console.log(`${options.mode} ${i} ${clone.vmId}: ${JSON.stringify(row)}`);
    }
    const hasTree = (await run(clones[0]!.vm, `test -e ${sq(tree.dir)} && echo yes || echo no`)).stdout.trim() === "yes";
    if (options.mode === "before" && hasTree) {
      report.skipped = `the image already has ${tree.dir}; a before run needs an image without the dev tree`;
    } else if (options.mode === "after" && !hasTree) {
      throw new Error(`the image has no ${tree.dir} (not a --dev-tree bake)`);
    } else {
      const settled = await Promise.allSettled(clones.map((c, i) => timeRun(c.vm, c.vmId, options.mode, tree, options.ref, c.readyMs, (line) => console.log(`[${options.mode}-${i + 1}] ${line}`))));
      for (const [i, s] of settled.entries()) {
        if (s.status === "fulfilled") report.runs.push(s.value);
        else report.failed.push(`${clones[i]!.vmId}: ${String(s.reason).slice(0, 2000)}`);
      }
      report.summary = summarize(report.runs);
    }
  } catch (error) {
    report.error = String(error);
  } finally {
    for (const c of clones) await deleteVm(c.vm, c.vmId, c.name, ledger);
  }
  writeFileSync(path.join(options.outDir, `first-build-${options.mode}-${options.tag}.json`), `${JSON.stringify(report, null, 2)}\n`);
  return report;
}

const minutes = (ms: number) => {
  if (!Number.isFinite(ms)) return "n/a";
  return ms < 60_000 ? `${(ms / 1000).toFixed(1)} s` : `${Math.floor(ms / 60_000)} min ${Math.round((ms % 60_000) / 1000)} s`;
};
const gigabytes = (bytes: number) => (Number.isFinite(bytes) ? `${(bytes / 1e9).toFixed(2)} GB` : "n/a");
const cell = (s: Stat | undefined, fmt: (v: number) => string) => (s && s.n > 0 ? `${fmt(s.p50)} (${fmt(s.min)} to ${fmt(s.max)}), n=${s.n}` : "not measured");

/** The before/after table (Markdown) from two first-build JSON reports. */
export function reportTable(before: FirstBuildReport, after: FirstBuildReport): string {
  const side = (r: FirstBuildReport) => r.skipped ?? r.error ?? (r.failed.length > 0 ? `${r.failed.length} run(s) failed` : "");
  const phases = (r: FirstBuildReport) =>
    Object.entries(r.summary?.phasesMs ?? {})
      .map(([p, s]) => `${p} ${minutes(s.p50)}`)
      .join(", ") || "n/a";
  return [
    `First build: \`${after.firstBuild}\`. Before: a fresh machine of \`${before.snapshotId}\` (no dev tree) sets up and builds; after: a fresh machine of \`${after.snapshotId}\` fetches and builds the same commit.`,
    "",
    "| | Before | After |",
    "| --- | --- | --- |",
    `| Time to first build, p50 (min to max) | ${cell(before.summary?.totalMs, minutes)} | ${cell(after.summary?.totalMs, minutes)} |`,
    `| Phases, p50 | ${phases(before)} | ${phases(after)} |`,
    `| Create to daemon ready, p50 (min to max) | ${cell(before.summary?.createToReadyMs, minutes)} | ${cell(after.summary?.createToReadyMs, minutes)} |`,
    `| Root disk used at create | ${cell(before.summary?.rootUsedBytes, gigabytes)} | ${cell(after.summary?.rootUsedBytes, gigabytes)} |`,
    `| Commit built | ${before.runs[0]?.head.slice(0, 12) ?? "n/a"} | ${after.runs[0]?.head.slice(0, 12) ?? "n/a"} |`,
    ...(side(before) || side(after) ? [`| Notes | ${side(before)} | ${side(after)} |`] : []),
  ].join("\n");
}

function argValue(name: string, argv: readonly string[]): string | undefined {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : undefined;
}

export async function main(argv = process.argv): Promise<number> {
  const reportAt = argv.indexOf("--report");
  if (reportAt >= 0) {
    const [before, after] = argv.slice(reportAt + 1, reportAt + 3).map((file) => JSON.parse(readFileSync(file, "utf8")) as FirstBuildReport);
    if (!before || !after) throw new Error("usage: first-build.ts --report <before.json> <after.json>");
    console.log(reportTable(before, after));
    return 0;
  }
  const mode = argValue("--mode", argv);
  const snapshotId = argValue("--snapshot", argv);
  const tag = argValue("--tag", argv);
  const runs = Number(argValue("--runs", argv) ?? 3);
  if ((mode !== "before" && mode !== "after") || !snapshotId?.startsWith("sh-") || !tag || !Number.isInteger(runs) || runs < 1) {
    throw new Error("usage: first-build.ts --mode before|after --snapshot <sh-id> --tag <tag> [--ref <sha>] [--runs 3] [--out-dir <dir>]");
  }
  const report = await measure({ mode, snapshotId, tag, ref: argValue("--ref", argv) ?? "", runs, outDir: path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}`) });
  console.log(JSON.stringify(report.summary ?? report.skipped ?? report.error ?? null));
  for (const failure of report.failed) console.error(`FAILED ${failure}`);
  return report.error || report.failed.length > 0 ? 1 : 0;
}
