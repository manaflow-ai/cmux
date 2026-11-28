/**
 * Freestyle plumbing for the cmux VM image scripts: the client, a resource
 * ledger (every VM and snapshot id the moment it exists, so cleanup deletes
 * exactly what this run made), and logged guest steps.
 */
import { appendFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { Freestyle } from "freestyle";

export const BUILD_ENV = {
  PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
  DEBIAN_FRONTEND: "noninteractive",
  LANG: "C.UTF-8",
};
/** The exec API starts with an empty $HOME; installers read it. */
const HOME_PREFIX = 'export HOME="${HOME:-$(getent passwd $(id -u) | cut -d: -f6)}"';
/** The exec API caps one call at 5 minutes. */
export const STEP_TIMEOUT_MS = 300_000;

/**
 * FREESTYLE_API_KEY, or FREESTYLE_API_KEY_FILE (a path; the key is read here and never
 * printed), so an operator passes the key by path instead of through a shell variable.
 */
export function freestyleApiKey(env: Record<string, string | undefined> = process.env): string {
  if (env.FREESTYLE_API_KEY) return env.FREESTYLE_API_KEY;
  const file = env.FREESTYLE_API_KEY_FILE;
  if (file) {
    const key = readFileSync(file, "utf8").trim();
    if (key) return key;
    throw new Error("FREESTYLE_API_KEY_FILE is empty");
  }
  throw new Error("set FREESTYLE_API_KEY or FREESTYLE_API_KEY_FILE");
}

export function freestyleClient(): Freestyle {
  const apiKey = freestyleApiKey();
  const baseUrl = process.env.FREESTYLE_API_URL?.trim() || undefined;
  return new Freestyle({ apiKey, baseUrl });
}

export type Vm = Awaited<ReturnType<Freestyle["vms"]["create"]>>["vm"];

export const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Append-only ledger: `id\tkind\tname\tISO time\tstatus`. */
export class Ledger {
  constructor(readonly file: string) {
    mkdirSync(path.dirname(file), { recursive: true });
  }
  record(id: string, kind: "vm" | "snapshot", name: string, status = "created"): void {
    appendFileSync(this.file, `${id}\t${kind}\t${name}\t${new Date().toISOString()}\t${status}\n`);
  }
  /** Ids created and not yet recorded as deleted, newest last. */
  live(): Array<{ id: string; kind: "vm" | "snapshot"; name: string }> {
    if (!existsSync(this.file)) return [];
    const state = new Map<string, { id: string; kind: "vm" | "snapshot"; name: string; status: string }>();
    for (const line of readFileSync(this.file, "utf8").split("\n")) {
      const [id, kind, name, , status] = line.split("\t");
      if (!id || (kind !== "vm" && kind !== "snapshot")) continue;
      state.set(id, { id, kind, name, status });
    }
    return [...state.values()].filter((row) => row.status !== "deleted" && row.status !== "kept").map(({ id, kind, name }) => ({ id, kind, name }));
  }
}

/** Branch resources must carry the cmuxnp-dev- prefix; only a promotion run may pass allowUnprefixed. */
export function assertResourceName(name: string, allowUnprefixed = false): void {
  if (!allowUnprefixed && !name.startsWith("cmuxnp-dev-")) throw new Error(`resource name ${name} must start with cmuxnp-dev-`);
}

type LiveVm = { vm: Vm; vmId: string; name: string; ledger: Ledger };
const liveVms = new Map<string, LiveVm>();
let signalCleanupInstalled = false;

/** Remembers a VM this process created until deleteVm runs; a signal deletes what is left. */
export function trackLiveVm(entry: LiveVm): void {
  liveVms.set(entry.vmId, entry);
  if (signalCleanupInstalled) return;
  signalCleanupInstalled = true;
  // finally blocks do not run when a signal ends the process (a local `timeout`, Ctrl-C).
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) {
    process.once(signal, () => {
      void deleteLiveVms().finally(() => process.exit(128 + (signal === "SIGINT" ? 2 : signal === "SIGHUP" ? 1 : 15)));
    });
  }
}

