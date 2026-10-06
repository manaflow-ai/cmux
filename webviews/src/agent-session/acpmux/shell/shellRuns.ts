/// Shell mode's commands (`!` first in the composer or the new tab field): each runs on the
/// chat's machine in the chat's folder through the host (`shell.run`), its output streams back
/// through `shell.read` (the host answers when there is output or the command ended), and it
/// shows in the transcript as a command block where it ran. Nothing opens a terminal by itself;
/// "Open in terminal" is the block's own action. The next prompt carries a command as a chip the
/// user can remove (`shellAttachment`), filled with its output when the prompt goes.
import type { ComposerAttachment } from "../attachments";
import type { AcpmuxRow } from "../model";

export type ShellRunStatus = "running" | "done" | "failed" | "stopped";

export type ShellRun = {
  /// The page's id (the block's row is `shell-<id>`).
  id: string;
  command: string;
  cwd?: string;
  /// The chat it ran in; unset until a fresh chat gets its session (`claim`).
  sessionId?: string;
  startedAt: number;
  endedAt?: number;
  status: ShellRunStatus;
  exitCode?: number;
  /// What the command printed (stdout and stderr together), escape sequences removed.
  output: string;
  /// The start of the output was dropped to keep the run bounded.
  truncated: boolean;
  /// Why the host did not run it, or lost it.
  error?: string;
  /// Bumped on every change, so the transcript measures the block again.
  version: number;
};

type Native = <T>(method: string, params?: Record<string, unknown>) => Promise<T>;
type HostRead = { output?: string; next?: number; truncated?: boolean; exit?: { code?: number; signal?: string } };

/// The transcript row kind of a command block.
export const SHELL_ROW = "userShell";
/// Raw output kept per run in the page; older output is dropped from the front.
export const MAX_SHELL_OUTPUT = 256 * 1024;
/// What a prompt carries of one command's output: its end, where the errors are.
export const MAX_SHELL_CONTEXT = 16 * 1024;
/// Command chips a prompt holds; an older one goes when another command runs.
export const MAX_SHELL_CHIPS = 3;

export class ShellRuns {
  private runs: ShellRun[] = [];
  private raw = new Map<string, string>();
  private hostIds = new Map<string, string>();
  private stopping = new Set<string>();
  private listeners = new Set<() => void>();

  constructor(
    private readonly callNative: Native,
    private readonly now: () => number = () => Date.now(),
  ) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  /// Every run, oldest first; a new array after each change (useSyncExternalStore).
  snapshot = () => this.runs;

  get(id: string): ShellRun | undefined {
    return this.runs.find((run) => run.id === id);
  }

  forSession(sessionId: string | undefined): ShellRun[] {
    return this.runs.filter((run) => run.sessionId === sessionId);
  }

  /// The chat's newest command still running: the one Ctrl-C stops.
  running(sessionId: string | undefined): ShellRun | undefined {
    return this.forSession(sessionId)
      .filter((run) => run.status === "running")
      .at(-1);
  }

  /// Runs started in a chat that had no session yet join `sessionId`.
  claim(sessionId: string) {
    if (!this.runs.some((run) => run.sessionId === undefined)) return;
    this.runs = this.runs.map((run) => (run.sessionId === undefined ? { ...run, sessionId } : run));
    this.emit();
  }

  start(command: string, where: { cwd?: string; sessionId?: string }): ShellRun {
    const run: ShellRun = {
      id: crypto.randomUUID(),
      command,
      ...(where.cwd ? { cwd: where.cwd } : {}),
      ...(where.sessionId ? { sessionId: where.sessionId } : {}),
      startedAt: this.now(),
      status: "running",
      output: "",
      truncated: false,
      version: 1,
    };
    this.runs = [...this.runs, run];
    this.emit();
    void this.pump(run.id, command, where.cwd);
    return run;
  }

  /// Ctrl-C or the block's Stop: the host interrupts the command's process group.
  stop(id: string) {
    const run = this.get(id);
    if (!run || run.status !== "running") return;
    this.stopping.add(id);
    const hostId = this.hostIds.get(id);
    if (hostId) void this.callNative("shell.stop", { id: hostId }).catch(() => undefined);
  }

  private async pump(id: string, command: string, cwd?: string) {
    try {
      const started = await this.callNative<{ id: string }>("shell.run", { command, ...(cwd ? { cwd } : {}) });
      this.hostIds.set(id, started.id);
      if (this.stopping.has(id)) void this.callNative("shell.stop", { id: started.id }).catch(() => undefined);
      let after = 0;
      for (;;) {
        const read = await this.callNative<HostRead>("shell.read", { id: started.id, after });
        after = read.next ?? after;
        if (read.output || read.truncated) this.append(id, read.output ?? "", read.truncated === true);
        if (read.exit) {
          const stopped = this.stopping.has(id) && read.exit.code === undefined;
          const code = read.exit.code;
          this.update(id, {
            status: stopped ? "stopped" : code === 0 ? "done" : "failed",
            ...(code !== undefined ? { exitCode: code } : {}),
            endedAt: this.now(),
          });
          return;
        }
      }
    } catch (error) {
      this.update(id, {
        status: "failed",
        error: error instanceof Error ? error.message : String(error),
        endedAt: this.now(),
      });
    } finally {
      this.hostIds.delete(id);
      this.stopping.delete(id);
    }
  }

