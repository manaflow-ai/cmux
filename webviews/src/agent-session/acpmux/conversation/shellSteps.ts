// A shell command's structure, for the labels a row, the live line and a note draw (shortCommand.ts,
// commandActions.ts). Leo, 2026-11-07, on a row that read "Ran 0*.mov) …" for
// `V=$(ls "…/0/"*.mov); ffmpeg … | python3 -c "…"`: "It only showed the zero asterisk dot MOV,
// which is worse than, like, ran whatever." A command splits into its steps (`;`, `&&`, `||`,
// newlines, subshells and `{ …; }` groups), never inside quotes, `$(…)`, backticks or a heredoc's
// body; a step splits into its pipeline's stages and words. A step that only feeds a later one (an
// assignment from `$(ls …)`, an `echo`, a `cd`) is plumbing, so the step that does the work names
// the command. No step is cut into a fragment: a word is whole or left out.
import { isPlainCd } from "./commandFolder";

export type Word = { text: string; raw: string; start: number; end: number };

// ---------------------------------------------------------------------------------------------
// Steps.

/// Words that open or close a compound command; what follows `if`, `while`, `do` is a command.
const KEYWORD_PREFIX = /^(?:if|then|else|elif|do|while|until|!)\s+/;
const KEYWORD_ALONE = /^(?:fi|done|esac|then|else|do|\{|\}|\(|\))$/;
/// A loop's or case's header: its words are a list, not a command.
const HEADER = /^(?:for|select|case)\s/;

/// A heredoc's start in a step: `<<EOF`, `<<-'EOF'`, `<< "EOF"`, never a here-string (`<<<`).
const HEREDOC = /^<<(-?)[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|\\?([A-Za-z_][\w.-]*))/;

/// The command's steps, in order, with heredoc bodies and comments left out (a heredoc's marker
/// stays on its step). A subshell or `{ …; }` group is its own steps; `if`/`while`/`do` before a
/// command go, and `for … in`, `fi`, `done` are no steps.
export function splitSteps(command: string): string[] {
  const out: string[] = [];
  for (const step of rawSteps(command)) {
    let text = step.trim();
    while (KEYWORD_PREFIX.test(text)) text = text.replace(KEYWORD_PREFIX, "").trim();
    if (!text || KEYWORD_ALONE.test(text) || HEADER.test(text)) continue;
    const group = groupBody(text);
    if (group !== undefined) out.push(...splitSteps(group));
    else out.push(text);
  }
  return out;
}

/// `( … )` or `{ …; }` around a whole step: its inside.
function groupBody(step: string): string | undefined {
  if (step.startsWith("(") && !step.startsWith("((") && closes(step, 0) === step.length - 1) return step.slice(1, -1);
  if (/^\{\s/.test(step) && /(?:^|[\s;])\}$/.test(step)) return step.slice(1, -1);
  return undefined;
}

/// The index of the `)` that closes the `(` at `open`, quotes and nesting respected.
function closes(text: string, open: number): number {
  let depth = 0;
  for (let i = open; i < text.length; i += 1) {
    const c = text[i]!;
    if (c === "\\") i += 1;
    else if (c === "'" || c === '"' || c === "`") i = quoteEnd(text, i);
    else if (c === "(") depth += 1;
    else if (c === ")" && --depth === 0) return i;
  }
  return -1;
}

/// The index of the quote that closes the one at `at` (the end of the text when none does).
function quoteEnd(text: string, at: number): number {
  const q = text[at]!;
  for (let i = at + 1; i < text.length; i += 1) {
    if (text[i] === "\\" && q !== "'") i += 1;
    else if (text[i] === q) return i;
  }
  return text.length;
}

