/**
 * Does baking package caches into the image make a first session faster? Measured, not assumed:
 *   cold:  a machine of the image runs a first session's installs (FIRST_SESSION_WORKLOADS) as the work user;
 *   warm:  a second machine of the image runs the prewarm (what a bake step would run: the same package
 *          managers filling their caches, then the project dirs removed), is snapshotted, and a machine of
 *          that snapshot runs the same installs.
 * The warm side is the best case: its caches hold exactly the packages the workloads ask for. A real project
 * overlaps them only partly, so a workload that does not get faster here never would. Every machine and the
 * temporary snapshot are deleted whatever happens.
 *
 * Usage (from web/): bun ../images/cmux-vm/first-session.ts --snapshot <sh-id> --tag <tag> [--out-dir <dir>]
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run, type Vm } from "./guest";
import { PREFILL_NODE_DEPS } from "./dep-cache";
import { sq } from "./lock";

/** A web app's and a Python service's usual first installs; unpinned, as a person's new project resolves them. */
const NODE_DEPS = PREFILL_NODE_DEPS;
const PY_DEPS = ["fastapi", "pydantic", "requests", "pytest", "numpy", "httpx"];

// The work user's login shell has no corepack on PATH (run 42082074422), so pnpm and yarn come through npx, as a
// person's first `npx pnpm` would; corepack would otherwise ask before downloading a package manager.
const asUser = (script: string) => `runuser -u ${DEVBOX_WORK_USER} -- env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 bash -lc ${sq(`cd ${DEVBOX_WORK_HOME} && ${script}`)}`;
const project = (dir: string) =>
  `rm -rf ${dir} && mkdir -p ${dir} && cd ${dir} && printf '%s' '{"name":"first-session","private":true}' > package.json`;

/** One first session's installs, each timed alone, in a fresh dir. */
export const FIRST_SESSION_WORKLOADS: Record<string, string> = {
  // First, so the npm cache measured right after it holds only what dep-cache.ts bakes.
  "npm-install": `${project("/tmp/fs-npm")} && npm install --no-audit --no-fund --loglevel=error ${NODE_DEPS.join(" ")}`,
  "npx-pnpm": "npx --yes pnpm@10 --version",
  "npx-yarn": "npx --yes yarn@1 --version",
  "bun-install": `${project("/tmp/fs-bun")} && bun add ${NODE_DEPS.join(" ")} >/dev/null`,
  "pnpm-install": `${project("/tmp/fs-pnpm")} && npx --yes pnpm@10 add ${NODE_DEPS.join(" ")} >/dev/null`,
  "uv-install": `rm -rf /tmp/fs-uv && mkdir -p /tmp/fs-uv && cd /tmp/fs-uv && uv venv -q && uv pip install -q ${PY_DEPS.join(" ")}`,
};

/** The bake step under test: every workload once, each its own exec (the provider caps one at 300 s). */
export const PREWARM_STEPS: readonly string[] = [
  ...Object.values(FIRST_SESSION_WORKLOADS).map(asUser),
  // Only the package caches stay; the project dirs were the vehicle.
  "rm -rf /tmp/fs-npm /tmp/fs-bun /tmp/fs-pnpm /tmp/fs-uv",
  "sync && echo 3 > /proc/sys/vm/drop_caches",
];

/** Bytes each package manager's cache takes on the seed after the prewarm (the cost of baking it). */
const CACHE_SIZES = `du -sb ${["/.npm/_cacache", "/.bun/install/cache", "/.local/share/pnpm", "/.cache/uv", "/.npm/_npx"].map((d) => DEVBOX_WORK_HOME + d).join(" ")} 2>/dev/null; true`;

type Side = { vmId: string; firstExecMs: number; workloadsMs: Record<string, number>; failed: Record<string, string> };

async function timeWorkloads(vm: Vm): Promise<Pick<Side, "workloadsMs" | "failed">> {
  const workloadsMs: Record<string, number> = {};
  const failed: Record<string, string> = {};
  for (const [name, script] of Object.entries(FIRST_SESSION_WORKLOADS)) {
    const t = Date.now();
    const r = await run(vm, asUser(script), 290_000);
    workloadsMs[name] = Date.now() - t;
    if (r.code !== 0) failed[name] = (r.stderr || r.stdout).slice(-400);
  }
  return { workloadsMs, failed };
}