  private append(id: string, chunk: string, hostTruncated: boolean) {
    let raw = (this.raw.get(id) ?? "") + chunk;
    let truncated = hostTruncated || (this.get(id)?.truncated ?? false);
    if (raw.length > MAX_SHELL_OUTPUT) {
      const cut = raw.indexOf("\n", raw.length - MAX_SHELL_OUTPUT);
      raw = raw.slice(cut < 0 ? raw.length - MAX_SHELL_OUTPUT : cut + 1);
      truncated = true;
    }
    this.raw.set(id, raw);
    this.update(id, { output: cleanShellOutput(raw), truncated });
  }

  private update(id: string, change: Partial<ShellRun>) {
    this.runs = this.runs.map((run) => (run.id === id ? { ...run, ...change, version: run.version + 1 } : run));
    this.emit();
  }

  private emit() {
    for (const listener of this.listeners) listener();
  }
}

/// Output as text: CSI and OSC escape sequences removed, and a carriage return (a progress bar)
/// keeps only what the line ended with.
export function cleanShellOutput(raw: string): string {
  const plain = raw
    // oxlint-disable-next-line no-control-regex
    .replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g, "")
    // oxlint-disable-next-line no-control-regex
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "")
    // oxlint-disable-next-line no-control-regex
    .replace(/\u001b[@-Z\\-_]/g, "")
    .replace(/\r\n/g, "\n");
  return plain
    .split("\n")
    .map((line) => line.slice(line.lastIndexOf("\r") + 1))
    .join("\n");
}

/// The chat's rows with each command block placed where it ran (before the first row that came
/// later). The same array when there are none.
export function withShellRows(rows: AcpmuxRow[], runs: readonly ShellRun[]): AcpmuxRow[] {
  if (runs.length === 0) return rows;
  const out = [...rows];
  for (const run of [...runs].sort((a, b) => a.startedAt - b.startedAt)) {
    const at = out.findIndex((row) => row.kind !== SHELL_ROW && row.at > run.startedAt);
    const block: AcpmuxRow = {
      id: `shell-${run.id}`,
      kind: SHELL_ROW,
      at: run.startedAt,
      version: run.version,
      shell: run,
    };
    if (at < 0) out.push(block);
    else out.splice(at, 0, block);
  }
  return out;
}

/// The chip a command leaves in the composer: removable, filled when the prompt goes.
export function shellAttachment(run: ShellRun): ComposerAttachment {
  return {
    id: `shell-${run.id}`,
    kind: "text",
    name: `$ ${run.command}`,
    mimeType: "text/plain",
    size: 0,
    shellRun: run.id,
  };
}

/// `attachments` with each command chip filled from its run: the command, folder, exit status
/// and the end of its output, as the text the agent reads.
export function shellContextAttachments(
  attachments: ComposerAttachment[],
  find: (id: string) => ShellRun | undefined,
): ComposerAttachment[] {
  return attachments.map((attachment) => {
    const run = attachment.shellRun ? find(attachment.shellRun) : undefined;
    if (!attachment.shellRun || !run) return attachment;
    const state =
      run.status === "running"
        ? "still running"
        : run.status === "stopped"
          ? "stopped"
          : run.exitCode !== undefined
            ? `exit ${run.exitCode}`
            : "failed";
    const output = run.output.length > MAX_SHELL_CONTEXT ? run.output.slice(-MAX_SHELL_CONTEXT) : run.output;
    const cut = run.truncated || output.length < run.output.length;
    const text = [
      `The user ran this command${run.cwd ? ` in ${run.cwd}` : ""}: ${run.command}`,
      `Result: ${state}${run.error ? ` (${run.error})` : ""}`,
      cut ? "Output (its end):" : "Output:",
      output.replace(/\n$/, ""),
    ].join("\n");
    return { ...attachment, name: `$ ${run.command} (${state})`, text, size: text.length };
  });
}

/// Keeps the newest `MAX_SHELL_CHIPS` command chips, other attachments as they are.
export function cappedShellChips(attachments: ComposerAttachment[]): ComposerAttachment[] {
  const chips = attachments.filter((attachment) => attachment.shellRun);
  if (chips.length <= MAX_SHELL_CHIPS) return attachments;
  const drop = new Set(chips.slice(0, chips.length - MAX_SHELL_CHIPS).map((chip) => chip.id));
  return attachments.filter((attachment) => !drop.has(attachment.id));
}