function rawSteps(command: string, bodies: string[] = []): string[] {
  const out: string[] = [];
  let current = "";
  let depth = 0;
  let pending: { end: string; tabs: boolean }[] = [];
  const push = () => {
    out.push(current);
    current = "";
  };
  for (let i = 0; i < command.length; i += 1) {
    const c = command[i]!;
    if (c === "\\" && i + 1 < command.length) {
      // A backslash before a newline joins the lines.
      current += command[i + 1] === "\n" ? " " : c + command[i + 1];
      i += 1;
      continue;
    }
    if (c === "'" || c === '"' || c === "`") {
      const end = quoteEnd(command, i);
      current += command.slice(i, end + 1);
      i = end;
      continue;
    }
    if (c === "<" && command[i + 1] === "<" && command[i + 2] !== "<") {
      const match = HEREDOC.exec(command.slice(i));
      if (match) {
        pending.push({ end: match[2] ?? match[3] ?? match[4] ?? "", tabs: match[1] === "-" });
        current += match[0];
        i += match[0].length - 1;
        continue;
      }
    }
    if (c === "#" && (current === "" || /\s$/.test(current))) {
      // A comment runs to the line's end.
      while (i + 1 < command.length && command[i + 1] !== "\n") i += 1;
      continue;
    }
    if (c === "\n" && pending.length) {
      // The heredocs' bodies follow the line that opened them.
      let at = i + 1;
      for (const doc of pending) {
        const body: string[] = [];
        for (;;) {
          if (at >= command.length) break;
          const stop = command.indexOf("\n", at);
          const line = command.slice(at, stop < 0 ? command.length : stop);
          at = stop < 0 ? command.length : stop + 1;
          if ((doc.tabs ? line.replace(/^\t+/, "") : line) === doc.end) break;
          body.push(line);
        }
        bodies.push(body.join("\n"));
      }
      pending = [];
      i = at - 1;
      if (depth === 0) push();
      else current += "\n";
      continue;
    }
    if (c === "$" && command[i + 1] === "(") {
      depth += 1;
      current += "$(";
      i += 1;
      continue;
    }
    if (c === "(") depth += 1;
    else if (c === ")" && depth > 0) depth -= 1;
    if (depth === 0) {
      const pair = command.slice(i, i + 2);
      if (pair === "&&" || pair === "||") {
        push();
        i += 1;
        continue;
      }
      // A lone `&` stays inside its step: `cd /tmp & curl … | sh` keeps both, so a backgrounded
      // step is never read as setup the label may leave out (#20456).
      if (c === ";" || c === "\n") {
        if (command[i + 1] === ";") i += 1;
        push();
        continue;
      }
    }
    current += c;
  }
  push();
  return out;
}

// ---------------------------------------------------------------------------------------------
// Words.

/// A step's words, unquoted (`text`) and as typed (`raw`, with its place in the step), and `|`
/// between pipeline stages. `$(…)` and backticks stay inside their word.
export function shellWords(step: string): (Word | "|")[] {
  const out: (Word | "|")[] = [];
  let text = "";
  let raw = "";
  let open = false;
  let start = 0;
  let depth = 0;
  const end = (at: number) => {
    if (open) out.push({ text, raw, start, end: at });
    text = "";
    raw = "";
    open = false;
  };
  for (let i = 0; i < step.length; i += 1) {
    const c = step[i]!;
    if (depth > 0) {
      raw += c;
      text += c;
      if (c === "(") depth += 1;
      else if (c === ")") depth -= 1;
      continue;
    }
    if (/\s/.test(c)) {
      end(i);
      continue;
    }
    if (c === "|") {
      end(i);
      if (step[i + 1] === "&") i += 1;
      out.push("|");
      continue;
    }
    if (!open) start = i;
    open = true;
    if (c === "'") {
      const close = step.indexOf("'", i + 1);
      const stop = close < 0 ? step.length : close;
      text += step.slice(i + 1, stop);
      raw += step.slice(i, stop + 1);
      i = stop;
    } else if (c === '"') {
      raw += c;
      for (i += 1; i < step.length && step[i] !== '"'; i += 1) {
        if (step[i] === "\\" && i + 1 < step.length) {
          raw += step[i];
          i += 1;
        }
        raw += step[i];
        text += step[i];
      }
      if (i < step.length) raw += '"';
    } else if (c === "\\" && i + 1 < step.length) {
      raw += c + step[i + 1];
      text += step[i + 1];
      i += 1;
    } else if (c === "$" && step[i + 1] === "(") {
      raw += "$(";
      text += "$(";
      depth = 1;
      i += 1;
    } else if (c === "`") {
      const close = step.indexOf("`", i + 1);
      const stop = close < 0 ? step.length : close;
      raw += step.slice(i, stop + 1);
      text += step.slice(i, stop + 1);
      i = stop;
    } else {
      raw += c;
      text += c;
    }
  }
  end(step.length);
  return out;
}

