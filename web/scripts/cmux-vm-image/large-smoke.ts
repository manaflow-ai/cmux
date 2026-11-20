/**
 * Smoke test for the large image (large-image.ts): clones of it boot at LARGE_IMAGE_SHAPE with no resize call.
 *
 * Usage (from web/):
 *   bun ../images/cmux-vm/large-smoke.ts --snapshot <sh-id> --tag <tag> [--clones 2] [--out-dir <dir>]
 *
 * The large image holds the tree the small image's smoke (smoke.ts) already checks, so this checks only what the
 * second snapshot can change: every clone's daemon listens; every clone shows LARGE_IMAGE_SHAPE (4 vCPU, 16 GiB, a 64 GiB
 * root filesystem) the first time it is asked, and this script never calls resize; two clones are bound to their own
 * instance with their own daemon identity and SSH host key (the builder ran on between the two snapshots); and
 * the machine-health guards (percentages of RAM) apply at this size. Boot latency is recorded the way smoke.ts
 * records it, and printed beside the small image's when its report is in the out dir.
 *
 * Clones are named cmuxnp-dev-vmimg-<tag>-large-smoke-<i>, recorded in <out-dir>/large/resources.tsv (the large
 * image's own ledger) and deleted whatever happens. Writes <out-dir>/smoke-large-<tag>.json.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { argValue, deleteVm, freestyleClient, Ledger, run, type Vm } from "./guest";
import { type GuestShape, guestShape, LARGE_IMAGE_SHAPE, shapeProblems } from "./large-image";
import { machineHealthSmokeCommand, machineHealthSmokeProblems } from "./machine-health";
import { daemonListening, IDENTITY_PROBE, imageLatency, kv, measureClone, measureCloneRetrying, PROVIDER_RETRIES, providerLatency } from "./smoke";

type Clone = { vm: Vm; vmId: string; name: string };
type Check = { ok: boolean; detail: string };
export type LargeSmokeReport = { snapshotId: string; size: typeof LARGE_IMAGE_SHAPE; checks: Record<string, Check>; passed?: boolean; error?: string; [key: string]: unknown };

/** The shape check over every clone: each must show the large size on its first read. */
export function bootShapeCheck(shapes: readonly GuestShape[]): Check {
  const problems = shapes.flatMap((shape, i) => shapeProblems(shape).map((p) => `clone ${i + 1}: ${p}`));
  return { ok: shapes.length > 0 && problems.length === 0, detail: problems.join("\n") || `${shapes.length} clones booted at ${JSON.stringify(shapes[0])} with no resize` };
}

/** Two clones of one snapshot must each be bound to their own instance, with their own daemon identity and host key. */
export function identityChecks(ids: ReadonlyArray<Record<string, string>>): Record<string, Check> {
  const [a, b] = ids;
  return {
    "daemon-bound": { ok: ids.length === 2 && ids.every((id) => Boolean(id.instance) && id.instance === id.bound && id["identity-present"] === "1"), detail: ids.map((id) => `${id.instance} bound ${id.bound}`).join(" | ") },
    "daemon-identity-differs": { ok: ids.length === 2 && Boolean(a?.daemon) && a?.daemon !== b?.daemon, detail: `${a?.daemon?.slice(0, 12)} vs ${b?.daemon?.slice(0, 12)}` },
    "ssh-host-key-differs": { ok: ids.length === 2 && Boolean(a?.sshkey) && a?.sshkey !== b?.sshkey, detail: `${a?.sshkey} vs ${b?.sshkey}` },
  };
}

