import { type VmDriver, VmUnavailable } from "./vm.ts";

/**
 * Runs one coding task on a fresh VM: start the agent detached (an exec
 * call is capped at 5 minutes, the task is not), poll a done file with
 * backoff, read the answer, and always delete the VM.
 */

export type CodingAgent = "claude" | "codex";

export interface CodingTask {
  readonly label: string;
  readonly harness: CodingAgent;
  readonly prompt: string;
  /**
   * Model credential env for the agent, passed only through exec env, never
   * written to disk. Absent until the CodeRouter route exists (R35): then
   * the runner refuses, except for a dry run.
   */
  readonly credentialEnv?: Record<string, string>;
  /** Runs `<agent> --version` instead of the task: proves the machine and the CLI without a model. */
  readonly dryRun?: boolean;
}

export interface RunnerOptions {
  /** Longest a task may run before the VM is deleted anyway. */
  readonly maxRunSeconds: number;
  readonly sleep: (ms: number) => Promise<void>;
  /** First and longest gap between done checks. */
  readonly pollMs?: { readonly initial: number; readonly maximum: number };
}

export type CodingOutcome =
  | { readonly status: "done"; readonly answer: string; readonly exitCode: number }
  | { readonly status: "refused"; readonly reason: string }
  | { readonly status: "failed"; readonly reason: string };

const DIR = "/tmp/chief";
/** Characters of the answer reported back (the chief stores 280 bytes; the UI shows the rest). */
export const ANSWER_LIMIT = 16_000;

/** Single-quotes a value for bash. */
export const shellQuote = (s: string) => `'${s.replaceAll("'", `'"'"'`)}'`;

/** The agent's one-shot command line. */
export function agentCommand(task: CodingTask): string {
  if (task.dryRun) return task.harness === "claude" ? "claude --version" : "codex --version";
  const prompt = shellQuote(task.prompt);
  return task.harness === "claude"
    ? `claude -p --dangerously-skip-permissions ${prompt}`
    : `codex exec --yolo ${prompt}`;
}

/** Starts `command` detached so it outlives the exec call; its output and exit code land in DIR. */
export function detached(command: string): string {
  const inner = `echo started > ${DIR}/started; cd ~ && (${command}) > ${DIR}/out 2>&1; echo $? > ${DIR}/done`;
  // The start exec waits until the agent's shell wrote `started`, so a start that failed is an error now, not a timeout later.
  return (
    `mkdir -p ${DIR} && rm -f ${DIR}/out ${DIR}/done ${DIR}/started && ` +
    `(setsid bash -c ${shellQuote(inner)} < /dev/null > /dev/null 2>&1 &) && ` +
    `for i in $(seq 1 50); do [ -f ${DIR}/started ] && exit 0; sleep 0.1; done; exit 1`
  );
}

export async function runCodingTask(
  driver: VmDriver,
  task: CodingTask,
  options: RunnerOptions,
): Promise<CodingOutcome> {
  if (!task.dryRun && !task.credentialEnv) {
    return {
      status: "refused",
      reason: "Coding workers have no model credential yet (they will use the CodeRouter route).",
    };
  }
  let vm: { id: string } | undefined;
  try {
    vm = await driver.create({ label: task.label, maxRunSeconds: options.maxRunSeconds });
    const env = { HOME: "/home/ubuntu", ...task.credentialEnv };
    const started = await driver.exec(vm.id, detached(agentCommand(task)), { env, timeoutMs: 30_000 });
    if (started.statusCode !== 0)
      return { status: "failed", reason: `could not start the agent: ${started.stderr.trim() || started.statusCode}` };

    const poll = options.pollMs ?? { initial: 2_000, maximum: 30_000 };
    const deadline = options.maxRunSeconds * 1000;
    let waited = 0;
    let gap = poll.initial;
    for (;;) {
      const done = await driver.exec(vm.id, `cat ${DIR}/done 2>/dev/null`, { timeoutMs: 30_000 });
      const code = done.stdout.trim();
      if (code !== "") {
        const out = await driver.exec(vm.id, `tail -c ${ANSWER_LIMIT} ${DIR}/out`, { timeoutMs: 30_000 });
        return { status: "done", answer: out.stdout.trim(), exitCode: Number(code) };
      }
      if (waited >= deadline) return { status: "failed", reason: `no answer within ${options.maxRunSeconds} s` };
      await options.sleep(gap);
      waited += gap;
      gap = Math.min(gap * 2, poll.maximum);
    }
  } catch (e) {
    if (e instanceof VmUnavailable) return { status: "refused", reason: e.message };
    return { status: "failed", reason: (e as Error).message };
  } finally {
    if (vm) await driver.destroy(vm.id).catch(() => undefined);
  }
}
