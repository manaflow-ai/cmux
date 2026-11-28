/**
 * Freestyle plumbing for the cmux VM image scripts: the client, a resource
 * ledger (every VM and snapshot id the moment it exists, so cleanup deletes
 * exactly what this run made), and logged guest steps.
 */
import { appendFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { Freestyle } from "freestyle";
import { installCapacityRetry } from "./capacity";
import { guestShellProblems } from "./shell-check";

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

/** The image scripts' client; a capacity answer to any of its calls is retried (capacity.ts). */
export function freestyleClient(): Freestyle {
  const apiKey = freestyleApiKey();
  const baseUrl = process.env.FREESTYLE_API_URL?.trim() || undefined;
  return installCapacityRetry(new Freestyle({ apiKey, baseUrl }));
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
let signalCleanupStarted = false;

/** Remembers a VM this process created until deleteVm runs; a signal deletes what is left. */
export function trackLiveVm(entry: LiveVm): void {
  liveVms.set(entry.vmId, entry);
  if (signalCleanupInstalled) return;
  signalCleanupInstalled = true;
  // finally blocks do not run when a signal ends the process (a local `timeout`, Ctrl-C).
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) {
    process.once(signal, () => {
      if (signalCleanupStarted) return;
      signalCleanupStarted = true;
      void deleteLiveVms()
        .catch((error) => console.error(`image VM signal cleanup incomplete: ${String(error)}`))
        .finally(() => process.exit(128 + (signal === "SIGINT" ? 2 : signal === "SIGHUP" ? 1 : 15)));
    });
  }
}

/** Try every tracked VM, retry failed deletes once, and report any exact ids still live. */
export async function deleteLiveVms(): Promise<string[]> {
  const deleted: string[] = [];
  const failed: string[] = [];
  for (const entry of [...liveVms.values()]) {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        await deleteVm(entry.vm, entry.vmId, entry.name, entry.ledger);
        deleted.push(entry.vmId);
        break;
      } catch {
        if (attempt === 0) await sleep(250);
        else failed.push(entry.vmId);
      }
    }
  }
  if (failed.length) throw new Error(`image VM cleanup failed; still tracked: ${failed.join(", ")}`);
  return deleted;
}

/** Network idleness after which Freestyle pauses a harness VM (at most 300 s). */
export const HARNESS_IDLE_TIMEOUT_SECONDS = 300;

/** One inline edge rule at create, as a product create carries it (web/services/vms/drivers/freestyle.ts freestyleEdgeRules). */
export type CreateTlsRule = {
  action: "allow";
  domain: string;
  source: Record<string, never>;
  destination: { host: string; port: number };
  transform: Array<{ headers: Record<string, string> }>;
};

export async function createVm(fs: Freestyle, ledger: Ledger, options: { name: string; snapshotId: string; allowUnprefixed?: boolean; tlsRules?: CreateTlsRule[] }): Promise<{ vm: Vm; vmId: string; createMs: number; t0: number }> {
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
    ...(options.tlsRules?.length ? { tls: { rules: options.tlsRules } } : {}),
  });
  const createMs = Date.now() - t0;
  ledger.record(vmId, "vm", options.name);
  trackLiveVm({ vm, vmId, name: options.name, ledger });
  return { vm, vmId, createMs, t0 };
}

/** Waits before each retry of a delete the provider answered 5xx, or that timed out: 4 tries over 35 s. */
export const DELETE_RETRY_DELAYS_MS: readonly number[] = [5_000, 10_000, 20_000];