export async function largeSmoke(options: { snapshotId: string; tag: string; clones: number; outDir: string }): Promise<LargeSmokeReport> {
  mkdirSync(options.outDir, { recursive: true });
  const ledger = new Ledger(path.join(options.outDir, "large", "resources.tsv"));
  const fs = freestyleClient();
  const report: LargeSmokeReport = { snapshotId: options.snapshotId, size: LARGE_IMAGE_SHAPE, checks: {} };
  const check = (name: string, c: Check) => {
    report.checks[name] = c;
    console.log(`${c.ok ? "PASS" : "FAIL"} ${name}: ${c.detail.split("\n").slice(0, 6).join(" | ")}`);
  };
  const prefix = `cmuxnp-dev-vmimg-${options.tag}-large-smoke-`;
  const kept: Clone[] = [];
  const rows: Array<Record<string, number | string>> = [];
  const shapes: GuestShape[] = [];
  try {
    const budget = { left: PROVIDER_RETRIES, unfinished: [] as string[] };
    // One at a time, as smoke.ts: create latency is part of what this measures.
    for (let i = 1; i <= options.clones; i++) {
      const { clone, row } = await measureCloneRetrying(
        (attempt) => measureClone(fs, ledger, `${prefix}${i}${attempt ? `r${attempt}` : ""}`, options.snapshotId),
        (c) => deleteVm(c.vm, c.vmId, c.name, ledger),
        budget,
      );
      kept.push(clone);
      // The first read after the clone is ready: no resize ran, and none runs anywhere in this script.
      const shape = await guestShape(clone.vm);
      shapes.push(shape);
      rows.push({ ...row, cpu: shape.cpu, memoryMb: shape.memoryMb, rootMb: shape.rootMb });
      console.log(`clone ${i} ${clone.vmId}: ${JSON.stringify(rows.at(-1))}`);
      if (kept.length > 2) {
        await deleteVm(clone.vm, clone.vmId, clone.name, ledger);
        kept.pop();
      }
    }
    report.clones = rows;
    report.providerLatency = providerLatency(rows, budget.unfinished);
    report.imageLatency = imageLatency(rows);
    console.log(`INFO large provider-latency ${JSON.stringify(report.providerLatency)}`);
    console.log(`INFO large image-latency ${JSON.stringify(report.imageLatency)}`);
    // The small image's smoke of the same run, when it is here: the two boot latencies side by side.
    const small = path.join(options.outDir, `smoke-${options.tag}.json`);
    if (existsSync(small)) {
      const smallRows = (JSON.parse(readFileSync(small, "utf8")) as { clones?: Array<Record<string, number | string>> }).clones ?? [];
      report.smallImageLatency = imageLatency(smallRows);
      report.smallProviderLatency = providerLatency(smallRows, []);
      console.log(`INFO small image-latency ${JSON.stringify(report.smallImageLatency)}`);
      console.log(`INFO small provider-latency ${JSON.stringify(report.smallProviderLatency)}`);
    }
    check("daemon-listening", { ok: daemonListening(rows), detail: JSON.stringify(report.imageLatency) });
    check("boots-at-large-size", bootShapeCheck(shapes));
    const ids = await Promise.all(kept.slice(0, 2).map((c) => run(c.vm, IDENTITY_PROBE, 60_000).then((r) => kv(r.stdout))));
    for (const [name, c] of Object.entries(identityChecks(ids))) check(name, c);
    const health = await run(kept[0].vm, machineHealthSmokeCommand(DEVBOX_WORK_USER), 120_000);
    const healthProblems = machineHealthSmokeProblems(health.stdout);
    check("machine-health", { ok: healthProblems.length === 0, detail: healthProblems.join("\n") || health.stdout.trim() });
  } catch (error) {
    report.error = String(error);
    console.error(`LARGE SMOKE FAILED: ${report.error}`);
  } finally {
    for (const c of kept) await deleteVm(c.vm, c.vmId, c.name, ledger).catch((error) => console.error(`could not delete ${c.vmId}: ${String(error)}; the run's cleanup retries it`));
    for (const row of ledger.live().filter((r) => r.kind === "vm" && r.name.startsWith(prefix))) {
      try {
        await fs.vms.delete(row.id);
        ledger.record(row.id, row.kind, row.name, "deleted");
      } catch (error) {
        console.error(`could not delete ${row.id} (${row.name}): ${String(error)}; the run's cleanup retries it`);
      }
    }
  }
  report.passed = !report.error && Object.values(report.checks).every((c) => c.ok);
  writeFileSync(path.join(options.outDir, `smoke-large-${options.tag}.json`), `${JSON.stringify(report, null, 2)}\n`);
  console.log(report.passed ? "LARGE SMOKE PASSED" : "LARGE SMOKE FAILED");
  return report;
}

export async function main(argv = process.argv): Promise<number> {
  const snapshotId = argValue("--snapshot", argv);
  const tag = argValue("--tag", argv);
  const clones = Number(argValue("--clones", argv) ?? 2);
  if (!snapshotId?.startsWith("sh-") || !tag) throw new Error("usage: large-smoke.ts --snapshot <sh-id> --tag <tag> [--clones 2] [--out-dir <dir>]");
  if (!Number.isInteger(clones) || clones < 2) throw new Error("--clones must be a whole number of at least 2 (the identity checks compare two clones)");
  const report = await largeSmoke({ snapshotId, tag, clones, outDir: path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}`) });
  return report.passed ? 0 : 1;
}
