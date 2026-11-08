/**
 * A guest exec runs its command with /bin/sh, which is dash on the image (run 42104967506 failed every bake on a
 * step that said `set -o pipefail`). guestShellProblems finds what dash refuses: a syntax error under `sh -n`
 * (dash where the host has it), and the bash-only constructs `-n` cannot see because they fail only when run.
 * Text inside single quotes is skipped: that is where a `bash -c '...'` / `bash -lc '...'` payload lives (lock.ts sq),
 * and bash runs it.
 */
import { spawnSync } from "node:child_process";

const BASHISMS: ReadonlyArray<{ name: string; re: RegExp }> = [
  { name: "set -o pipefail", re: /\bset\s+-[a-z]*o\s+pipefail\b|\bset\s+-[a-z]*\s+-o\s+pipefail\b|\bpipefail\b/ },
  { name: "[[ ]]", re: /(^|[\s;&|(])\[\[\s/ },
  { name: "process substitution", re: /[<>]\(/ },
  { name: "source (dash has only .)", re: /(^|[\s;&|])source\s/ },
  { name: "$'...' quoting", re: /\$'/ },
  { name: "array assignment", re: /(^|[\s;&|])[A-Za-z_][A-Za-z0-9_]*=\(/ },
  { name: "function keyword", re: /(^|[\s;&|])function\s+[A-Za-z_]/ },
  { name: "&> redirection", re: /&>/ },
];

/** The command with every single-quoted span removed (POSIX: no escapes inside single quotes). */
export function outsideSingleQuotes(command: string): string {
  let out = "";
  let quoted = false;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (!quoted && c === "\\") {
      out += command.slice(i, i + 2);
      i++;
      continue;
    }
    if (c === "'") {
      quoted = !quoted;
      out += " ";
      continue;
    }
    if (!quoted) out += c;
  }
  return out;
}

let guestShell: string | undefined;
function shell(): string {
  guestShell ??= spawnSync("sh", ["-c", "command -v dash"], { encoding: "utf8" }).status === 0 ? "dash" : "sh";
  return guestShell;
}

/**
 * What the guest's /bin/sh would refuse in `command`, split by certainty. `refused`: a syntax error under `sh -n`
 * (no false positives on a command that runs under dash today) or `pipefail` outside single quotes (dash has no such
 * option). `suspect`: the other bash-only constructs, which a pattern can mistake in quoted text.
 */
export function guestShellProblems(command: string): { refused: string[]; suspect: string[] } {
  const refused: string[] = [];
  const suspect: string[] = [];
  const syntax = spawnSync(shell(), ["-n"], { input: command, encoding: "utf8", timeout: 20_000 });
  if (syntax.status !== 0) refused.push(`${shell()} -n: ${(syntax.stderr || "syntax error").trim().slice(0, 300)}`);
  const bare = outsideSingleQuotes(command);
  for (const { name, re } of BASHISMS) if (re.test(bare)) (name === "set -o pipefail" ? refused : suspect).push(`bash-only for /bin/sh: ${name}`);
  return { refused, suspect };
}
