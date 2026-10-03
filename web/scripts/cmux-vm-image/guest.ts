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

export function freestyleClient(): Freestyle {
  const apiKey = process.env.FREESTYLE_API_KEY;
  if (!apiKey) throw new Error("FREESTYLE_API_KEY is not set");
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

export async function createVm(fs: Freestyle, ledger: Ledger, options: { name: string; snapshotId: string; allowUnprefixed?: boolean }): Promise<{ vm: Vm; vmId: string; createMs: number; t0: number }> {
  assertResourceName(options.name, options.allowUnprefixed);
  const t0 = Date.now();
  const { vm, vmId } = await fs.vms.create({
    snapshotId: options.snapshotId,
    displayName: options.name,
    // Outbound-only: the bake downloads its inputs; nothing dials in.
    firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
  });
  const createMs = Date.now() - t0;
  ledger.record(vmId, "vm", options.name);
  return { vm, vmId, createMs, t0 };
}

export async function deleteVm(vm: Vm, vmId: string, name: string, ledger: Ledger): Promise<void> {
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
