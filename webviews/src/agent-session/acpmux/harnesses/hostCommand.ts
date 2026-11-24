// One install or update command run in place on the app host (`shell.run`, then `shell.read` until
// it ends): the Harnesses page's Install… and Update, and the model picker's pick of a model whose
// harness this Mac does not have yet (harnessSetup.ts). Nothing opens a terminal.
import { cleanShellOutput } from "../shell/shellRuns";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;
type HostRead = { output?: string; next?: number; exit?: { code?: number; signal?: number } };

/// Output kept to find the last line.
const TAIL = 4096;

/// The last non-empty line of a command's output, escape sequences removed.
export const lastLine = (text: string): string | undefined =>
  cleanShellOutput(text)
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .at(-1);

/// A command that exited with a failure; `line` is its last output line, when it printed one.
export class HostCommandFailed extends Error {
  constructor(readonly line: string | undefined) {
    super(line ?? "command failed");
  }
}

/// Runs `command` in the user's login shell on the host, in `cwd`, and reads it to its end.
/// `onLine` gets its last output line whenever it changes. When `alive()` turns false (the page or
/// the pick that started it went away) the command is stopped and this resolves `"stopped"`.
/// Resolves `"done"` on exit 0; rejects with ``HostCommandFailed`` on another exit, and with the
/// host's error when it refused (the host runs a command only on the person's gesture).
export async function runHostCommand(
  native: Native,
  command: string,
  { cwd, onLine, alive = () => true }: { cwd?: string; onLine?(line: string): void; alive?(): boolean } = {},
): Promise<"done" | "stopped"> {
  const started = (await native("shell.run", { command, ...(cwd ? { cwd } : {}) })) as { id: string };
  let after = 0;
  let tail = "";
  for (;;) {
    const read = (await native("shell.read", { id: started.id, after })) as HostRead;
    if (!alive()) {
      if (!read.exit) void native("shell.stop", { id: started.id }).catch(() => undefined);
      return "stopped";
    }
    after = read.next ?? after;
    if (read.output) {
      tail = (tail + read.output).slice(-TAIL);
      const line = lastLine(tail);
      if (line) onLine?.(line);
    }
    if (read.exit) {
      if (read.exit.code !== 0) throw new HostCommandFailed(lastLine(tail));
      return "done";
    }
  }
}