/** Deletes every tracked VM by id (ledger-recorded); returns the ids it deleted. */
export async function deleteLiveVms(): Promise<string[]> {
  const ids: string[] = [];
  for (const entry of [...liveVms.values()]) {
    await deleteVm(entry.vm, entry.vmId, entry.name, entry.ledger);
    ids.push(entry.vmId);
  }
  return ids;
}

/** Network idleness after which Freestyle pauses a harness VM (at most 300 s). */
export const HARNESS_IDLE_TIMEOUT_SECONDS = 300;

export async function createVm(fs: Freestyle, ledger: Ledger, options: { name: string; snapshotId: string; allowUnprefixed?: boolean }): Promise<{ vm: Vm; vmId: string; createMs: number; t0: number }> {
  assertResourceName(options.name, options.allowUnprefixed);
  const t0 = Date.now();
  const { vm, vmId } = await fs.vms.create({
    snapshotId: options.snapshotId,
    displayName: options.name,
    // Outbound-only: the bake downloads its inputs; nothing dials in.
    firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
    // A run that dies without cleanup (lost laptop, killed harness) must not
    // leave a VM running: Freestyle pauses it after this much network idleness
    // (Lawrence, 2026-10-07). Product machines are created by CloudDO with -1.
    idleTimeoutSeconds: HARNESS_IDLE_TIMEOUT_SECONDS,
  });
  const createMs = Date.now() - t0;
  ledger.record(vmId, "vm", options.name);
  trackLiveVm({ vm, vmId, name: options.name, ledger });
  return { vm, vmId, createMs, t0 };
}

export async function deleteVm(vm: Vm, vmId: string, name: string, ledger: Ledger): Promise<void> {
  liveVms.delete(vmId);
  try {
    await vm.delete();
    ledger.record(vmId, "vm", name, "deleted");
  } catch (error) {
    ledger.record(vmId, "vm", name, `delete-failed ${String(error).slice(0, 80)}`);
  }
}

/** Polls a trivial exec until the guest answers; returns ms since t0. */
export async function firstExec(vm: Vm, t0: number, budgetMs = 60_000): Promise<number> {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    try {
      const r = await vm.exec({ command: "true", timeoutMs: 10_000 });
      if ((r.statusCode ?? 1) === 0) return Date.now() - t0;
    } catch {
      // not ready yet
    }
    await sleep(50);
  }
  throw new Error("guest never answered an exec");
}

export type ExecResult = { code: number; stdout: string; stderr: string; ms: number };

export async function run(vm: Vm, command: string, timeoutMs = STEP_TIMEOUT_MS, user = "root"): Promise<ExecResult> {
  const t0 = Date.now();
  const r = await vm.exec({ command: `${HOME_PREFIX} && ${command}`, env: BUILD_ENV, timeoutMs, linuxUser: user });
  return { code: r.statusCode ?? 124, stdout: r.stdout ?? "", stderr: r.stderr ?? "", ms: Date.now() - t0 };
}

/** Logged steps; a failed step throws with its output tail. */
export class StepLog {
  readonly steps: Array<{ label: string; secs: number }> = [];
  constructor(readonly logFile: string) {
    mkdirSync(path.dirname(logFile), { recursive: true });
  }
  log(line: string): void {
    console.log(line);
    appendFileSync(this.logFile, `${line}\n`);
  }
  async step(vm: Vm, label: string, command: string, timeoutMs = STEP_TIMEOUT_MS): Promise<string> {
    const r = await run(vm, command, timeoutMs);
    const secs = r.ms / 1000;
    this.steps.push({ label, secs });
    appendFileSync(this.logFile, `--- [${label}] status=${r.code} ${secs.toFixed(1)}s\n${r.stdout}\n--- stderr\n${r.stderr.slice(-3000)}\n`);
    if (r.code !== 0) {
      this.log(`STEP FAILED [${label}] status=${r.code} (${secs.toFixed(1)}s)\nstdout: ${r.stdout.slice(-3000)}\nstderr: ${r.stderr.slice(-3000)}`);
      throw new Error(`step ${label} failed`);
    }
    this.log(`ok [${label}] ${secs.toFixed(1)}s :: ${r.stdout.trim().split("\n").slice(-3).join(" | ")}`);
    return r.stdout;
  }
}

export function argValue(name: string, argv = process.argv): string | undefined {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : undefined;
}

export const hasFlag = (name: string, argv = process.argv) => argv.includes(name);
