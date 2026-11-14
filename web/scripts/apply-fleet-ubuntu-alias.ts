#!/usr/bin/env bun
/**
 * Adds the `ubuntu` alias for the work user (devboxUbuntuAliasCommand, the
 * exact command the image bake runs) to running Freestyle machines that were
 * baked before it. The command is idempotent and changes only /etc/passwd,
 * /etc/shadow, /etc/group, the work user's sudoers drop-in and the
 * /home/ubuntu link: no restart, no terminal ends.
 *
 * An exec wakes a paused machine, so this runs only on machines the provider
 * reports `running`; every other machine is listed as skipped. Run it again
 * later to reach machines that were paused this time.
 *
 * Usage (from web/):
 *   FREESTYLE_API_KEY=... bun scripts/apply-fleet-ubuntu-alias.ts --vm <id> [--vm <id> ...]
 *   FREESTYLE_API_KEY=... bun scripts/apply-fleet-ubuntu-alias.ts --vms-file <file>   # first column per line
 *     [--dry-run]   print each machine's state and what would run, change nothing
 *
 * Canary first: run one machine you own, then the rest.
 */
import { Freestyle } from "freestyle";
import { readFileSync } from "node:fs";
import { shellQuote } from "../services/vms/drivers/cmuxTuiDaemon";
import { devboxUbuntuAliasCommand } from "../services/vms/images/workUser";

const argValues = (name: string): string[] =>
  process.argv.flatMap((arg, index) => (arg === name && process.argv[index + 1] ? [process.argv[index + 1]] : []));
const hasFlag = (name: string): boolean => process.argv.includes(name);

/** Every entry must be a machine id: a typo must stop the run, not shrink it. */
function machineIds(): string[] {
  const fromFile = argValues("--vms-file")[0];
  const entries = [
    ...argValues("--vm"),
    ...(fromFile ? readFileSync(fromFile, "utf8").split("\n").map((line) => line.trim().split(/\s+/)[0] ?? "") : []),
  ].map((entry) => entry.trim()).filter((entry) => entry !== "");
  const invalid = entries.filter((entry) => !/^vm-[0-9a-f]{32}$/.test(entry));
  if (invalid.length > 0) throw new Error(`not machine ids: ${invalid.join(", ")}`);
  if (entries.length === 0) throw new Error("no machines: pass --vm <id> or --vms-file <file>");
  return [...new Set(entries)];
}

const apiKey = process.env.FREESTYLE_API_KEY;
if (!apiKey) throw new Error("FREESTYLE_API_KEY is required");
const freestyle = new Freestyle({ apiKey, ...(process.env.FREESTYLE_API_URL ? { baseUrl: process.env.FREESTYLE_API_URL } : {}) });
const dryRun = hasFlag("--dry-run");
const command = `sudo -n sh -c ${shellQuote(devboxUbuntuAliasCommand())}`;

async function apply(id: string): Promise<string> {
  try {
    const { state } = await freestyle.vms.get(id);
    if (state !== "running") return `SKIP ${state}: an exec would wake it`;
    if (dryRun) return "WOULD apply";
    const result = await freestyle.vms.ref(id).exec({ command, timeoutMs: 60_000 });
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
    return output.endsWith("ubuntu-alias-ok") ? "OK" : `FAIL ${output.slice(-300)}`;
  } catch (error) {
    return `ERR ${error instanceof Error ? error.message : String(error)}`;
  }
}

const ids = machineIds();
console.log(`${dryRun ? "dry run: " : ""}${ids.length} machine(s)`);
const results = await Promise.all(ids.map(async (id) => [id, await apply(id)] as const));
for (const [id, result] of results) console.log(`${id}\t${result}`);
if (results.some(([, result]) => /^(FAIL|ERR)/.test(result))) process.exitCode = 1;
