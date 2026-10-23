#!/usr/bin/env bun
/**
 * Upgrades cmux-tui in place on running Freestyle machines without ending a
 * terminal. docs/cloud-guest-upgrades.md is the contract and the runbook.
 *
 * Each machine gets a fresh run directory under /var/lib/cmux-tui-upgrade with
 * the pinned install command (`cmuxTuiInstallCommand`, the exact command the
 * image bake runs), the current state-mount helper, and the guest script
 * `scripts/cloud-vm/cmux-tui-upgrade.sh`,
 * which runs detached as root, holds a per-machine lock, and writes one result
 * line. This runner only starts the script and polls the result; the guest
 * script owns every safety check and the rollback.
 *
 * The target defaults to the cmux-tui build the default image bakes, so an
 * upgraded machine runs what a new machine runs. It never changes database
 * rows: a machine created before the snapshot-v2 contract still needs its
 * `cmuxTuiContract` backfilled (see the doc) after an OK result.
 *
 * Usage (from web/):
 *   FREESTYLE_API_KEY=... bun scripts/upgrade-fleet-cmux-tui.ts --vm <id> [--vm <id> ...]
 *   FREESTYLE_API_KEY=... bun scripts/upgrade-fleet-cmux-tui.ts --vms-file <file>   # first column per line
 *     [--commit <40-hex>]   pin another published build instead of the default image's
 *     [--dry-run]           print the target and machines, change nothing
 *
 * Canary first: run one machine you own, attach from the Mac, then the rest.
 */
import { Freestyle } from "freestyle";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CMUX_TUI_STATE_MOUNT_HELPER_PATH, readImageManifest } from "./devbox-image-common";
import { cmuxTuiInstallCommand, parseCmuxTuiManifest, shellQuote } from "../services/vms/drivers/cmuxTuiDaemon";

const argValues = (name: string): string[] =>
  process.argv.flatMap((arg, index) => (arg === name && process.argv[index + 1] ? [process.argv[index + 1]] : []));
const argValue = (name: string): string | undefined => argValues(name)[0];
const hasFlag = (name: string): boolean => process.argv.includes(name);

const GUEST_DIR = "/var/lib/cmux-tui-upgrade";
const POLL_INTERVAL_MS = 15_000;
const POLL_DEADLINE_MS = 30 * 60_000;
const guestScript = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "cloud-vm/cmux-tui-upgrade.sh"),
  "utf8",
);
const stateMountScript = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "../services/vms/images/devbox/cmux-tui-state-mount"),
  "utf8",
);

function defaultImageCommit(): string {
  const commits = new Set(
    readImageManifest()
      .images.filter((image) => image.provider === "freestyle" && image.defaultForKind)
      .map((image) => image.cmuxTuiCommit)
      .filter((commit): commit is string => typeof commit === "string"),
  );
  if (commits.size !== 1) {
    throw new Error(`default Freestyle images bake ${commits.size} cmux-tui builds; pass --commit`);
  }
  return [...commits][0];
}

/** Every entry must be a machine id: a typo must stop the run, not shrink it. */
function machineIds(): string[] {
  const fromFile = argValue("--vms-file");
  const entries = [
    ...argValues("--vm"),
    ...(fromFile ? readFileSync(fromFile, "utf8").split("\n").map((line) => line.trim().split(/\s+/)[0] ?? "") : []),
  ].map((entry) => entry.trim()).filter((entry) => entry !== "");
  const invalid = entries.filter((entry) => !/^vm-[0-9a-f]{32}$/.test(entry));
  if (invalid.length > 0) throw new Error(`not machine ids: ${invalid.join(", ")}`);
  if (entries.length === 0) throw new Error("no machines: pass --vm <id> or --vms-file <file>");
  return [...new Set(entries)];
}

/** `echo <base64> | base64 -d`: the provider exec body carries no quoting of its own. */
function writeFileCommand(file: string, content: string): string {
  return `echo ${Buffer.from(content).toString("base64")} | base64 -d > ${file}`;
}

const commit = argValue("--commit") ?? defaultImageCommit();
const manifestUrl = `https://files.cmux.com/cmux-tui/${commit}/manifest.json`;
const source = parseCmuxTuiManifest(manifestUrl, await (await fetch(manifestUrl)).json());
const ids = machineIds();
console.log(`target cmux-tui ${source.commit} sha256 ${source.sha256}; ${ids.length} machine(s)`);
if (hasFlag("--dry-run")) {
  for (const id of ids) console.log(`  ${id}`);
  process.exit(0);
}

const apiKey = process.env.FREESTYLE_API_KEY;
if (!apiKey) throw new Error("FREESTYLE_API_KEY is required");
const freestyle = new Freestyle({ apiKey, ...(process.env.FREESTYLE_API_URL ? { baseUrl: process.env.FREESTYLE_API_URL } : {}) });

// One directory per run: concurrent runs never share an install command or result.
const runDir = `${GUEST_DIR}/run-${new Date().toISOString().replace(/[^0-9]/g, "").slice(0, 14)}-${source.commit.slice(0, 12)}`;
const launch = [
  `mkdir -p ${runDir}`,
  writeFileCommand(`${runDir}/install.cmd`, cmuxTuiInstallCommand(source)),
  writeFileCommand(`${runDir}/upgrade.sh`, guestScript),
  writeFileCommand(`${runDir}/state-mount.sh`, stateMountScript),
  `(setsid nohup sh ${runDir}/upgrade.sh ${source.sha256} ${source.commit} ${runDir} ${CMUX_TUI_STATE_MOUNT_HELPER_PATH} </dev/null >/dev/null 2>&1 &)`,
  "echo launched",
].join(" && ");

async function run(id: string, command: string): Promise<string> {
  try {
    const result = await freestyle.vms.ref(id).exec({ command: `sudo -n sh -c ${shellQuote(command)}`, timeoutMs: 60_000 });
    return `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
  } catch (error) {
    return `ERR ${error instanceof Error ? error.message : String(error)}`;
  }
}

const results = new Map<string, string>();
await Promise.all(ids.map(async (id) => {
  const launched = await run(id, launch);
  if (!launched.endsWith("launched")) results.set(id, `FAIL launch: ${launched.slice(0, 200)}`);
}));

const deadline = Date.now() + POLL_DEADLINE_MS;
while (results.size < ids.length && Date.now() < deadline) {
  await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  await Promise.all(ids.filter((id) => !results.has(id)).map(async (id) => {
    const line = await run(id, `cat ${runDir}/result 2>/dev/null || echo running`);
    if (!/^(running|ERR)/.test(line)) results.set(id, line);
  }));
}
for (const id of ids) console.log(`${id}\t${results.get(id) ?? "TIMEOUT still running; read the result file later"}`);
