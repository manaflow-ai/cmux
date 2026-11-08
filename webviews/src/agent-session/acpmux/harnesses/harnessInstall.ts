// Installs a harness's CLI in place (cmux#38191): the Harnesses page's Install and the model
// picker's install prompt run the same command the same way. The host runs it in the user's login
// shell (`shell.run`, only on a click), its output is read until it exits, and then acpmux looks
// for harnesses again (`rescan`) and the caller reads its catalog again.
import { cleanShellOutput } from "../shell/shellRuns";

export type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

type HostRead = { output?: string; next?: number; exit?: { code?: number; signal?: number } };

/// Output kept to find the last line.
const TAIL = 4096;

/// The last non-empty line of a command's output, as a row or a dialog shows its progress.
export const lastLine = (text: string) =>
  cleanShellOutput(text)
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .at(-1);

/// Why an install failed: the command's last output line, else `fallback`.
export class InstallFailed extends Error {}

/// Runs `command` through the host and resolves when it exits 0. `onLine` gets each new last
/// output line; `live()` false (the page or dialog closed) stops the command and resolves
/// `"stopped"`. A non-zero exit rejects with an `InstallFailed` naming the last line.
export async function runInstallCommand({
  callNative,
  command,
  cwd,
  live,
  onLine,
  failedText,
}: {
  callNative: Native;
  command: string;
  cwd?: string;
  live(): boolean;
  onLine(line: string): void;
  /// The reason when the command printed nothing.
  failedText: string;
}): Promise<"done" | "stopped"> {
  let tail = "";
  const started = (await callNative("shell.run", { command, ...(cwd ? { cwd } : {}) })) as { id: string };
  let after = 0;
  for (;;) {
    const read = (await callNative("shell.read", { id: started.id, after })) as HostRead;
    if (!live()) {
      if (!read.exit) void callNative("shell.stop", { id: started.id }).catch(() => undefined);
      return "stopped";
    }
    after = read.next ?? after;
    if (read.output) {
      tail = (tail + read.output).slice(-TAIL);
      const line = lastLine(tail);
      if (line) onLine(line);
    }
    if (read.exit) {
      if (read.exit.code !== 0) throw new InstallFailed(lastLine(tail) ?? failedText);
      return "done";
    }
  }
}

/// acpmux looks for `harness` again (PATH and profiles) and answers its health; the caller then
/// reads the catalog again. A failed look answers undefined: the catalog says what is there.
export async function rescanHarness(callNative: Native, harness: string): Promise<unknown> {
  try {
    return await callNative("harness.health", { id: harness, refresh: true, rescan: true });
  } catch {
    return undefined;
  }
}