// A provider 5xx on delete (run 44112930938: 503 INTERNAL_ERROR after a smoke whose checks all passed) is
// retried: a delete is idempotent, and 404 below already reads a lost success as gone. Any other error, and a
// 5xx that outlasts the delays, goes to the caller with the VM still tracked, as before. A delete the client gave
// up on (TimeoutError, no status: run 45829777164's smoke failed in its cleanup after its checks passed) is retried
// the same way: the provider may have done it, and the next try reads that as 404.
export async function deleteVm(
  vm: Vm, vmId: string, name: string, ledger: Ledger,
  deps: { sleep?: (ms: number) => Promise<unknown>; delaysMs?: readonly number[] } = {},
): Promise<void> {
  const delays = deps.delaysMs ?? DELETE_RETRY_DELAYS_MS;
  for (let attempt = 0; ; attempt++) {
    try {
      await vm.delete();
      break;
    } catch (error) {
      const status = (error as { status?: unknown } | null)?.status;
      // A prior delete may have succeeded before its response was lost.
      if (status === 404) break;
      const timedOut = (error as { name?: unknown } | null)?.name === "TimeoutError";
      if (((typeof status === "number" && status >= 500) || timedOut) && attempt < delays.length) {
        await (deps.sleep ?? sleep)(delays[attempt]);
        continue;
      }
      ledger.record(vmId, "vm", name, `delete-failed ${String(error).slice(0, 80)}`);
      throw error;
    }
  }
  // Retire only after the provider has answered deleted/already-gone AND
  // the ledger records that outcome. A failed ledger write remains retryable.
  ledger.record(vmId, "vm", name, "deleted");
  liveVms.delete(vmId);
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
    // The guest runs it with /bin/sh (dash): refuse here, in a second, what would fail there after the layers before it.
    const shellCheck = guestShellProblems(command);
    for (const s of shellCheck.suspect) this.log(`WARN [${label}] ${s}`);
    if (shellCheck.refused.length > 0) {
      this.log(`STEP FAILED [${label}] before it ran: the guest's /bin/sh refuses it:\n${shellCheck.refused.join("\n")}`);
      throw new Error(`step ${label} failed: not /bin/sh`);
    }
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

  /**
   * A step that may outlast one exec call: the guest runs it detached under `timeout`, writing its output and status
   * into `dir`, and short execs poll for the status. One exec-await held open for minutes fails two ways (rolls
   * 45779971043: status 124 at the 300 s exec cap; 45829777164 and 45883186922: the client's TimeoutError after its
   * background-request poll went unanswered), so a poll that errors or times out is tried again until the budget is
   * spent. The guest's own `timeout` ends the command at budgetMs (status 124, "step X failed"); a step that took more
   * than half its budget logs SLOW_STEP so the workflow can warn before the bound is reached.
   */
  async detachedStep(
    vm: Vm, label: string, command: string,
    options: { dir: string; budgetMs: number; pollMs?: number; sleep?: (ms: number) => Promise<unknown>; now?: () => number; wake?: () => Promise<unknown> },
  ): Promise<string> {
    const shellCheck = guestShellProblems(command);
    for (const s of shellCheck.suspect) this.log(`WARN [${label}] ${s}`);
    if (shellCheck.refused.length > 0) {
      this.log(`STEP FAILED [${label}] before it ran: the guest's /bin/sh refuses it:\n${shellCheck.refused.join("\n")}`);
      throw new Error(`step ${label} failed: not /bin/sh`);
    }
    const now = options.now ?? Date.now;
    const wait = options.sleep ?? sleep;
    const pollMs = options.pollMs ?? DETACHED_POLL_MS;
    const { dir } = options;
    const budgetSecs = Math.ceil(options.budgetMs / 1000);
    const script = Buffer.from(command).toString("base64");
    const t0 = now();
    const start = await run(vm, [
      `mkdir -p ${dir}`,
      `rm -f ${dir}/status ${dir}/out ${dir}/err`,
      `printf %s ${script} | base64 -d > ${dir}/cmd.sh`,
      `{ nohup setsid sh -c 'timeout -k 10 ${budgetSecs} sh ${dir}/cmd.sh > ${dir}/out 2> ${dir}/err; echo $? > ${dir}/status' > /dev/null 2>&1 < /dev/null & }`,
      "echo started",
    ].join(" && "), DETACHED_CALL_MS);
    if (start.code !== 0 || !start.stdout.includes("started")) {
      this.log(`STEP FAILED [${label}] did not start: status=${start.code} ${start.stderr.slice(-3000)}`);
      throw new Error(`step ${label} failed: did not start`);
    }
    // The guest ends the command at the budget; the grace covers its kill, the status write and a slow poll.
    const deadline = t0 + options.budgetMs + DETACHED_GRACE_MS;
    let pollError: unknown;
    let failedPolls = 0;
    for (;;) {
      await wait(pollMs);
      let status = "";
      try {
        status = (await run(vm, `cat ${dir}/status 2>/dev/null || true`, DETACHED_CALL_MS)).stdout.trim();
        pollError = undefined;
        failedPolls = 0;
      } catch (error) {
        pollError = error;
        // A run of failed polls may be a paused or stopped VM rather than a blip (roll 46078031124: every poll of the
        // sbom step failed for its whole budget, then each retry's first exec): ask the provider and start it.
        if (++failedPolls % DETACHED_WAKE_AFTER_FAILED_POLLS === 0 && options.wake) {
          try {
            await options.wake();
          } catch (wakeError) {
            this.log(`WARN [${label}] wake after ${failedPolls} failed polls: ${String(wakeError)}`);
          }
        }
      }
      if (status !== "") {
        const r = await run(vm, `cat ${dir}/out; echo ${DETACHED_STDERR_MARK}; tail -c 3000 ${dir}/err`, DETACHED_CALL_MS);
        const [stdout, stderr = ""] = r.stdout.split(`${DETACHED_STDERR_MARK}\n`);
        const code = Number(status);
        const secs = (now() - t0) / 1000;
        this.steps.push({ label, secs });
        appendFileSync(this.logFile, `--- [${label}] status=${code} ${secs.toFixed(1)}s (detached, budget ${budgetSecs}s)\n${stdout}\n--- stderr\n${stderr}\n`);
        if (code !== 0) {
          const why = code === 124 || code === 137 ? ` (its ${budgetSecs} s budget ran out)` : "";
          this.log(`STEP FAILED [${label}] status=${code}${why} (${secs.toFixed(1)}s)\nstdout: ${stdout.slice(-3000)}\nstderr: ${stderr.slice(-3000)}`);
          throw new Error(`step ${label} failed`);
        }
        if (secs * 1000 > options.budgetMs / 2) this.log(`SLOW_STEP [${label}] ${secs.toFixed(1)}s of its ${budgetSecs}s budget`);
        this.log(`ok [${label}] ${secs.toFixed(1)}s :: ${stdout.trim().split("\n").slice(-3).join(" | ")}`);
        return stdout;
      }
      if (now() > deadline) {
        // Polls that answered without a status mean the guest lost the command; polls that kept failing are the
        // provider's, and go to the caller as that error (inventory.ts retries a cut or timed-out connection).
        if (pollError !== undefined) throw pollError;
        this.log(`STEP FAILED [${label}] no status after ${((now() - t0) / 1000).toFixed(1)}s (budget ${budgetSecs}s)`);
        throw new Error(`step ${label} failed: no status`);
      }
    }
  }
}