export async function main(argv = process.argv): Promise<number> {
  const snapshotId = argValue("--snapshot", argv);
  const tag = argValue("--tag", argv);
  if (!snapshotId || !tag) throw new Error("usage: first-session.ts --snapshot <sh-id> --tag <tag> [--out-dir <dir>]");
  const outDir = path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}`);
  mkdirSync(outDir, { recursive: true });
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const fs = freestyleClient();
  const report: Record<string, unknown> = { snapshotId, nodeDeps: NODE_DEPS, pyDeps: PY_DEPS };
  const live: Array<{ vm: Vm; vmId: string; name: string }> = [];
  let warmSnapshot: string | undefined;
  const boot = async (name: string, from: string) => {
    const c = await createVm(fs, ledger, { name, snapshotId: from });
    live.push({ vm: c.vm, vmId: c.vmId, name });
    return { ...c, firstExecMs: await firstExec(c.vm, c.t0) };
  };
  try {
    // Cold and the prewarm at once: separate machines of the same image.
    // Both boots settle before anything throws, so a machine that comes up after the other failed is still in `live`.
    const boots = await Promise.allSettled([boot(`cmuxnp-dev-vmimg-${tag}-fs-cold`, snapshotId), boot(`cmuxnp-dev-vmimg-${tag}-fs-seed`, snapshotId)]);
    const bootFailure = boots.find((b) => b.status === "rejected");
    if (bootFailure) throw bootFailure.reason;
    const [cold, seed] = boots.map((b) => (b as PromiseFulfilledResult<Awaited<ReturnType<typeof boot>>>).value);
    const [coldTimes, prewarm] = await Promise.all([
      timeWorkloads(cold.vm),
      (async () => {
        const t = Date.now();
        const readSizes = async () => Object.fromEntries((await run(seed.vm, CACHE_SIZES)).stdout.trim().split("\n").filter(Boolean).map((l) => { const [b, p] = l.split("\t"); return [p, Number(b)]; }));
        let npmOnly: Record<string, number> = {};
        for (const [i, step] of PREWARM_STEPS.entries()) {
          const r = await run(seed.vm, step, 290_000);
          if (r.code !== 0) throw new Error(`prewarm failed: ${(r.stderr || r.stdout).slice(-600)}`);
          // The npm cache right after the npm install alone: what the image bakes (dep-cache.ts), before npx adds to it.
          if (Object.keys(FIRST_SESSION_WORKLOADS)[i] === "npm-install") npmOnly = await readSizes();
        }
        const ms = Date.now() - t;
        return { ms, npmInstallCacheBytes: npmOnly[`${DEVBOX_WORK_HOME}/.npm/_cacache`], cacheBytes: await readSizes() };
      })(),
    ]);
    report.cold = { vmId: cold.vmId, firstExecMs: cold.firstExecMs, ...coldTimes } satisfies Side;
    report.prewarm = prewarm;
    console.log(`FIRST_SESSION cache npm-install-only ${(Number(prewarm.npmInstallCacheBytes) / 1048576).toFixed(1)} MB`);
    for (const [dir, bytes] of Object.entries(prewarm.cacheBytes)) console.log(`FIRST_SESSION cache ${dir} ${(Number(bytes) / 1048576).toFixed(1)} MB`);
    report.rootUsedBytes = { before: (await run(cold.vm, "df -B1 --output=used / | tail -1")).stdout.trim(), afterPrewarm: (await run(seed.vm, "df -B1 --output=used / | tail -1")).stdout.trim() };
    const snap = await seed.vm.snapshot({ displayName: `cmuxnp-dev-vmimg-${tag}-fs-warm`, slug: `cmuxnp-dev-vmimg-${tag}-fs-warm` });
    warmSnapshot = snap.snapshotId;
    ledger.record(warmSnapshot, "snapshot", `cmuxnp-dev-vmimg-${tag}-fs-warm`);
    const warm = await boot(`cmuxnp-dev-vmimg-${tag}-fs-warm-1`, warmSnapshot);
    report.warm = { vmId: warm.vmId, firstExecMs: warm.firstExecMs, ...(await timeWorkloads(warm.vm)) } satisfies Side;
    // A failed install's time is not a measurement: the probe fails rather than report it.
    const failures = [...Object.keys(coldTimes.failed).map((w) => `cold ${w}`), ...Object.keys((report.warm as Side).failed).map((w) => `warm ${w}`)];
    if (failures.length) throw new Error(`workloads failed: ${failures.join(", ")}`);
  } catch (error) {
    report.error = String(error);
  } finally {
    // Every resource gets its delete whatever another one's does; only a delete that went through is recorded.
    await Promise.allSettled(live.map((c) => deleteVm(c.vm, c.vmId, c.name, ledger)));
    if (warmSnapshot) {
      const id = warmSnapshot;
      try {
        await fs.vms.snapshots.delete(id);
        ledger.record(id, "snapshot", `cmuxnp-dev-vmimg-${tag}-fs-warm`, "deleted");
      } catch (error) {
        console.error(`could not delete ${id}: ${String(error)}; the run's cleanup retries it from the ledger`);
      }
    }
  }
  const cold = report.cold as Side | undefined;
  const warm = report.warm as Side | undefined;
  if (cold && warm && !report.error) {
    report.table = Object.keys(FIRST_SESSION_WORKLOADS).map((w) => ({ workload: w, coldMs: cold.workloadsMs[w], warmMs: warm.workloadsMs[w], savedMs: cold.workloadsMs[w] - warm.workloadsMs[w] }));
    for (const row of report.table as Array<Record<string, unknown>>) console.log(`FIRST_SESSION ${row.workload} cold=${row.coldMs} warm=${row.warmMs} saved=${row.savedMs}`);
  }
  writeFileSync(path.join(outDir, `first-session-${tag}.json`), `${JSON.stringify(report, null, 2)}\n`);
  console.log(report.error ? `FIRST_SESSION FAILED: ${String(report.error)}` : "FIRST_SESSION DONE");
  return report.error ? 1 : 0;
}
