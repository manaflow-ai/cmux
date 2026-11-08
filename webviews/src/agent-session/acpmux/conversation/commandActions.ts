// What a shell command did, in words (Leo, 2026-11-07: "it's not just you ran a command. It's that
// you ran a specific thing"): a known program and subcommand read as a past-tense verb and its main
// argument, `agent-memory search "x" 2>/dev/null | head -12` as Searched memory for “x”. The table
// below is the whole vocabulary; a program or subcommand it does not list gets no meaning, and its
// row reads as its command line without the plumbing after it (`cleanCommand`). Only the first
// step of a compound command is named, with an ellipsis for the rest, so a label never claims more
// than that step did. The opened row's Shell block always shows the whole line as it ran.
//
// Claude's Bash calls also carry a `description` the model wrote ("Search prior tooltip work");
// Codex's exec calls carry none (acpmux passes `rawInput: {command, commandLine, cwd}`, and the
// reads, searches and listings its app server parses arrive as read and search calls already).
// The table comes first because it is read off what ran: a description is the model's own words
// and could say one thing while the command does another (the reason #36940 drew commands as
// typed). A description names only what the table cannot (`commandSaid`).
import type { StringKey, StringValues, Translate } from "../i18n";
import { experimentArm } from "../../../experiments/experiment";
import type { AcpmuxActivity } from "../model";
import { commandLabelLook, type CommandLabelLook } from "./commandLabel.experiment";
import { ROW_WIDTH, shortCommand } from "./shortCommand";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// One named action: its string and values, and for a run of them, the bare phrase a group repeats
/// ("Searched memory twice") and the files a read opened.
export type CommandAction = {
  key: StringKey;
  values?: StringValues;
  bare?: StringKey;
  files?: string[];
  /// Steps after the named one, left unnamed.
  more?: boolean;
};

type Act = Omit<CommandAction, "more">;
type Word = { text: string; raw: string };

// ---------------------------------------------------------------------------------------------
// Words.

/// A shell step's words, unquoted (`text`) and as typed (`raw`), and `|` between pipeline stages.
/// `$(…)` and backticks stay inside their word. Steps were split on `&&`, `||`, `;` and newlines
/// already (shortCommand.ts).
export function shellWords(step: string): (Word | "|")[] {
  const out: (Word | "|")[] = [];
  let text = "";
  let raw = "";
  let open = false;
  let depth = 0;
  const end = () => {
    if (open) out.push({ text, raw });
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
      end();
      continue;
    }
    if (c === "|") {
      end();
      if (step[i + 1] === "&") i += 1;
      out.push("|");
      continue;
    }
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
  end();
  return out;
}

