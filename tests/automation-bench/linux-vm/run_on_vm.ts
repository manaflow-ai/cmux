#!/usr/bin/env bun
/**
 * Runs vm_measure.py on a throwaway clone of a cmux VM image snapshot (run by hand, development
 * Freestyle account only; not a CI gate).
 *
 * Usage (from web/, after `bun install`):
 *   FREESTYLE_API_KEY_FILE=~/.secrets/freestyle-cmux-next-dev-20261004.key \
 *     bun ../tests/automation-bench/linux-vm/run_on_vm.ts --snapshot <sh-id> --out-dir <dir>
 *
 * The clone is named cmuxnp-dev-vmimg-measure-<time>, recorded in <out-dir>/resources.tsv and
 * deleted by its exact id at the end (also on failure). gedit is installed on the clone as the
 * computer-use fixture. vm_measure.py runs in a terminal of the clone's own daemon as the work
 * user, so the browser host is the one the daemon starts. The key is read from the file in this
 * process only and never printed.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run } from "../../../web/scripts/cmux-vm-image/guest";

const snapshotId = argValue("--snapshot", process.argv);
const outDir = path.resolve(argValue("--out-dir", process.argv) ?? "vm-measure-out");
if (!snapshotId?.startsWith("sh-")) throw new Error("usage: run_on_vm.ts --snapshot <sh-id> [--out-dir <dir>]");
mkdirSync(outDir, { recursive: true });

const WORK = "/tmp/cmux-vm-measure";
const DAEMON = "/opt/cmux/current/bin/cmux-tui --session cloud";
const ledger = new Ledger(path.join(outDir, "resources.tsv"));
const name = `cmuxnp-dev-vmimg-measure-${Date.now().toString(36)}`;
const { vm, vmId, t0 } = await createVm(freestyleClient(), ledger, { name, snapshotId });
try {
  console.log(`vm ${vmId} first exec ${await firstExec(vm, t0)} ms`);
  const apt = await run(vm, "DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends gedit >/dev/null 2>&1 && command -v gedit", 280_000);
  if (apt.code !== 0) throw new Error(`gedit install failed: ${apt.stderr.slice(-300)}`);
  await run(vm, `install -d -m 0755 -o cmux -g cmux ${WORK}`);
  await vm.fs.writeFile(`${WORK}/vm_measure.py`, readFileSync(path.join(import.meta.dir, "vm_measure.py"), "utf8"), { mode: 0o644 });
  await vm.fs.writeFile(`${WORK}/run.sh`, `cd ${WORK}\ntimeout 900 python3 vm_measure.py --out ${WORK}/result.json > ${WORK}/measure.log 2>&1\necho done > ${WORK}/done\n`, { mode: 0o644 });
  const versions = await run(vm, "/opt/cmux/current/bin/cmux-cua --version; /opt/cmux/current/bin/cmux-tui --version; $(tr '\\0' '\\n' < /proc/$(pgrep -f 'cmux-tui server [s]tart' | head -1)/environ | sed -n 's/^CMUX_BROWSER_HOST_BIN=//p') version; cat /etc/cmux/image-stamp");
  const start = await run(vm, `(${DAEMON} workspace name:measure show || ${DAEMON} workspace create --name measure) >/dev/null && ${DAEMON} workspace name:measure run --on-exit keep shell '. ${WORK}/run.sh' >/dev/null && echo started`, 60_000, "cmux");
  if (!start.stdout.includes("started")) throw new Error(`daemon terminal: ${start.stderr.slice(-300)}`);
  let done = false;
  for (let i = 0; i < 4 && !done; i++) done = (await run(vm, `for i in $(seq 1 240); do [ -e ${WORK}/done ] && exit 0; sleep 1; done; exit 1`, 260_000, "cmux")).code === 0;
  const log = (await run(vm, `cat ${WORK}/measure.log`)).stdout;
  writeFileSync(path.join(outDir, "measure.log"), `${versions.stdout}\n${log}`);
  try {
    writeFileSync(path.join(outDir, "result.json"), Buffer.from(await vm.fs.readFile(`${WORK}/result.json`)));
  } catch {
    // no result: the log says why
  }
  console.log(versions.stdout.trim());
  console.log(log.trim() || "no output (the measure did not finish)");
} finally {
  await deleteVm(vm, vmId, name, ledger);
  console.log(readFileSync(path.join(outDir, "resources.tsv"), "utf8").trim());
}
