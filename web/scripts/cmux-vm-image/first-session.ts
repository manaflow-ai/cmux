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
import { sq } from "./lock";

/** A web app's and a Python service's usual first installs; unpinned, as a person's new project resolves them. */
const NODE_DEPS = ["react", "react-dom", "vite", "typescript", "@types/react", "@types/node", "eslint", "prettier", "zod", "vitest"];
const PY_DEPS = ["fastapi", "pydantic", "requests", "pytest", "numpy", "httpx"];

// corepack would otherwise ask before downloading a package manager.
const asUser = (script: string) => `runuser -u ${DEVBOX_WORK_USER} -- env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 bash -lc ${sq(`cd ${DEVBOX_WORK_HOME} && ${script}`)}`;
const project = (dir: string) =>
  `rm -rf ${dir} && mkdir -p ${dir} && cd ${dir} && printf '%s' '{"name":"first-session","private":true}' > package.json`;

/** One first session's installs, each timed alone, in a fresh dir. */
export const FIRST_SESSION_WORKLOADS: Record<string, string> = {
  "corepack-pnpm": "corepack pnpm --version",
  "corepack-yarn": "corepack yarn --version",
  "npm-install": `${project("/tmp/fs-npm")} && npm install --no-audit --no-fund --loglevel=error ${NODE_DEPS.join(" ")}`,
  "bun-install": `${project("/tmp/fs-bun")} && bun add ${NODE_DEPS.join(" ")} >/dev/null`,
  "pnpm-install": `${project("/tmp/fs-pnpm")} && corepack pnpm add ${NODE_DEPS.join(" ")} >/dev/null`,
  "uv-install": `rm -rf /tmp/fs-uv && mkdir -p /tmp/fs-uv && cd /tmp/fs-uv && uv venv -q && uv pip install -q ${PY_DEPS.join(" ")}`,
};

/** The bake step under test: every workload once, each its own exec (the provider caps one at 300 s). */
export const PREWARM_STEPS: readonly string[] = [
  ...Object.values(FIRST_SESSION_WORKLOADS).map(asUser),
  // Only the package caches stay; the project dirs were the vehicle.
  "rm -rf /tmp/fs-npm /tmp/fs-bun /tmp/fs-pnpm /tmp/fs-uv",
  `du -sb ${DEVBOX_WORK_HOME}/.npm ${DEVBOX_WORK_HOME}/.bun/install/cache ${DEVBOX_WORK_HOME}/.local/share/pnpm ${DEVBOX_WORK_HOME}/.cache/uv ${DEVBOX_WORK_HOME}/.cache/node/corepack 2>/dev/null; true`,
  "sync && echo 3 > /proc/sys/vm/drop_caches",
];

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
        let out = "";
        for (const step of PREWARM_STEPS) {
          const r = await run(seed.vm, step, 290_000);
          if (r.code !== 0) throw new Error(`prewarm failed: ${(r.stderr || r.stdout).slice(-600)}`);
          out = r.stdout;
        }
        return { ms: Date.now() - t, sizes: out.trim().split("\n").slice(-5) };
      })(),
    ]);
    report.cold = { vmId: cold.vmId, firstExecMs: cold.firstExecMs, ...coldTimes } satisfies Side;
    report.prewarm = prewarm;
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
