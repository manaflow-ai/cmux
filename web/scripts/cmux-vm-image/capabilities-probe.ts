/**
 * The daemon handshake of a cmux VM image on one fresh clone (cmuxnp-dev-vmimg-<tag>-probe):
 * create, wait for the daemon, read its full `identify` (identify.ts), delete the clone.
 * Used to record or check an image's capability list (images/cmux-vm/channels/*.json
 * `cmux_tui.capabilities`) without a full smoke.
 *
 * Usage (from web/):
 *   bun scripts/cmux-vm-image/capabilities-probe.ts --snapshot <sh-id> --tag <tag> [--out-dir <dir>]
 * Writes <out-dir>/probe-<tag>.json and the ledger <out-dir>/resources.tsv.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { devboxWaitForDaemonCommand } from "../devbox-image-common";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run } from "./guest";
import { daemonIdentifyCommand, parseDaemonIdentify } from "./identify";

export async function main(argv = process.argv): Promise<number> {
  const snapshotId = argValue("--snapshot", argv);
  const tag = argValue("--tag", argv);
  if (!snapshotId?.startsWith("sh-") || !tag) throw new Error("usage: capabilities-probe.ts --snapshot <sh-id> --tag <tag> [--out-dir <dir>]");
  const outDir = path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}`);
  mkdirSync(outDir, { recursive: true });
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const name = `cmuxnp-dev-vmimg-${tag}-probe`;
  const fs = freestyleClient();
  const report: Record<string, unknown> = { snapshotId, name };
  const clone = await createVm(fs, ledger, { name, snapshotId });
  report.vmId = clone.vmId;
  try {
    await firstExec(clone.vm, clone.t0);
    const ready = await run(clone.vm, devboxWaitForDaemonCommand(90), 120_000);
    if (ready.code !== 0) throw new Error(`daemon not ready: ${ready.stdout.slice(-200)} ${ready.stderr.slice(-200)}`);
    const out = await run(clone.vm, daemonIdentifyCommand(), 60_000);
    if (out.code !== 0) throw new Error(`identify exit ${out.code}: ${out.stdout.slice(-300)} ${out.stderr.slice(-300)}`);
    report.identify = parseDaemonIdentify(out.stdout);
  } catch (error) {
    report.error = String(error);
  } finally {
    await deleteVm(clone.vm, clone.vmId, name, ledger);
  }
  writeFileSync(path.join(outDir, `probe-${tag}.json`), `${JSON.stringify(report, null, 2)}\n`);
  const identify = report.identify as { version?: string; capabilities?: string[] } | undefined;
  console.log(report.error ? `PROBE FAILED: ${String(report.error)}` : `PROBE ${snapshotId} ${identify?.version} ${identify?.capabilities?.length} capabilities`);
  return report.error ? 1 : 0;
}

if (import.meta.main) process.exit(await main());