/** One poll or start call of a detached step: short, so a provider blip costs one poll, not the step. */
export const DETACHED_CALL_MS = 30_000;
export const DETACHED_POLL_MS = 10_000;
export const DETACHED_GRACE_MS = 60_000;
/** Failed polls in a row (DETACHED_POLL_MS + DETACHED_CALL_MS each, about a minute for 2) before detachedStep's wake. */
export const DETACHED_WAKE_AFTER_FAILED_POLLS = 2;

/**
 * Reads the VM's provider state and starts it when it is not running: createVm gives every harness VM a
 * HARNESS_IDLE_TIMEOUT_SECONDS network-idle pause, and a builder kept for the inventory runs a long detached scan
 * with nothing on the network. Logs the state either way, so an unreachable guest names its cause in the log.
 * Returns the state it found.
 */
export async function wakeVm(vm: Pick<Vm, "data" | "start">, log: (line: string) => void, label: string): Promise<string> {
  const state = String((await vm.data()).state);
  if (state === "running" || state === "starting") {
    log(`VM_STATE [${label}] ${state}`);
    return state;
  }
  log(`VM_STATE [${label}] ${state}: starting it`);
  const after = await vm.start();
  log(`VM_STATE [${label}] after start: ${String(after?.state ?? "unknown")}`);
  return state;
}
const DETACHED_STDERR_MARK = "--cmux-detached-stderr--";

export function argValue(name: string, argv = process.argv): string | undefined {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : undefined;
}

export const hasFlag = (name: string, argv = process.argv) => argv.includes(name);
