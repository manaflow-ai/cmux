import { spawn } from "node:child_process";

// Every web test that runs a child process goes through this helper instead of
// node:child_process's synchronous APIs. On Blacksmith runners Bun 1.3's
// synchronous spawn sometimes never observes the child's exit and spins the test process at
// 100% CPU until the job times out (manaflow-ai/cmux#14876). The async spawn
// waits on the event loop, so the child's exit always resolves the promise and
// the per-test timeout keeps working. tests/no-sync-child-process.test.ts keeps
// the synchronous APIs out of web/tests.

export interface ChildResult {
  /** Exit code, or null when the child was killed by a signal (as with the synchronous spawn). */
  status: number | null;
  /** The signal that killed the child, e.g. the timeout's kill signal; null on a normal exit. */
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
  /** Set when the child could not be spawned (e.g. ENOENT) or was killed by the timeout. */
  error?: Error;
}

export interface RunChildOptions {
  cwd?: string;
  /** Replaces the child's environment; undefined values are dropped. Defaults to process.env. */
  env?: Record<string, string | undefined>;
  /** Written to the child's stdin, which is then closed. Stdin is always closed. */
  input?: string;
  /** Milliseconds before the child is killed with killSignal. Defaults to 60 s. */
  timeout?: number;
  killSignal?: NodeJS.Signals;
}

const DEFAULT_TIMEOUT_MS = 60_000;

export function runChild(
  command: string,
  args: readonly string[] = [],
  options: RunChildOptions = {},
): Promise<ChildResult> {
  return new Promise((resolve) => {
    const child = spawn(command, [...args], {
      cwd: options.cwd,
      env: definedEnv(options.env ?? process.env),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;
    const finish = (result: ChildResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const timeoutMs = options.timeout ?? DEFAULT_TIMEOUT_MS;
    const killSignal = options.killSignal ?? "SIGTERM";
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill(killSignal);
    }, timeoutMs);
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk));
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
    child.on("error", (error) => finish({ status: null, signal: null, stdout, stderr, error }));
    child.on("close", (status, signal) => {
      const error = timedOut ? new Error(`${command} timed out after ${timeoutMs} ms and was killed with ${signal ?? killSignal}`) : undefined;
      finish({ status, signal, stdout, stderr, ...(error ? { error } : {}) });
    });
    // A child that exits without reading its stdin closes the pipe; that is not a test failure.
    child.stdin.on("error", () => {});
    child.stdin.end(options.input ?? "");
  });
}

/** Like the synchronous exec-file API: resolves only when the child exits 0, otherwise rejects with its output. */
export async function runChildOk(
  command: string,
  args: readonly string[] = [],
  options: RunChildOptions = {},
): Promise<ChildResult> {
  const result = await runChild(command, args, options);
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args.join(" ")} failed (status ${result.status}, signal ${result.signal})` +
        `${result.error ? `: ${result.error.message}` : ""}\n${result.stderr}${result.stdout}`,
    );
  }
  return result;
}

function definedEnv(env: Record<string, string | undefined>): NodeJS.ProcessEnv {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(env)) {
    if (value !== undefined) out[key] = value;
  }
  return out as NodeJS.ProcessEnv;
}