/// An output redirect (`2>/dev/null`, `>out.txt`, `2>&1`, `&>log`): `target` when its file is the
/// next word. Input redirects and heredocs are part of what ran and stay.
const REDIRECT = /^(?:\d*|&)(?:>>?|>&)(.*)$/;
function redirect(word: Word): "self" | "target" | undefined {
  if (/^["'`]/.test(word.raw)) return undefined;
  const match = REDIRECT.exec(word.raw);
  if (!match) return undefined;
  return match[1] ? "self" : "target";
}

/// A step's pipeline stages, each its words without output redirects.
function stages(step: string): Word[][] {
  const out: Word[][] = [[]];
  let skipNext = false;
  for (const word of shellWords(step)) {
    if (word === "|") {
      out.push([]);
      continue;
    }
    if (skipNext) {
      skipNext = false;
      continue;
    }
    const kind = redirect(word);
    if (kind === "target") skipNext = true;
    if (kind) continue;
    out.at(-1)!.push(word);
  }
  return out.filter((stage) => stage.length > 0);
}

/// A stage that only trims or reshapes what came before it: `| head -12`, `| cut -c1-220`, `| wc -l`,
/// `| sort | uniq`, `| grep -v test`, `| jq .`. None of these can write a file or run a program;
/// `sort -o`, `uniq IN OUT` and `sort --compress-program` can, so those are not filters.
const FILTERS = new Set(["head", "tail", "cut", "wc", "jq", "column", "tr", "nl", "fold", "less", "more"]);
function isFilter(stage: Word[]): boolean {
  const name = baseName(stage[0]!.text);
  const args = stage.slice(1).map((word) => word.text);
  if (FILTERS.has(name)) return true;
  if (name === "cat") return stage.length === 1;
  if (name === "sort") return !args.some((arg) => /^-[A-Za-z]*o|^--output|^--compress-program/.test(arg));
  if (name === "uniq") return args.filter((arg) => !arg.startsWith("-") || arg === "-").length < 2;
  if (name === "grep" || name === "rg") return stage.some((word) => /^-[A-Za-z]*v[A-Za-z]*$/.test(word.raw));
  return false;
}

/// A later pipeline stage that only reads what came before it and prints a part of it, for a label
/// read off the first stage (`commandAction`): the filters, any grep, a `sed` or `awk` that can only
/// print. `tee`, `xargs`, a shell or anything unknown can write or run, so the line stays.
function passesThrough(stage: Word[]): boolean {
  const name = baseName(stage[0]!.text);
  const args = stage.slice(1).map((word) => word.text);
  if (isFilter(stage) || ["grep", "egrep", "fgrep"].includes(name)) return true;
  // `rg --pre CMD` runs CMD on every file.
  if (name === "rg") return !args.some((arg) => /^--pre(?:=|$)/.test(arg));
  if (name === "sed") return sedPrintsOnly(args);
  if (name === "awk") return awkPrintsOnly(args);
  return false;
}

/// One sed command that only prints, deletes or substitutes on its stream: an optional address
/// (`12`, `$`, `/re/`, `1,20`), then `p`, `d`, `q`, `=`, `n`, `N`, `P`, `D`, `{`/`}`, or `s///` with
/// flags from g, p, i, I, m, M and a count. `w`, `W`, `r`, `R`, `e` and the `s///w`/`s///e` flags write
/// files or run commands, so they never pass; anything this cannot read does not pass either.
const SED_ADDRESS = String.raw`(?:\d+|\$|/(?:[^/\\]|\\.)*/[IM]*)(?:\s*,\s*(?:\d+|\$|/(?:[^/\\]|\\.)*/[IM]*|[+~]\d+))?`;
const SED_PLAIN = new RegExp(String.raw`^(?:${SED_ADDRESS})?\s*!?\s*(?:[pdqQ=nNPDgGhHxl{}]|[qQ]\s*\d+)?$`);
function sedCommandPrintsOnly(command: string): boolean {
  const text = command.trim();
  if (SED_PLAIN.test(text)) return true;
  const sub = new RegExp(String.raw`^(?:${SED_ADDRESS})?\s*!?\s*s(.)`).exec(text);
  if (!sub) return false;
  const delim = sub[1]!;
  if (delim === "\\" || delim === "\n") return false;
  // Walk past the pattern and the replacement, honouring escapes, then read the flags.
  let i = sub[0].length;
  for (let part = 0; part < 2; part += 1) {
    while (i < text.length && text[i] !== delim) i += text[i] === "\\" ? 2 : 1;
    if (i >= text.length) return false;
    i += 1;
  }
  return /^[gpiImM0-9]*$/.test(text.slice(i));
}
function sedPrintsOnly(args: string[]): boolean {
  const scripts: string[] = [];
  let positional = false;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i]!;
    if (arg === "-e" || arg === "--expression") scripts.push(args[(i += 1)] ?? "");
    else if (arg.startsWith("--expression=")) scripts.push(arg.slice("--expression=".length));
    else if (/^-[nEr]+$/.test(arg) || ["--quiet", "--silent", "--regexp-extended", "-u", "--unbuffered"].includes(arg))
      continue;
    // -i edits in place, -f reads a script this cannot see, -s/-z and the rest change nothing here
    // but are rare enough to keep the line.
    else if (arg.startsWith("-")) return false;
    else if (!positional && scripts.length === 0) {
      scripts.push(arg);
      positional = true;
    }
  }
  if (scripts.length === 0) return false;
  // Commands split on `;` and newlines; a `;` inside a substitution makes a part unreadable, and an
  // unreadable part keeps the line.
  return scripts.every((script) => script.split(/[;\n]/).every(sedCommandPrintsOnly));
}

/// An awk program that only prints to its stream: no `>`/`|` (print to a file or a command, which
/// also rules out comparisons, kept as the line), no system(), no getline, no -f program file, no
/// gawk `-i inplace`. Only -F and -v flags pass.
function awkPrintsOnly(args: string[]): boolean {
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i]!;
    if (arg === "-F" || arg === "-v") i += 1;
    else if (/^-[Fv]./.test(arg)) continue;
    else if (arg.startsWith("-")) return false;
    else if (/[>|]|system\s*\(|getline|@include|@load/.test(arg)) return false;
  }
  return true;
}

/// The step's main part and whether steps follow it: shortCommand's first step that is not setup
/// (`cd x &&`, `export …`, `FOO=1`), its program by name.
function mainStep(command: string): { step: string; more: boolean } {
  const short = shortCommand(command, ROW_WIDTH);
  return short.endsWith(" …") ? { step: short.slice(0, -2), more: true } : { step: short, more: false };
}

