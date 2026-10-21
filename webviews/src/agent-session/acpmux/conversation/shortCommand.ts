// A shell command in a few words, for a one-line note that has no room for all of it (a background
// task's end, BackgroundTaskNote.tsx): the step that does the work, without the setup before it.
// `export PATH="…"; B=~/x; cd repo && cmux browser open …` reads "cmux browser open …" (Leo
// 2026-10-20: "a short human label, not the raw command").

/// A step that only sets the shell up: an export, a bare assignment, a cd, a set. A `source` or `.`
/// runs a script, so it is never setup.
const SETUP = /^(?:export|cd|pushd|set|unset|ulimit|umask)(?:\s|$)|^[A-Za-z_][A-Za-z0-9_]*=\S*$/;
/// A substitution (`$(…)`, backticks, `<(…)`), a pipe or a `&` runs code, so a setup step with one
/// (`cd "$(…)"`, `cd /tmp & curl …`) is never left out: nothing the call ran is hidden
/// (commandFolder.ts, #20456).
const RUNS_CODE = /\$\(|`|[<>]\(|[|&]/;
const isSetup = (step: string) => SETUP.test(step) && !RUNS_CODE.test(step);
/// Assignments before a program (`FOO=1 BAR=2 cargo test`).
const LEADING_ASSIGNMENTS = /^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S)*\s+)+/;

/// The command's steps, split on `;`, `&&`, `||` and newlines outside quotes.
function steps(command: string): string[] {
  const out: string[] = [];
  let quote: string | undefined;
  let current = "";
  for (let index = 0; index < command.length; index += 1) {
    const char = command[index]!;
    if (quote) {
      if (char === "\\" && quote === '"' && index + 1 < command.length) {
        current += char + command[(index += 1)]!;
        continue;
      }
      if (char === quote) quote = undefined;
      current += char;
      continue;
    }
    if (char === '"' || char === "'") quote = char;
    const pair = command.slice(index, index + 2);
    if (char === ";" || char === "\n" || pair === "&&" || pair === "||") {
      out.push(current.trim());
      current = "";
      if (pair === "&&" || pair === "||") index += 1;
      continue;
    }
    current += char;
  }
  out.push(current.trim());
  return out.filter(Boolean);
}

/// A program named by its path reads as its name: `/opt/x/bin/cmux` is `cmux`.
function programName(step: string): string {
  const match = /^(?:"([^"]+)"|'([^']+)'|(\S+))(.*)$/s.exec(step);
  if (!match) return step;
  const program = match[1] ?? match[2] ?? match[3] ?? "";
  const name = program.includes("/") ? (program.split("/").filter(Boolean).pop() ?? program) : program;
  return `${name}${match[4] ?? ""}`;
}

/// `command` in at most `max` characters: its first step that is not setup, its program by name,
/// an ellipsis where steps or words were left out.
export function shortCommand(command: string, max = 60): string {
  const all = steps(command.trim());
  if (all.length === 0) return "";
  const at = all.findIndex((step) => !isSetup(step));
  const step = at < 0 ? all[0]! : all[at]!;
  let text = programName(step.replace(LEADING_ASSIGNMENTS, "")).replace(/\s+/g, " ");
  const more = at >= 0 && at < all.length - 1;
  if (text.length > max) text = `${text.slice(0, max - 1).trimEnd()}…`;
  else if (more) text = `${text} …`;
  return text;
}