/// An output redirect (`2>/dev/null`, `>out.txt`, `2>&1`, `&>log`) and its target, when the target
/// is the next word. Input redirects and heredocs are part of what ran and stay.
const REDIRECT = /^(\d*|&)(>&|>>?)(.*)$/;

/// One pipeline stage: its words without redirects (what the table reads), the words a row shows
/// (a write to a file stays: it changed something; `word` false for a redirect), and whether it
/// writes a file and to which (`append` for `>>`).
export type Stage = {
  words: Word[];
  shown: { raw: string; word: boolean }[];
  writes: boolean;
  targets: { path: string; append: boolean }[];
};

/// A step's pipeline stages. Output to /dev/null and fd copies (`2>&1`) are plumbing and go; a write
/// to a file (`> out.txt`, `>> log`) is what the step did and stays on the line.
export function stages(step: string): Stage[] {
  const all = shellWords(step);
  const out: Stage[] = [{ words: [], shown: [], writes: false, targets: [] }];
  for (let i = 0; i < all.length; i += 1) {
    const word = all[i]!;
    if (word === "|") {
      out.push({ words: [], shown: [], writes: false, targets: [] });
      continue;
    }
    const stage = out.at(-1)!;
    const match = /^["'`]/.test(word.raw) ? null : REDIRECT.exec(word.raw);
    if (!match) {
      stage.words.push(word);
      stage.shown.push({ raw: word.raw, word: true });
      continue;
    }
    const next = all[i + 1];
    const attached = match[3] !== "";
    const target = attached ? match[3]! : next !== undefined && next !== "|" ? next.text : "";
    const raw = attached || next === undefined || next === "|" ? word.raw : `${word.raw} ${next.raw}`;
    if (!attached && next !== undefined && next !== "|") i += 1;
    const plumbing =
      /^\/dev\/(?:null|stdout|stderr)$/.test(target) || (match[2] === ">&" && /^(?:\d+|-)$/.test(target));
    if (plumbing) continue;
    stage.writes = true;
    stage.targets.push({ path: target, append: match[2] === ">>" });
    stage.shown.push({ raw, word: false });
  }
  return out.filter((stage) => stage.words.length > 0);
}

export const baseName = (path: string) => path.replace(/\/+$/, "").split("/").pop() || path;

export const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/// Wrappers that run the program after them: `sudo`, `timeout 20`, `env A=1`, `nice -n 5`, `npx`,
/// and assignments before a program (`FOO=1 cargo test`).
export function unwrap(words: string[]): string[] {
  let rest = words;
  for (;;) {
    const head = rest[0];
    if (head === undefined) return rest;
    if (ASSIGNMENT.test(head)) {
      rest = rest.slice(1);
      continue;
    }
    const name = baseName(head);
    const drop = (values: string[]) => {
      let i = 1;
      while (i < rest.length && rest[i]!.startsWith("-")) i += values.includes(rest[i]!) ? 2 : 1;
      return i;
    };
    if (name === "sudo") rest = rest.slice(drop(["-u", "-g", "-C", "-D", "-h", "-p", "-U"]));
    else if (name === "timeout" || name === "gtimeout") {
      const at = drop(["-s", "--signal", "-k", "--kill-after"]);
      rest = rest.slice(at + 1);
    } else if (name === "env") rest = rest.slice(drop(["-u", "--unset", "-C", "--chdir", "-S"]));
    else if (name === "nice") rest = rest.slice(drop(["-n", "--adjustment"]));
    else if (["time", "command", "exec", "nohup", "npx", "bunx", "uvx"].includes(name)) rest = rest.slice(drop([]));
    else return rest;
  }
}

/// The commands inside a word's `$(…)` and backticks; undefined when it has a process
/// substitution (`<(…)`), which the labels never look into.
export function substitutions(raw: string): string[] | undefined {
  if (/[<>]\(/.test(raw)) return undefined;
  const out: string[] = [];
  for (let i = 0; i < raw.length; i += 1) {
    if (raw[i] === "'" && !insideDouble(raw, i)) i = quoteEnd(raw, i);
    else if (raw[i] === "$" && raw[i + 1] === "(") {
      const close = closes(raw, i + 1);
      const stop = close < 0 ? raw.length : close;
      out.push(raw.slice(i + 2, stop));
      i = stop;
    } else if (raw[i] === "`") {
      const close = raw.indexOf("`", i + 1);
      const stop = close < 0 ? raw.length : close;
      out.push(raw.slice(i + 1, stop));
      i = stop;
    }
  }
  return out;
}

function insideDouble(raw: string, at: number): boolean {
  let inside = false;
  for (let i = 0; i < at; i += 1) {
    if (raw[i] === "\\") i += 1;
    else if (raw[i] === '"') inside = !inside;
  }
  return inside;
}

// ---------------------------------------------------------------------------------------------
// Setup and plumbing.

/// A step that only sets the shell up: an export, a bare assignment, a set. A cd counts only into a
/// plain path (isPlainCd, the rule a Ran row uses). A `source` or `.` runs a script, and a step with
/// a substitution (`$(…)`, backticks, `<(…)`), a pipe or a `&` runs code, so none is setup: the
/// label never reads as a harmless command the setup ran past (commandFolder.ts, #20456).
const SETUP = /^(?:export|pushd|set|unset|ulimit|umask)(?:\s|$)|^[A-Za-z_][A-Za-z0-9_]*=\S*$/;
const RUNS_CODE = /\$\(|`|[<>]\(|[|&]/;

export function isSetup(step: string): boolean {
  return isPlainCd(step) || (SETUP.test(step) && !RUNS_CODE.test(step));
}

/// Steps that only print, wait or move around, never what a command is for: `ls`, `echo`, `cd`.
const PLUMBING = new Set([
  "cd",
  "ls",
  "echo",
  "printf",
  "pwd",
  "true",
  "false",
  ":",
  "sleep",
  "date",
  "[",
  "[[",
  "test",
]);
/// What a substitution may run and still only feed a later step: a value read, a path made.
const FEEDS = new Set([
  ...PLUMBING,
  "basename",
  "dirname",
  "realpath",
  "readlink",
  "cat",
  "head",
  "tail",
  "cut",
  "tr",
  "wc",
  "sort",
  "which",
  "mktemp",
  "whoami",
  "hostname",
  "uname",
  "nproc",
]);
const GIT_FEEDS = new Set(["rev-parse", "merge-base", "symbolic-ref", "describe"]);

/// Whether a step only feeds or reports, so another step names the command: an `ls`, `echo` or
/// `cd`; an assignment whose value is a word or a substitution that only feeds (`V=$(ls *.mov)`,
/// `H=$(git rev-parse HEAD)`). A write to a file, a pipe into anything but a filter, or a
/// substitution that runs anything else (`X=$(rm -rf x)`, `cd "$(curl …|sh)"`) is never plumbing.
export function isPlumbing(step: string, feeding = false): boolean {
  const parts = stages(step);
  if (parts.length === 0) return true;
  if (parts.some((stage) => stage.writes)) return false;
  for (const stage of parts)
    for (const word of stage.words) {
      const inner = substitutions(word.raw);
      if (!inner) return false;
      if (!inner.every((sub) => splitSteps(sub).every((part) => isPlumbing(part, true)))) return false;
    }
  const allowed = feeding ? FEEDS : PLUMBING;
  return parts.every((stage, index) => {
    const words = stage.words.map((word) => word.text);
    if (index === 0 && words.every((word) => ASSIGNMENT.test(word))) return true;
    const [program, ...args] = unwrap(words);
    if (!program) return true;
    const name = baseName(program);
    if (allowed.has(name)) return true;
    if (index > 0 && FEEDS.has(name)) return true;
    if (!feeding || name !== "git") return false;
    // `git -C dir`, `-c key=value` come before the subcommand.
    let at = 0;
    while (at < args.length && args[at]!.startsWith("-")) at += ["-C", "-c"].includes(args[at]!) ? 2 : 1;
    return GIT_FEEDS.has(args[at] ?? "");
  });
}

/// The step that names the command and whether steps follow it: the first that is neither setup
/// nor plumbing, else the first that is not setup, else the first. `before` are the steps ahead of
/// it (an assignment there can say what a later `$V` holds).
export function mainStep(command: string): { step: string; more: boolean; before: string[]; bodies: string[] } {
  const all = splitSteps(command.trim());
  if (all.length === 0) return { step: "", more: false, before: [], bodies: [] };
  let at = all.findIndex((step) => !isSetup(step) && !isPlumbing(step));
  if (at < 0) at = all.findIndex((step) => !isSetup(step));
  const more = at >= 0 && at < all.length - 1;
  if (at < 0) at = 0;
  // The heredoc bodies the step reads, in order: the ones before it belong to earlier steps.
  const docs = heredocBodies(command.trim());
  const skip = all.slice(0, at).reduce((n, step) => n + heredocMarkers(step), 0);
  const bodies = docs.slice(skip, skip + heredocMarkers(all[at]!));
  return { step: all[at]!, more, before: all.slice(0, at), bodies };
}

/// Every heredoc's body in the command, in the order their markers open them.
export function heredocBodies(command: string): string[] {
  const bodies: string[] = [];
  rawSteps(command, bodies);
  return bodies;
}

/// How many heredocs a step opens (`<<EOF`, `<< 'EOF'`, never a here-string `<<<`).
export function heredocMarkers(step: string): number {
  return shellWords(step).filter((word) => word !== "|" && /^<<(?!<)/.test(word.raw)).length;
}

/// The step without the assignments before its program (`FOO=1 BAR='a b' bun test` is `bun
/// test`), each assignment whole. A step that is only assignments stays as it is.
export function withoutAssignments(step: string): string {
  const words = shellWords(step);
  let at = 0;
  while (at < words.length) {
    const word = words[at]!;
    if (word === "|" || !ASSIGNMENT.test(word.raw)) break;
    at += 1;
  }
  const next = words[at];
  if (at === 0 || next === undefined) return step;
  return next === "|" ? step : step.slice(next.start);
}

/// Whether a step is only assignments (`V=$(ls *.mov)`, `A=1 B=2`).
export function isAssignmentOnly(step: string): boolean {
  const words = shellWords(step);
  return words.length > 0 && words.every((word) => word !== "|" && ASSIGNMENT.test(word.raw));
}

/// The step without its heredoc markers (`<<'EOF'`, `<< EOF`): the body is not on the line, so the
/// marker says nothing (Leo, 2026-11-07: "it's just weird, um, that it just says EOF").
export function withoutHeredocMarkers(step: string): string {
  const words = shellWords(step);
  let out = "";
  let from = 0;
  for (let i = 0; i < words.length; i += 1) {
    const word = words[i]!;
    if (word === "|" || !/^<<(?!<)/.test(word.raw)) continue;
    const next = words[i + 1];
    const end = (word.raw === "<<" || word.raw === "<<-") && next && next !== "|" ? next.end : word.end;
    out += step.slice(from, word.start).trimEnd();
    from = end;
    if (end !== word.end) i += 1;
  }
  return (out + step.slice(from)).replace(/\s+$/, "");
}