/// The command as a row draws it when the table does not name it: its first step, without output
/// redirects and the filters piped after it ("make -j8 2>&1 | tail -20" is "make -j8"). The opened
/// Shell block keeps the whole line.
export function cleanCommand(command: string): string {
  const { step, more } = mainStep(command);
  const parts = stages(step);
  while (parts.length > 1 && isFilter(parts.at(-1)!)) parts.pop();
  const line = parts.map((stage) => stage.map((word) => word.raw).join(" ")).join(" | ") || step;
  return more ? `${line} …` : line;
}

// ---------------------------------------------------------------------------------------------
// Arguments.

const baseName = (path: string) => path.replace(/\/+$/, "").split("/").pop() || path;

/// Flags and positionals. `values` lists the flags that take the next word as their value; `--x=y`
/// and anything after `--` are handled for every program.
function parse(words: readonly string[], values: readonly string[] = []) {
  const takes = new Set(values);
  const flags = new Map<string, string | true>();
  const positional: string[] = [];
  for (let i = 0; i < words.length; i += 1) {
    const word = words[i]!;
    if (word === "--") {
      positional.push(...words.slice(i + 1));
      break;
    }
    if (word.startsWith("--") && word.includes("=")) {
      const at = word.indexOf("=");
      flags.set(word.slice(0, at), word.slice(at + 1));
    } else if (word.startsWith("-") && word.length > 1) {
      if (takes.has(word) && i + 1 < words.length) flags.set(word, words[(i += 1)]!);
      else flags.set(word, true);
    } else positional.push(word);
  }
  const has = (...names: string[]) => names.some((name) => flags.has(name));
  const value = (...names: string[]) => {
    for (const name of names) {
      const found = flags.get(name);
      if (typeof found === "string") return found;
    }
    return undefined;
  };
  return { positional, has, value };
}

/// Quoted words (a search, a commit message): one line, at most 80 characters, so the closing quote
/// shows. Paths and names are never cut: the row's CSS ellipsis cuts the line at its edge.
const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

function subject(text: string): string {
  const line = text.replace(/\s+/g, " ").trim();
  return line.length > 80 ? `${line.slice(0, 79).trimEnd()}…` : line;
}

/// `#123` for a number, else as typed (a branch, a URL).
const numbered = (value: string) => (/^\d+$/.test(value) ? `#${value}` : oneLine(value));

const read = (files: readonly string[]): Act | undefined =>
  files.length === 0
    ? undefined
    : files.length === 1
      ? { key: "command.read", values: { file: baseName(files[0]!) }, files: [...files] }
      : { key: "tools.read.other", values: { n: files.length }, files: [...files] };

const search = (pattern: string | undefined): Act | undefined =>
  pattern
    ? { key: "command.searched", values: { pattern: subject(pattern) }, bare: "command.bare.searched" }
    : undefined;

const listed = (path: string | undefined): Act =>
  !path || path === "." || path === "./"
    ? { key: "command.listedFiles", bare: "command.listedFiles" }
    : { key: "command.listed", values: { path: oneLine(path) }, bare: "command.listedFiles" };

/// The folder `find` lists: its first argument after the symlink options (-H, -L, -P, -D x, -Olevel)
/// when that is no predicate (`-name`, `(`, `!`); none, the folder it runs in.
function findRoot(args: string[]): string | undefined {
  let at = 0;
  while (/^-([HLP]|O\d*)$/.test(args[at] ?? "") || args[at] === "-D") at += args[at] === "-D" ? 2 : 1;
  const root = args[at];
  return root && !/^[-(!)]/.test(root) ? root : undefined;
}

const ranScript = (script: string): Act => ({ key: "tools.ranCommand", values: { command: baseName(script) } });

// ---------------------------------------------------------------------------------------------
// The table: program, then subcommand, to a verb and its main argument.

type Rule = (args: string[]) => Act | undefined;

