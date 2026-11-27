/**
 * One guest command run detached, with short execs that start it and poll for its status, so no exec is held open
 * for the command's whole length.
 *
 * Why: an exec-await held open for minutes fails on the provider's side, not the guest's. Rebake run 45920283687
 * stalled in `media-apt` (32 s to 187 s on earlier rolls) until the client's own TimeoutError at 526 s, past the
 * exec API's 300 s cap, with no status and no step name; StepLog.detachedStep (guest.ts) records the same class for
 * the image inventory (rolls 45829777164, 45883186922). Here a lost poll costs one poll: the next one asks again.
 *
 * Two clocks, as a CDN keeps an origin timeout apart from its retry window: the budget bounds the guest's command
 * (its own `timeout` ends it and writes `status` to disk), and the outage window bounds how long the provider's exec
 * API may stay unreachable. Rebake run 45960390204 (2026-11-27, Freestyle "start capacity overloaded") lost
 * `media-apt` at 546 s with every poll timing out: a failing poll says nothing about the guest, so past the budget
 * the step keeps asking until the provider has been unreachable for the outage window. A poll that answers with no
 * status past the budget still fails at once: that guest lost the command.
 *
 * The guest runs the command under `timeout` (status 124 at the budget), in bash, as the start call's user and env.
 */

export type DetachedExecVm = {
  exec(args: { command: string; env?: Record<string, string>; timeoutMs: number; linuxUser?: string }): Promise<{
    statusCode?: number | null;
    stdout?: string | null;
    stderr?: string | null;
  }>;
};

export type DetachedExecResult = { code: number; stdout: string; stderr: string; ms: number };

export type DetachedExecOptions = {
  /** A guest directory this command alone owns. */
  dir: string;
  budgetMs: number;
  env?: Record<string, string>;
  linuxUser?: string;
  /** Prepended to every exec (the bake's HOME restore). */
  prefix?: string;
  /** One start or poll call. */
  callMs?: number;
  /** The first poll waits this long, doubling to maxPollMs: a 0.2 s step answers in about 0.25 s. */
  firstPollMs?: number;
  maxPollMs?: number;
  /** Past the budget: the guest's kill, the status write and a slow poll. */
  graceMs?: number;
  /** Past the budget, polls that keep failing go on until none has answered for this long. */
  outageMs?: number;
  sleep?: (ms: number) => Promise<unknown>;
  now?: () => number;
};

export const DETACHED_EXEC_CALL_MS = 30_000;
export const DETACHED_EXEC_FIRST_POLL_MS = 250;
export const DETACHED_EXEC_MAX_POLL_MS = 5_000;
export const DETACHED_EXEC_GRACE_MS = 60_000;
export const DETACHED_EXEC_OUTAGE_MS = 600_000;
const STDERR_MARK = "--cmux-detached-exec-stderr--";

const defaultSleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Thrown when no status came back; names the last provider error, if the polls themselves were failing. */
export class DetachedExecLost extends Error {
  constructor(message: string, readonly lastError: unknown) {
    super(message);
    this.name = "DetachedExecLost";
  }
}

export async function detachedExec(vm: DetachedExecVm, command: string, options: DetachedExecOptions): Promise<DetachedExecResult> {
  const now = options.now ?? Date.now;
  const wait = options.sleep ?? defaultSleep;
  const callMs = options.callMs ?? DETACHED_EXEC_CALL_MS;
  const maxPollMs = options.maxPollMs ?? DETACHED_EXEC_MAX_POLL_MS;
  const { dir } = options;
  const budgetSecs = Math.ceil(options.budgetMs / 1000);
  const call = async (shell: string) => {
    const r = await vm.exec({
      command: options.prefix ? `${options.prefix} && ${shell}` : shell,
      env: options.env,
      timeoutMs: callMs,
      linuxUser: options.linuxUser,
    });
    return { code: r.statusCode ?? 124, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  };
  // The script deletes itself once bash holds it open: a step's text can carry a key, and the guest is snapshotted.
  const script = Buffer.from(`rm -f -- "$0"\n${command}`).toString("base64");
  const t0 = now();
  // `started` is written before the launch returns, so a start whose answer was lost is read back, not run twice.
  const startShell = [
    `mkdir -p ${dir}`,
    `if [ -e ${dir}/started ]; then echo started; exit 0; fi`,
    `rm -f ${dir}/status ${dir}/out ${dir}/err`,
    `printf %s ${script} | base64 -d > ${dir}/cmd.sh`,
    `{ nohup setsid sh -c 'timeout -k 10 ${budgetSecs} bash ${dir}/cmd.sh > ${dir}/out 2> ${dir}/err; echo $? > ${dir}/status' > /dev/null 2>&1 < /dev/null & }`,
    `touch ${dir}/started`,
    "echo started",
  ].join(" && ");
  let started = false;
  let lastError: unknown;
  for (let attempt = 0; attempt < 3 && !started; attempt++) {
    try {
      const r = await call(startShell);
      if (r.code !== 0 || !r.stdout.includes("started")) {
        return { code: r.code === 0 ? 1 : r.code, stdout: r.stdout, stderr: `did not start: ${r.stderr}`, ms: now() - t0 };
      }
      started = true;
    } catch (error) {
      lastError = error;
      await wait(options.firstPollMs ?? DETACHED_EXEC_FIRST_POLL_MS);
    }
  }
  if (!started) throw new DetachedExecLost(`never started after 3 tries: ${String(lastError)}`, lastError);

  const deadline = t0 + options.budgetMs + (options.graceMs ?? DETACHED_EXEC_GRACE_MS);
  const outageMs = options.outageMs ?? DETACHED_EXEC_OUTAGE_MS;
  let pollMs = options.firstPollMs ?? DETACHED_EXEC_FIRST_POLL_MS;
  let lastAnswerAt = now();
  lastError = undefined;
  for (;;) {
    await wait(pollMs);
    pollMs = Math.min(pollMs * 2, maxPollMs);
    try {
      const r = await call(`if [ -s ${dir}/status ]; then cat ${dir}/status; cat ${dir}/out; echo ${STDERR_MARK}; tail -c 3000 ${dir}/err; fi`);
      lastError = undefined;
      lastAnswerAt = now();
      if (r.stdout !== "") {
        const newline = r.stdout.indexOf("\n");
        const code = Number(r.stdout.slice(0, newline).trim());
        const [stdout, stderr = ""] = r.stdout.slice(newline + 1).split(`${STDERR_MARK}\n`);
        const ms = now() - t0;
        // Best effort: a lost answer here leaves only this step's output files.
        await call(`rm -rf ${dir}`).catch(() => undefined);
        return { code: Number.isFinite(code) ? code : 1, stdout: stdout.replace(/\n$/, ""), stderr, ms };
      }
    } catch (error) {
      lastError = error;
    }
    if (now() > deadline && (lastError === undefined || now() - lastAnswerAt > outageMs)) {
      const secs = ((now() - t0) / 1000).toFixed(1);
      throw new DetachedExecLost(
        lastError === undefined
          ? `no status after ${secs}s (budget ${budgetSecs}s): the guest lost the command`
          : `no status after ${secs}s (budget ${budgetSecs}s); no poll answered for ${((now() - lastAnswerAt) / 1000).toFixed(1)}s; last poll failed: ${String(lastError)}`,
        lastError,
      );
    }
  }
}
