#!/usr/bin/env bun
/**
 * Puts the guest DNS fallback (`cmux-dns`, cmux issue 26640) on running
 * Freestyle machines. New machines get it from the image; a running machine
 * keeps resolving straight through the platform resolver, which intermittently
 * answers SERVFAIL or nothing for every name, until this runs.
 * docs/cloud-guest-upgrades.md is the runbook; the guest commands are in
 * scripts/cloud-vm/dns-fallback-fleet.ts.
 *
 * It prints one line per machine: `OK installed`, `SKIP current` (already
 * there), `SKIP no-systemd` (not a devbox guest), `SKIP custom-resolv-conf`
 * (the user, a VPN or Tailscale owns DNS), `SKIP busy` (another run holds the
 * machine), `SKIP not-running <state>` (left asleep: a provider exec would
 * wake it), `FAIL ...` with what was put back, or `ERR` when the provider call
 * failed. After a batch with a FAIL or ERR it stops and lists the machines it
 * did not start, and exits 1. Terminals and their processes keep running.
 *
 * It changes customer machines as root. Tell owners first, and canary one
 * machine you own and one consenting customer machine before any batch
 * (docs/cloud-guest-upgrades.md).
 *
 * Usage (from web/):
 *   FREESTYLE_API_KEY=... bun scripts/install-fleet-dns-fallback.ts --vm <id> [--vm <id> ...]
 *   FREESTYLE_API_KEY=... bun scripts/install-fleet-dns-fallback.ts --vms-file <file>   # first column per line
 *     [--remove]    take the fallback off again (rollback)
 *     [--dry-run]   print the machines, change nothing
 *
 * Canary first: run one machine you own, check `getent ahostsv4 github.com` on it, then the rest.
 */
import { Freestyle } from "freestyle";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { shellQuote } from "../services/vms/drivers/cmuxTuiDaemon";
import {
  dnsFallbackInstallCommand,
  dnsFallbackResult,
  dnsFallbackUninstallCommand,
  parseFleetArgs,
  parseMachineIds,
  runInBatches,
} from "./cloud-vm/dns-fallback-fleet";

/** Machines per batch: each exec is one provider call of a few seconds. */
const CONCURRENCY = 8;
/**
 * `systemctl enable --now` waits for the stub's ready signal (systemd's start
 * timeout, 90 s by default) before the probe and check run, and a failure
 * then rolls back; the exec must outlive all of it, or the rollback never runs.
 */
const EXEC_TIMEOUT_MS = 180_000;

const args = parseFleetArgs(process.argv.slice(2));
const ids = parseMachineIds([
  ...args.vms,
  ...(args.vmsFile ? readFileSync(args.vmsFile, "utf8").split("\n").map((line) => line.trim().split(/\s+/)[0] ?? "") : []),
]);
console.log(`${args.remove ? "remove" : "install"} the DNS fallback; ${ids.length} machine(s)`);
if (args.dryRun) {
  for (const id of ids) console.log(`  ${id}`);
  process.exit(0);
}

const apiKey = process.env.FREESTYLE_API_KEY;
if (!apiKey) throw new Error("FREESTYLE_API_KEY is required");
const freestyle = new Freestyle({ apiKey, ...(process.env.FREESTYLE_API_URL ? { baseUrl: process.env.FREESTYLE_API_URL } : {}) });

const script = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "../services/vms/images/devbox/cmux-dns"),
  "utf8",
);
const command = args.remove ? dnsFallbackUninstallCommand() : dnsFallbackInstallCommand(script);

/** A plain GET, which never resumes a paused machine (freestyleHealthInventory.ts, probeControl). */
async function machineState(id: string): Promise<string> {
  const response = await freestyle.fetch(`/v5/vms/${encodeURIComponent(id)}`, { method: "GET" });
  if (response.status === 404) return "gone";
  if (!response.ok) throw new Error(`state read: HTTP ${response.status}`);
  const state = ((await response.json()) as { state?: unknown })?.state;
  if (typeof state !== "string") throw new Error("state read: unreadable body");
  return state;
}

async function run(id: string): Promise<string> {
  try {
    const state = await machineState(id);
    if (state !== "running") return `SKIP not-running ${state}`;
    const result = await freestyle.vms.ref(id).exec({ command: `sudo -n sh -c ${shellQuote(command)}`, timeoutMs: EXEC_TIMEOUT_MS });
    if (result.statusCode === null || result.statusCode === undefined) {
      return `FAIL timeout after ${EXEC_TIMEOUT_MS / 1000} s, state unknown: run this machine again`;
    }
    return dnsFallbackResult(result.stdout ?? "", result.stderr ?? "");
  } catch (error) {
    return `ERR ${error instanceof Error ? error.message : String(error)}`;
  }
}

const { failed, notRun } = await runInBatches(ids, run, CONCURRENCY, (id, line) => console.log(`${id}\t${line}`));
for (const id of notRun) console.log(`${id}\tNOT RUN: stopped after a failure; read it, then run again`);
process.exit(failed > 0 ? 1 : 0);