const GIT: Record<string, Rule> = {
  status: () => ({ key: "command.git.status" }),
  diff: () => ({ key: "command.git.diff" }),
  log: () => ({ key: "command.git.log" }),
  show: (args) => {
    const ref = parse(args).positional[0];
    if (!ref) return { key: "command.git.show", values: { target: "HEAD" } };
    const at = ref.indexOf(":");
    return at >= 0 && at < ref.length - 1
      ? read([ref.slice(at + 1)])
      : { key: "command.git.show", values: { target: oneLine(ref) } };
  },
  add: (args) => {
    const { positional, has } = parse(args);
    if (has("-A", "--all", "-u", "--update") || positional.includes(".") || !positional.length)
      return { key: "command.git.addAll" };
    return { key: "command.git.add", values: { paths: positional.map(baseName).join(", ") } };
  },
  commit: (args) => {
    const message = parse(args, ["-m", "--message", "-F", "-C", "-c", "--author", "--date"]).value("-m", "--message");
    return message
      ? { key: "command.git.commitMessage", values: { message: subject(message.split("\n")[0]!) } }
      : { key: "command.git.commit" };
  },
  push: (args) => {
    const { positional, has } = parse(args, ["-o", "--push-option", "--repo"]);
    if (has("-d", "--delete")) return undefined;
    const ref = positional[1];
    const branch = ref?.slice(ref.lastIndexOf(":") + 1).replace(/^refs\/heads\//, "");
    return branch ? { key: "command.git.pushBranch", values: { branch } } : { key: "command.git.push" };
  },
  checkout: (args) => switchTo(args, ["-b", "-B"]),
  switch: (args) => switchTo(args, ["-c", "-C", "--create"]),
  rebase: (args) => {
    const { positional, has } = parse(args, ["--onto", "-s", "--strategy", "-X"]);
    if (has("--continue", "--abort", "--skip", "--quit", "--edit-todo")) return undefined;
    const onto = parse(args, ["--onto"]).value("--onto") ?? positional[0];
    return onto ? { key: "command.git.rebase", values: { ref: oneLine(onto) } } : undefined;
  },
  merge: (args) => {
    const { positional, has } = parse(args, ["-m", "-s", "--strategy", "-X"]);
    if (has("--continue", "--abort", "--quit") || !positional[0]) return undefined;
    return { key: "command.git.merge", values: { ref: oneLine(positional.join(", ")) } };
  },
  fetch: () => ({ key: "command.git.fetch" }),
  pull: () => ({ key: "command.git.pull" }),
  branch: (args) => {
    const { positional, has } = parse(args);
    return positional.length || has("-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy")
      ? undefined
      : { key: "command.git.branches" };
  },
};

function switchTo(args: string[], create: string[]): Act | undefined {
  const { positional, value } = parse(args, create);
  const made = value(...create);
  if (made) return { key: "command.git.newBranch", values: { branch: made } };
  if (args.includes("--") || positional.length !== 1) return undefined;
  return { key: "command.git.switch", values: { branch: positional[0]! } };
}

/// gh's subcommands; `-R`/`--repo` takes the repository.
const GH_VALUES = ["-R", "--repo", "--json", "-q", "--jq", "-t", "--template", "-L", "--limit", "-s", "--state"];
const ghTarget = (args: string[]) =>
  parse(args, [
    ...GH_VALUES,
    "-b",
    "--branch",
    "--title",
    "--body",
    "--body-file",
    "-B",
    "--base",
    "-H",
    "--head",
    "--label",
    "-l",
    "--author",
    "-A",
    "--match-head-commit",
    "-w",
    "--workflow",
    "-j",
    "--job",
    "-u",
    "--user",
  ]).positional[0];

const GH: Record<string, Record<string, Rule>> = {
  pr: {
    view: (args) => target("command.gh.prView", "pr", ghTarget(args)),
    list: () => ({ key: "command.gh.prList" }),
    checks: (args) => target("command.gh.prChecks", "pr", ghTarget(args)),
    diff: (args) => target("command.gh.prDiff", "pr", ghTarget(args)),
    // `--auto` only schedules the merge and `--disable-auto` cancels one: neither merged, so the line stays.
    merge: (args) =>
      args.some((arg) => /^--(?:auto|disable-auto)(?:=|$)/.test(arg))
        ? undefined
        : target("command.gh.prMerge", "pr", ghTarget(args)),
    create: () => ({ key: "command.gh.prCreate" }),
  },
  issue: {
    view: (args) => target("command.gh.issueView", "issue", ghTarget(args)),
    list: () => ({ key: "command.gh.issueList" }),
  },
  run: {
    view: (args) => {
      const id = ghTarget(args);
      return id ? { key: "command.gh.runView", values: { run: oneLine(id) } } : undefined;
    },
    list: () => ({ key: "command.gh.runList" }),
  },
};

function target(key: StringKey, name: string, value: string | undefined): Act | undefined {
  return value ? { key, values: { [name]: numbered(value) } } : undefined;
}

const RG_VALUES = [
  "-e",
  "--regexp",
  "-f",
  "--file",
  "-g",
  "--glob",
  "--iglob",
  "-t",
  "--type",
  "-T",
  "--type-not",
  "-A",
  "-B",
  "-C",
  "--context",
  "--after-context",
  "--before-context",
  "-m",
  "--max-count",
  "-M",
  "--max-columns",
  "-j",
  "--threads",
  "--sort",
  "--sortr",
  "--max-depth",
  "-d",
  "--type-add",
  "-r",
  "--replace",
  "--pre",
  "-E",
  "--encoding",
  "--colors",
  "--color",
];
const GREP_VALUES = [
  "-e",
  "--regexp",
  "-f",
  "--file",
  "-A",
  "-B",
  "-C",
  "-m",
  "--max-count",
  "--include",
  "--exclude",
  "--exclude-dir",
  "-d",
  "-D",
  "--label",
  "--color",
  "--colour",
];

function searched(args: string[], values: string[]): Act | undefined {
  const parsed = parse(args, values);
  // Patterns from a file: no word on the line is the pattern. Two or more -e: one would hide the rest.
  if (parsed.has("--file") || args.some((arg) => /^-[A-Za-z]*f/.test(arg))) return undefined;
  const patterns = args.filter((arg) => arg === "-e" || arg === "--regexp" || arg.startsWith("--regexp="));
  if (patterns.length > 1) return undefined;
  return search(parsed.value("-e", "--regexp") ?? parsed.positional[0]);
}

/// Files a reader named: head/tail take a count with -n and -c.
function readFiles(args: string[], values: string[] = []): Act | undefined {
  return read(parse(args, values).positional.filter((file) => file !== "-"));
}

function packageManager(tool: string): Rule {
  return (args) => {
    const [sub, ...rest] = args;
    switch (sub) {
      case undefined:
      case "install":
      case "i":
      case "add":
      case "ci":
        return { key: "command.installed", values: { tool } };
      case "test":
      case "t":
        return tested(tool, rest);
      case "build":
        return { key: "command.built", values: { tool } };
      case "run": {
        const [script, ...more] = rest;
        if (script === "build") return { key: "command.built", values: { tool } };
        if (script === "test") return tested(tool, more);
        return script && tool === "bun" && /\.[cm]?[jt]sx?$/.test(script) ? ranScript(script) : undefined;
      }
      default:
        return tool === "bun" && sub && /\.[cm]?[jt]sx?$/.test(sub) ? ranScript(sub) : undefined;
    }
  };
}

function tested(tool: string, args: string[]): Act {
  const file = parse(args, ["-t", "--test-name-pattern", "--timeout", "-p", "--package"]).positional.find((arg) =>
    /\.\w+$/.test(arg),
  );
  return file
    ? { key: "command.testedFile", values: { file: baseName(file) } }
    : { key: "command.tested", values: { tool } };
}

const SCRIPT = /\.(?:py|mjs|cjs|js|ts|tsx|rb|pl|sh|bash|zsh|swift)$/;

/// An interpreter running a script file names the script; `-c`, `-e`, `-` (stdin) and modules say
/// nothing the table knows, except `-m pytest`.
function interpreter(args: string[]): Act | undefined {
  if (args[0] === "-m") return args[1] === "pytest" ? { key: "command.tested", values: { tool: "pytest" } } : undefined;
  const script = args.find((arg) => !arg.startsWith("-"));
  if (!script || args.slice(0, args.indexOf(script)).some((arg) => ["-c", "-e", "--eval", "-"].includes(arg)))
    return undefined;
  return SCRIPT.test(script) || script.includes("/") ? ranScript(script) : undefined;
}

/// The flags that send a body or a file, curl's and wget's.
const SENDS = [
  "-d",
  "--data",
  "--data-raw",
  "--data-binary",
  "--data-urlencode",
  "--data-ascii",
  "--json",
  "-F",
  "--form",
  "--form-string",
  "-T",
  "--upload-file",
  "--post-data",
  "--post-file",
  "--body-data",
  "--body-file",
];

/// curl's short options run together, a value attached to the last (`-sXPOST`, `-dname=x`, `-Tf`):
/// the first value-taking letter of a cluster ends it, so `-fsSL` takes none.
const CURL_VALUE_LETTERS = /[HdXoOuAeFwmbcT]/;
function shortValue(arg: string): { letter: string; value: string } | undefined {
  if (!/^-[A-Za-z]/.test(arg)) return undefined;
  const at = arg.slice(1).search(CURL_VALUE_LETTERS);
  return at < 0 ? undefined : { letter: arg[at + 1]!, value: arg.slice(at + 2) };
}
const attachedSend = (arg: string) => {
  const found = shortValue(arg);
  return Boolean(found && "dFT".includes(found.letter) && (found.value || arg.length > 2));
};
function attachedMethod(args: string[]): string | undefined {
  for (let i = 0; i < args.length; i += 1) {
    const found = shortValue(args[i]!);
    if (found?.letter === "X") return found.value || args[i + 1];
  }
  return undefined;
}

function fetched(args: string[]): Act | undefined {
  const { positional, has, value } = parse(args, [
    "-H",
    "--header",
    "-d",
    "--data",
    "--data-raw",
    "--data-binary",
    "-X",
    "--request",
    "-o",
    "--output",
    "-O",
    "-u",
    "--user",
    "-A",
    "--user-agent",
    "-e",
    "--referer",
    "-F",
    "--form",
    "-w",
    "--write-out",
    "-m",
    "--max-time",
    "--connect-timeout",
    "-b",
    "--cookie",
    "-c",
    "--cookie-jar",
    "--retry",
    "-T",
    "--upload-file",
    ...SENDS.filter((flag) => flag.startsWith("--")),
    "--method",
  ]);
  const method = value("-X", "--request", "--method") ?? attachedMethod(args);
  // A request that sends something did more than fetch: its line says what.
  if ((method && method.toUpperCase() !== "GET") || has(...SENDS) || args.some(attachedSend)) return undefined;
  const url = positional.find((arg) => /^(?:https?:\/\/|localhost[:/]|[\w-]+(?:\.[\w-]+)+[:/])/.test(arg));
  if (!url) return undefined;
  const page = url
    .replace(/^https?:\/\//, "")
    .replace(/[?#].*$/, "")
    .replace(/\/$/, "");
  return { key: "command.fetched", values: { url: oneLine(page) } };
}

/** A table's own entry for `name`, never one it inherits: `__proto__` or `constructor` as a
 *  command word must fall back to the plain command line, not call into Object.prototype. */
function own<T>(table: Record<string, T>, name: string | undefined): T | undefined {
  return name !== undefined && Object.hasOwn(table, name) ? table[name] : undefined;
}

const PROGRAMS: Record<string, Rule> = {
  git: (args) => {
    // `git -C dir`, `-c key=value`, `--no-pager` come before the subcommand.
    let i = 0;
    while (i < args.length && args[i]!.startsWith("-"))
      i += ["-C", "-c", "--git-dir", "--work-tree"].includes(args[i]!) ? 2 : 1;
    const rule = own(GIT, args[i]);
    return rule?.(args.slice(i + 1));
  },
  gh: (args) => {
    const [group, sub, ...rest] = args;
    if (group === "api") {
      const path = parse(args.slice(1), [
        ...GH_VALUES,
        "-X",
        "--method",
        "-f",
        "-F",
        "--field",
        "--raw-field",
        "-H",
        "--header",
        "--input",
        "--hostname",
      ]).positional[0];
      return path ? { key: "command.gh.api", values: { path: oneLine(path) } } : undefined;
    }
    const subs = own(GH, group);
    return subs && own(subs, sub)?.(rest);
  },
  // `rg --files [path]` lists the files it would search; it searches nothing.
  rg: (args) => {
    if (!args.includes("--files")) return searched(args, RG_VALUES);
    return listed(parse(args, RG_VALUES).positional[0]);
  },
  grep: (args) => searched(args, GREP_VALUES),
  egrep: (args) => searched(args, GREP_VALUES),
  fgrep: (args) => searched(args, GREP_VALUES),
  ag: (args) => searched(args, ["-G", "--file-search-regex", "-A", "-B", "-C", "-m", "--ignore"]),
  ls: (args) => listed(parse(args, ["-I", "--ignore", "-w", "--width"]).positional[0]),
  eza: (args) => listed(parse(args).positional[0]),
  tree: (args) => listed(parse(args, ["-L", "-I", "-P"]).positional[0]),
  // A find that deletes, runs a command or writes a file did more than list.
  find: (args) =>
    args.some((arg) => /^-(?:delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)$/.test(arg))
      ? undefined
      : listed(findRoot(args)),
  fd: (args) =>
    args.some((arg) => /^(?:-[xX]|--exec|--exec-batch)(?:=|$)/.test(arg))
      ? undefined
      : listed(
          parse(args, [
            "-e",
            "--extension",
            "-t",
            "--type",
            "-d",
            "--max-depth",
            "-E",
            "--exclude",
            "-x",
            "--exec",
            "-X",
            "--exec-batch",
            "-c",
            "--color",
          ]).positional[1],
        ),
  cat: (args) => readFiles(args),
  bat: (args) =>
    readFiles(args, ["-r", "--line-range", "-l", "--language", "--style", "--theme", "-H", "--highlight-line"]),
  head: (args) => readFiles(args, ["-n", "-c", "--lines", "--bytes"]),
  tail: (args) =>
    args.some((arg) => /^-[A-Za-z]*[fF]/.test(arg) || arg === "--follow")
      ? undefined
      : readFiles(args, ["-n", "-c", "--lines", "--bytes"]),
  sed: (args) => {
    // Only `sed -n 'x,yp' file` reads; any other sed rewrites what it reads.
    const { positional, has } = parse(args, ["-e", "-f"]);
    if (!has("-n") || has("-i", "--in-place") || args.some((arg) => arg.startsWith("-i"))) return undefined;
    return has("-e") ? read(positional) : read(positional.slice(1));
  },
  curl: fetched,
  wget: fetched,
  cargo: (args) => {
    const sub = args.find((arg) => !arg.startsWith("+"));
    if (sub === "build" || sub === "b") return { key: "command.built", values: { tool: "cargo" } };
    if (sub === "test" || sub === "t" || sub === "nextest") return { key: "command.tested", values: { tool: "cargo" } };
    if (sub === "install" || sub === "add" || sub === "fetch")
      return { key: "command.installed", values: { tool: "cargo" } };
    return undefined;
  },
  npm: packageManager("npm"),
  pnpm: packageManager("pnpm"),
  yarn: packageManager("yarn"),
  bun: packageManager("bun"),
  pytest: () => ({ key: "command.tested", values: { tool: "pytest" } }),
  vitest: () => ({ key: "command.tested", values: { tool: "vitest" } }),
  jest: () => ({ key: "command.tested", values: { tool: "jest" } }),
  python: interpreter,
  python3: interpreter,
  node: interpreter,
  deno: (args) => (args[0] === "run" ? interpreter(args.slice(1)) : undefined),
  ruby: interpreter,
  bash: interpreter,
  sh: interpreter,
  zsh: interpreter,
  tsx: interpreter,
  mkdir: (args) => {
    const paths = parse(args, ["-m", "--mode"]).positional;
    return paths.length ? { key: "command.madeDir", values: { path: paths.join(", ") } } : undefined;
  },
  rm: (args) => {
    const paths = parse(args).positional;
    return paths.length ? { key: "command.removed", values: { path: paths.join(", ") } } : undefined;
  },
  mv: (args) => fromTo("command.moved", args),
  cp: (args) => fromTo("command.copied", args),
  // Our own tools, where the verb is plain.
  "agent-memory": (args) => {
    if (args[0] !== "search") return undefined;
    const query = parse(args.slice(1), ["--limit"]).positional.join(" ");
    return query
      ? { key: "command.searchedMemory", values: { query: subject(query) }, bare: "command.bare.memory" }
      : undefined;
  },
  "cmux-ci": (args) => {
    if (args[0] === "compile-check") return { key: "command.ci.compileCheck" };
    const at = args.indexOf("--");
    if (args[0] === "test" && at > 0 && at < args.length - 1)
      return { key: "command.ci.test", values: { command: oneLine(args.slice(at + 1).join(" ")) } };
    return undefined;
  },
  "lane-gh": (args): Act | undefined => {
    const [sub, , third, ...rest] = args;
    if (sub === "push" && third) return { key: "command.git.pushBranch", values: { branch: third } };
    if (sub === "search" && (third || rest.length))
      return { key: "command.searchedGithub", values: { query: subject([third, ...rest].filter(Boolean).join(" ")) } };
    return undefined;
  },
  "glaeda-gh": (args) => {
    const [sub, kind, what] = args;
    return sub === "wait" && (kind === "run" || kind === "pr") && what
      ? { key: "command.waited", values: { target: oneLine(what) } }
      : undefined;
  },
  wt: (args) => {
    const { positional } = parse(args.slice(1), [
      "--from",
      "--at",
      "--name",
      "--include",
      "--topic",
      "--files",
      "--prior-art-ack",
    ]);
    return args[0] === "new" && positional[1]
      ? { key: "command.wt.new", values: { branch: positional[1] } }
      : undefined;
  },
};

function fromTo(key: StringKey, args: string[]): Act | undefined {
  const paths = parse(args, ["-t", "--target-directory", "-S", "--suffix"]).positional;
  return paths.length === 2 ? { key, values: { from: baseName(paths[0]!), to: baseName(paths[1]!) } } : undefined;
}

/// Wrappers that run the program after them: `sudo`, `timeout 20`, `env A=1`, `nice -n 5`, `npx`.
function unwrap(words: string[]): string[] {
  let rest = words;
  for (;;) {
    const head = rest[0];
    if (head === undefined) return rest;
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(head)) {
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

/// Labels that say a command only looked: a redirect into a file makes them untrue.
const READS = new Set<StringKey>([
  "command.read",
  "tools.read.other",
  "command.searched",
  "command.searchedMemory",
  "command.searchedGithub",
  "command.listed",
  "command.listedFiles",
]);

/// Whether an output redirect in the step writes a file: `> out.txt`, `>>log`, `&> all.log`, but
/// not `2>/dev/null` or `2>&1`.
function writesFile(step: string): boolean {
  const words = shellWords(step);
  return words.some((word, i) => {
    if (word === "|") return false;
    const kind = redirect(word);
    if (!kind) return false;
    const next = words[i + 1];
    const file = kind === "self" ? REDIRECT.exec(word.raw)![1]! : next && next !== "|" ? next.text : "";
    return !/^(?:&?\d+|&?-|\/dev\/(?:null|stdout|stderr))$/.test(file);
  });
}

/// What a command did, from the table; undefined for anything it does not list.
export function commandAction(command: string): CommandAction | undefined {
  const { step, more } = mainStep(command);
  const [first, ...rest] = stages(step);
  // A pipeline is its first stage only when the rest only trim what it printed: `curl … | bash`
  // ran what it fetched and `cat a | tee b` wrote b, so those read as their line.
  if (!first || !rest.every(passesThrough)) return undefined;
  const words = unwrap(first.map((word) => word.text));
  const [program, ...args] = words;
  if (!program) return undefined;
  const rule = own(PROGRAMS, baseName(program));
  const act = rule?.(args);
  // `cat a > b` copied a and `rg x > hits.txt` wrote hits.txt: a read never hides a file it wrote.
  if (act && READS.has(act.key) && writesFile(step)) return undefined;
  return act && { ...act, ...(more ? { more } : {}) };
}

/// An action in the reader's language: "Searched memory for “x”", "Staged all changes …".
export function actionText(t: Translate, action: CommandAction): string {
  const text = t(action.key, action.values ?? {});
  return action.more ? `${text} …` : text;
}

// ---------------------------------------------------------------------------------------------
// Rows and groups.

export function commandLook(): CommandLabelLook {
  return experimentArm(commandLabelLook);
}

// A shell that went on in the background keeps its launch's "completed" while it runs there.
const running = (tool: Tool) =>
  tool.status === "pending" || tool.status === "in_progress" || tool.background?.state === "running";

// A call that failed, was denied or a hook blocked: its status says so, its command exited nonzero, or
// the shell it left in the background failed there (toolGroups.ts isFailed, countsFailed; not
// imported, since toolGroups imports this file). The table's verbs say what a command did ("Merged
// PR #101", "Pushed main"), so such a call never gets one: its row reads as its line, "Ran gh pr
// merge 101", and a group with one reads "Ran N commands".
const failed = (tool: Tool) =>
  tool.status === "failed" ||
  (tool.exitCode !== undefined && tool.exitCode !== 0) ||
  tool.background?.state === "failed";

/// A command row's words when they are not its command line: the table's action, else the call's
/// description, as the look orders them. Undefined when the row reads "Ran <line>". A running call
/// reads as the line that is running ("Running <line>", and the live line its command alone, as
/// #36940 set): it has done nothing yet, and what runs is what the person may want to stop.
export function commandSaid(t: Translate, tool: Tool, look: CommandLabelLook = commandLook()): string | undefined {
  const command = tool.command?.trim();
  if (!command || look === "command" || look === "cleaned") return undefined;
  const description = tool.description?.trim() || undefined;
  if (running(tool)) return undefined;
  const action = failed(tool) ? undefined : commandAction(command);
  if (look === "description") return description ?? (action && actionText(t, action));
  // A compound command's first step is all the table names; a description says what the whole did.
  if (action && !(action.more && description)) return actionText(t, action);
  return description;
}

/// The line a command row draws when nothing names it, "Ran <line>": as typed for the `command`
/// look, else without the plumbing after it.
export function commandLine(command: string, look: CommandLabelLook = commandLook()): string {
  return look === "command" ? shortCommand(command, ROW_WIDTH) : cleanCommand(command);
}

/// A finished group of commands that all did one kind of thing: "Searched memory twice", "Read 3
/// files", "Checked git status twice". Undefined for a mixed group, which keeps "Ran N commands": a
/// combined sentence ("Searched memory and read 2 files") would need a phrase per verb in every
/// language, and the rows under it already say each.
export function commandGroupSaid(
  t: Translate,
  tools: readonly Tool[],
  look: CommandLabelLook = commandLook(),
): string | undefined {
  if (look === "command" || look === "cleaned" || tools.length < 2 || tools.some(running) || tools.some(failed))
    return undefined;
  const actions: CommandAction[] = [];
  for (const tool of tools) {
    const action = tool.command ? commandAction(tool.command) : undefined;
    if (!action || action.more) return undefined;
    actions.push(action);
  }
  if (actions.every((action) => action.files?.length)) {
    const n = new Set(actions.flatMap((action) => action.files!)).size;
    return n === 1 ? t("tools.read.one") : t("tools.read.other", { n });
  }
  const labels = new Set(actions.map((action) => actionText(t, action)));
  const bare = new Set(actions.map((action) => action.bare));
  const phrase =
    labels.size === 1 ? [...labels][0]! : bare.size === 1 && actions[0]!.bare ? t(actions[0]!.bare) : undefined;
  if (!phrase) return undefined;
  return actions.length === 2
    ? t("commandGroup.twice", { action: phrase })
    : t("commandGroup.times", { action: phrase, n: actions.length });
}
