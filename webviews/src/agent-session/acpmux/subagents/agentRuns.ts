// A shell call that starts another agent (`codex exec …`, `claude -p …`, `acpmux run …`), read
// from its command so the transcript draws it as a subagent (subagentFold.ts, AgentRunCard.tsx)
// rather than as a long "Command" row. The command is read with a shell tokenizer (quotes,
// escapes, `;`/`&&`/`|`, `{ … }`, heredocs and `<` redirections), never by searching its text:
// a heredoc that mentions `codex exec`, a `grep "codex exec"` or a `codex exec --help` starts no
// agent. Wrappers that only run the next words (`timeout 600`, `nohup`, `env X=1`, `sr`, the
// `perl -e 'alarm N; exec @ARGV'` timeout) are looked through, and so are the command strings
// `reach HOST '…'`, `ssh HOST '…'` and `sh -c '…'` run, which name the machine it runs on.
//
// Each agent CLI's grammar is in ``CLIS``: what makes it start a non-interactive run (a
// subcommand or a flag), which options take a value, and where its model, effort, prompt and
// session name are. The family is the executable's own (`codex`, `claude`) or, for acpmux, the
// harness its `-m HARNESS[/MODEL]` names.

/// One agent a shell call starts.
export type AgentRun = {
  /// Its harness family (`codex`, `claude`), or the harness acpmux was told to run (`claude-sr2`);
  /// none for an acpmux run that names no harness (the daemon's default).
  harness?: string;
  model?: string;
  effort?: string;
  /// What it was asked, when the command carries it: an inline argument, or the heredoc or
  /// here-string its standard input reads.
  prompt?: string;
  /// The acpmux session's name (`-n`), which the session list finds it by.
  session?: string;
  /// The machine it runs on: `reach HOST`, `ssh HOST` or acpmux's `--host`.
  host?: string;
  /// The chat `acpmux run --parent` starts it under (acpmux #25019): a sub-session of that chat,
  /// whose state and reply its log records (subagentFold.ts `reduceChild`).
  parent?: string;
};

type Stdin = { text?: string; file?: string };
type Simple = { argv: string[]; stdin?: Stdin };

type Cli = {
  /// The family the executable runs; acpmux's comes from `-m`.
  family?: string;
  /// A subcommand that starts a run (`codex exec`), or a flag that does (`claude -p`).
  sub?: readonly string[];
  flag?: readonly string[];
  /// Options that take a value (`-m gpt-5`, `--model=gpt-5`).
  values: readonly string[];
  model?: readonly string[];
  effort?: readonly string[];
  /// Codex's `-c key=value`: `model` and `model_reasoning_effort` set the same.
  config?: readonly string[];
  /// acpmux's `-m HARNESS[/MODEL]`.
  harnessModel?: readonly string[];
  name?: readonly string[];
  host?: readonly string[];
  /// A run that reads its prompt from a file starts all the same, with no prompt to show.
  promptFile?: readonly string[];
  /// The prompt is the first positional word (`first`), or every one (`all`, acpmux's words).
  prompt: "first" | "all";
  /// A run with neither a prompt nor a prompt file reads its standard input.
  stdinPrompt: boolean;
};

/// Words written as one string, split at spaces.
const spaced = (list: string) => list.split(" ");

const CLIS: Record<string, Cli> = {
  codex: {
    family: "codex",
    sub: spaced("exec e"),
    values: spaced(
      "-c --config -m --model -p --profile -C --cd -s --sandbox -a --ask-for-approval -i --image -o --output-last-message --output-schema --color --add-dir --enable --disable --local-provider",
    ),
    model: spaced("-m --model"),
    config: spaced("-c --config"),
    prompt: "first",
    stdinPrompt: true,
  },
  claude: {
    family: "claude",
    flag: spaced("-p --print"),
    values: spaced(
      "--model --fallback-model --effort --output-format --input-format --allowedTools --allowed-tools --disallowedTools --disallowed-tools --permission-mode --append-system-prompt --system-prompt --mcp-config --settings --setting-sources --add-dir --session-id --resume -r --max-turns --agents --agent --debug-file",
    ),
    model: spaced("--model"),
    effort: spaced("--effort"),
    prompt: "first",
    stdinPrompt: true,
  },
  acpmux: {
    sub: spaced("run new exec"),
    values: spaced(
      "-p --preset --host -n --name --cwd --policy --mode -m --model -e --effort --timeout --on-permission --retries --stall --prompt-id --worktree --prompt-file --report-to --group --from --parent",
    ),
    harnessModel: spaced("-m --model"),
    effort: spaced("-e --effort"),
    name: spaced("-n --name"),
    host: spaced("--host"),
    promptFile: spaced("--prompt-file"),
    prompt: "all",
    stdinPrompt: false,
  },
};

/// The agent `command` starts, or undefined when it starts none. The first one wins when it
/// starts several.
export function agentRun(command: string): AgentRun | undefined {
  return runIn(command, undefined, undefined, 0);
}

/// The agent a command given as its words (Codex's `["bash", "-lc", "…"]`) starts, or undefined.
export function agentRunOf(argv: readonly string[]): AgentRun | undefined {
  return unwrap(withoutAssignments(argv), undefined, undefined, 0, 0);
}

/// `stdin` is what the command string's own standard input reads (`reach H '…' < prompt.txt`):
/// its commands that redirect none read it.
function runIn(
  command: string,
  stdin: Stdin | undefined,
  host: string | undefined,
  depth: number,
): AgentRun | undefined {
  // A command string inside a command string inside …: deep enough for `reach H 'sh -c "…"'`.
  if (depth > 4) return undefined;
  for (const simple of simpleCommands(command)) {
    const found = unwrap(withoutAssignments(simple.argv), simple.stdin ?? stdin, host, depth, 0);
    if (found) return found;
  }
  return undefined;
}

const base = (word: string) => word.slice(word.lastIndexOf("/") + 1);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/// The words after a simple command's leading `NAME=value` assignments (`X=1 codex …`).
function withoutAssignments(words: readonly string[]): string[] {
  let at = 0;
  while (at < words.length && ASSIGNMENT.test(words[at]!)) at += 1;
  return words.slice(at);
}

/// Wrappers looked through in one command (`nohup timeout 60 env codex …`) at most.
const MAX_WRAPPERS = 8;

/// Looks through the wrappers before the command that runs, then reads that command. `hops`
/// counts the wrappers looked through so far.
function unwrap(
  words: string[],
  stdin: Stdin | undefined,
  host: string | undefined,
  depth: number,
  hops: number,
): AgentRun | undefined {
  if (words.length === 0 || hops > MAX_WRAPPERS) return undefined;
  const name = base(words[0]!);
  const rest = words.slice(1);
  const again = (next: string[]) => unwrap(next, stdin, host, depth, hops + 1);
  switch (name) {
    case "command": {
      // `command -v codex` (or `-p -v`) only asks where it is.
      const options = rest.slice(0, rest.length - skipFlags(rest, []).length);
      if (options.some((word) => /^-[a-zA-Z]*[vV]/.test(word))) return undefined;
      return again(skipFlags(rest, []));
    }
    case "nohup":
    case "sr":
      return again(skipFlags(rest, []));
    case "time":
      return again(skipFlags(rest, ["-o", "-f", "--output", "--format"]));
    case "exec":
      return again(skipFlags(rest, ["-a"]));
    case "nice":
      return again(skipFlags(rest, ["-n"]));
    case "caffeinate":
      return again(skipFlags(rest, ["-t", "-w"]));
    case "env":
      return env(rest, again);
    case "timeout":
    case "gtimeout": {
      // Its options, then its duration, then the command.
      const after = skipFlags(rest, ["-s", "--signal", "-k", "--kill-after"]);
      return again(after.slice(1));
    }
    case "perl": {
      // `perl -e 'alarm 600; exec @ARGV' [--] codex exec …`: the script, among its leading options,
      // runs the words after them. A word before it is a program file, which runs instead.
      let at = 0;
      let script: string | undefined;
      while (at < rest.length && rest[at]!.startsWith("-")) {
        const word = rest[at]!;
        at += 1;
        if (word === "--") break;
        // `-e SCRIPT`, `-eSCRIPT`, and after switches that take no value (`-we SCRIPT`).
        const bundle = /^-[wnpaTtWXsUSc]*[eE](.*)$/s.exec(word);
        if (bundle) script = bundle[1] ? bundle[1] : rest[at++];
      }
      // Only a script that is the timeout itself: an alarm, then exec of the words after it.
      if (script === undefined || !PERL_TIMEOUT.test(script)) return undefined;
      return again(rest.slice(at));
    }
    case "sh":
    case "bash":
    case "zsh":
    case "dash": {
      // Its leading options, `-c` among them (`-lc`): the script is the first word after them. A
      // word before `-c` is a script file, which runs instead.
      let at = 0;
      let command = false;
      while (at < rest.length && /^[-+]./.test(rest[at]!) && rest[at] !== "--") {
        const word = rest[at]!;
        if (/^-[a-zA-Z]*c[a-zA-Z]*$/.test(word)) command = true;
        at += SHELL_VALUES.includes(word) ? 2 : 1;
      }
      if (rest[at] === "--") at += 1;
      const script = command ? rest[at] : undefined;
      return script === undefined ? undefined : runIn(script, stdin, host, depth + 1);
    }
    case "reach": {
      const [target, ...command] = rest;
      return target && command.length > 0 ? runIn(command.join(" "), stdin, target, depth + 1) : undefined;
    }
    case "ssh": {
      const after = skipFlags(rest, SSH_VALUES);
      const [target, ...command] = after;
      return target && command.length > 0
        ? runIn(command.join(" "), stdin, target.replace(/^.*@/, ""), depth + 1)
        : undefined;
    }
  }
  const cli = CLIS[name];
  return cli ? read(cli, rest, stdin, host) : undefined;
}

const PERL_TIMEOUT = /^\s*(?:alarm\s+\d+\s*;\s*)?exec\s*\(?\s*@ARGV\s*\)?\s*;?\s*$/;
const SHELL_VALUES = spaced("-o +o -O +O --rcfile --init-file");
const SSH_VALUES = spaced("-i -p -o -l -F -J -L -R -D -W -b -c -E -m -O -S -w");

/// `env [options] [NAME=value …] command …`: its options (`-u NAME`, `-C DIR`), and `-S STRING`
/// (`--split-string=STRING`, `-SSTRING`), whose string it splits into words that go before the
/// rest, then its assignments, then the command.
function env(args: readonly string[], run: (words: string[]) => AgentRun | undefined): AgentRun | undefined {
  let at = 0;
  let split: string[] = [];
  while (at < args.length && args[at]!.startsWith("-") && args[at] !== "-") {
    const word = args[at]!;
    at += 1;
    if (word === "--") break;
    if (word === "-u" || word === "-C" || word === "--unset" || word === "--chdir") {
      at += 1;
      continue;
    }
    let text: string | undefined | null = null;
    if (word === "-S" || word === "--split-string") text = args[at++];
    else if (word.startsWith("--split-string=")) text = word.slice("--split-string=".length);
    else if (word.startsWith("-S")) text = word.slice(2);
    if (text === null) continue;
    // A string that is not one simple command: env runs what it splits it to, which this does not read.
    const words = text === undefined ? undefined : splitWords(text);
    if (!words) return undefined;
    split = words;
  }
  return run(withoutAssignments([...split, ...args.slice(at)]));
}

/// A string's words as a shell reads one simple command's; undefined when it holds more than one.
function splitWords(text: string): string[] | undefined {
  const commands = simpleCommands(text);
  return commands.length === 1 ? commands[0]!.argv : commands.length === 0 ? [] : undefined;
}

/// The words after the leading options; `values` are the options that take the next word.
function skipFlags(words: readonly string[], values: readonly string[]): string[] {
  let at = 0;
  while (at < words.length && words[at]!.startsWith("-") && words[at] !== "-") {
    const word = words[at]!;
    at += 1;
    if (word === "--") break;
    if (values.includes(word)) at += 1;
  }
  return words.slice(at);
}

/// An option's value: `-m x`, `--model=x`, or `-mx` for a short one.
function optionValue(word: string, next: string | undefined, names: readonly string[]): string | undefined | null {
  for (const option of names) {
    if (word === option) return next ?? null;
    if (option.startsWith("--") && word.startsWith(`${option}=`)) return word.slice(option.length + 1);
    if (option.length === 2 && !word.startsWith("--") && word.startsWith(option) && word.length > 2)
      return word.slice(2).replace(/^=/, "");
  }
  return undefined;
}

function read(cli: Cli, args: readonly string[], stdin: Stdin | undefined, host: string | undefined) {
  // Before a `--`, which ends the options: `codex exec -- --help` asks Codex about its help.
  const end = args.indexOf("--");
  const options = end < 0 ? args : args.slice(0, end);
  if (options.some((word) => word === "--help" || word === "-h" || word === "--version" || word === "-V"))
    return undefined;
  const run: AgentRun = { ...(cli.family && { harness: cli.family }), ...(host && { host }) };
  // The subcommand that started the run, or the flag.
  let started: string | undefined;
  let file = false;
  const words: string[] = [];
  for (let at = 0; at < args.length; at += 1) {
    const word = args[at]!;
    const next = args[at + 1];
    if (word === "--") {
      words.push(...args.slice(at + 1));
      break;
    }
    if (word.startsWith("-") && word !== "-") {
      if (cli.flag?.includes(word)) started = word;
      const take = (names: readonly string[] | undefined) => (names ? optionValue(word, next, names) : undefined);
      const model = take(cli.model);
      if (typeof model === "string") run.model = model;
      const effort = take(cli.effort);
      if (typeof effort === "string") run.effort = effort;
      const name = take(cli.name);
      if (typeof name === "string") run.session = name;
      const remote = take(cli.host);
      if (typeof remote === "string") run.host = remote;
      if (take(cli.promptFile) !== undefined) file = true;
      const both = take(cli.harnessModel);
      if (typeof both === "string") {
        const slash = both.indexOf("/");
        run.harness = slash < 0 ? both : both.slice(0, slash);
        if (slash >= 0 && both.slice(slash + 1)) run.model = both.slice(slash + 1);
      }
      const config = take(cli.config);
      if (typeof config === "string") {
        const [key, ...value] = config.split("=");
        const setting = unquote(value.join("=").trim());
        if (key?.trim() === "model" && setting) run.model = setting;
        if (key?.trim() === "model_reasoning_effort" && setting) run.effort = setting;
      }
      if (cli.values.includes(word)) at += 1;
      continue;
    }
    if (cli.sub && started === undefined) {
      // The first positional word is the subcommand: another one (`acpmux send`) starts no agent.
      if (!cli.sub.includes(word)) return undefined;
      started = word;
      continue;
    }
    words.push(word);
  }
  if (started === undefined) return undefined;
  const prompt = cli.prompt === "first" ? words[0] : words.length > 0 ? words.join(" ") : undefined;
  if (prompt !== undefined && prompt !== "-") run.prompt = prompt;
  else if ((prompt === "-" || (!file && cli.stdinPrompt)) && stdin?.text !== undefined) run.prompt = stdin.text;
  // A session `acpmux new` makes with nothing to do runs no agent yet.
  if (started === "new" && prompt === undefined && !file) return undefined;
  // `acpmux run --parent` (acpmux #25019) makes a sub-session of that chat, with typed state and result.
  if (cli.values.includes("--parent"))
    for (let at = 0; at < options.length; at += 1) {
      const parent = optionValue(options[at]!, options[at + 1], ["--parent"]);
      if (typeof parent === "string") run.parent = parent;
    }
  return run;
}

const unquote = (value: string) => value.replace(/^(["'])(.*)\1$/s, "$2");

// ---- the tokenizer

/// A word keeps its source (`raw`): a quoted `}` closes nothing.
type Token = { word: string; raw: string } | { op: string; heredoc?: number };

/// The simple commands of a shell command line, each with what its standard input reads when a
/// redirection says (`< file`, a heredoc, a here-string). Pipelines, lists and groups split into
/// their commands; a `$(…)` or a backquote stays one word, unread.
export function simpleCommands(src: string): Simple[] {
  const { tokens, bodies } = lex(src);
  const out: Simple[] = [];
  let current: Simple = { argv: [] };
  const end = () => {
    if (current.argv.length > 0) out.push(current);
    current = { argv: [] };
  };
  for (let at = 0; at < tokens.length; at += 1) {
    const token = tokens[at]!;
    if ("word" in token) {
      // `args=(codex exec "x")` assigns an array: its words are data.
      const open = tokens[at + 1];
      if (/^[A-Za-z_]\w*\+?=$/.test(token.raw) && open && "op" in open && open.op === "(") {
        at = bodyEnd(tokens, at + 1);
        continue;
      }
      // `function f { … }` defines one too.
      if (current.argv.length === 0 && token.word === "function" && tokens[at + 1] && "word" in tokens[at + 1]!) {
        const paren = tokens[at + 2];
        const close = tokens[at + 3];
        const parens = paren && "op" in paren && paren.op === "(" && close && "op" in close && close.op === ")";
        at = bodyEnd(tokens, at + (parens ? 4 : 2));
        continue;
      }
      // Reserved words that open or close a compound command start no command of their own.
      if (current.argv.length === 0 && RESERVED.has(token.word)) continue;
      current.argv.push(token.word);
      continue;
    }
    const op = token.op;
    // `f() { … }` defines a function: its body runs only when it is called, which this does not follow.
    const next = tokens[at + 1];
    if (op === "(" && current.argv.length === 1 && next && "op" in next && next.op === ")") {
      current = { argv: [] };
      at = bodyEnd(tokens, at + 2);
      continue;
    }
    if (op === "<" || op === "<<<" || op.startsWith("<<")) {
      if (op === "<" || op === "<<<") {
        const target = tokens[at + 1];
        if (target && "word" in target) {
          current.stdin = op === "<" ? { file: target.word } : { text: target.word };
          at += 1;
        }
      } else {
        // The delimiter word, then the body read at the next line.
        if (tokens[at + 1] && "word" in tokens[at + 1]!) at += 1;
        current.stdin = { text: bodies[token.heredoc ?? -1] ?? "" };
      }
      continue;
    }
    if (REDIRECT.has(op)) {
      if (tokens[at + 1] && "word" in tokens[at + 1]!) at += 1;
      continue;
    }
    end();
  }
  end();
  return out;
}

/// The last token of the compound command that starts at or after `from` (past newlines): a
/// `{ … }` group or a `( … )` subshell, each to its matching close.
function bodyEnd(tokens: readonly Token[], from: number): number {
  let at = from;
  while (at < tokens.length && "op" in tokens[at]! && (tokens[at] as { op: string }).op === ";") at += 1;
  const first = tokens[at];
  if (!first) return tokens.length;
  const group = "word" in first && first.raw === "{";
  if (!group && !("op" in first && first.op === "(")) return at - 1;
  let depth = 0;
  for (; at < tokens.length; at += 1) {
    const token = tokens[at]!;
    const opens = group ? "word" in token && token.raw === "{" : "op" in token && token.op === "(";
    const closes = group ? "word" in token && token.raw === "}" : "op" in token && token.op === ")";
    if (opens) depth += 1;
    else if (closes && --depth === 0) return at;
  }
  return tokens.length;
}

const RESERVED = new Set(spaced("{ } ! if then else elif fi do done while until esac"));
const REDIRECT = new Set(spaced(">> >| >& <& <> &> &>> >"));
/// Longest first: `&&` before `&`.
const OPERATORS = spaced("&>> <<< <<- && || |& ;; << >> >| >& <& <> &> ; & | ( ) < >");

function lex(src: string): { tokens: Token[]; bodies: string[] } {
  const tokens: Token[] = [];
  const bodies: string[] = [];
  // Heredocs whose body starts at the next line: their index in `bodies`, delimiter and `<<-`.
  let pending: { index: number; delimiter: string; strip: boolean }[] = [];
  let at = 0;
  const n = src.length;
  while (at < n) {
    const c = src[at]!;
    if (c === "\n") {
      tokens.push({ op: ";" });
      at += 1;
      for (const doc of pending) {
        const lines: string[] = [];
        while (at < n) {
          const stop = src.indexOf("\n", at);
          const line = src.slice(at, stop < 0 ? n : stop);
          at = stop < 0 ? n : stop + 1;
          if ((doc.strip ? line.replace(/^\t+/, "") : line) === doc.delimiter) break;
          lines.push(doc.strip ? line.replace(/^\t+/, "") : line);
        }
        bodies[doc.index] = lines.join("\n");
      }
      pending = [];
      continue;
    }
    if (c === " " || c === "\t" || c === "\r") {
      at += 1;
      continue;
    }
    if (c === "\\" && src[at + 1] === "\n") {
      at += 2;
      continue;
    }
    if (c === "#") {
      while (at < n && src[at] !== "\n") at += 1;
      continue;
    }
    const op = OPERATORS.find((candidate) => src.startsWith(candidate, at));
    if (op) {
      at += op.length;
      if (op === "<<" || op === "<<-") {
        while (src[at] === " " || src[at] === "\t") at += 1;
        const [word, after] = readWord(src, at);
        at = after;
        const index = bodies.length;
        bodies.push("");
        pending.push({ index, delimiter: word, strip: op === "<<-" });
        tokens.push({ op, heredoc: index }, { word, raw: word });
      } else tokens.push({ op });
      continue;
    }
    const [word, after] = readWord(src, at);
    const raw = src.slice(at, after);
    at = after;
    // A file descriptor before a redirection (`2>&1`) is part of it.
    if (/^\d+$/.test(word) && (src[at] === ">" || src[at] === "<")) continue;
    tokens.push({ word, raw });
  }
  return { tokens, bodies };
}

/// One word from `start`: quotes removed, escapes read, a `$(…)` or a backquote kept as written.
function readWord(src: string, start: number): [string, number] {
  let at = start;
  let word = "";
  const n = src.length;
  while (at < n) {
    const c = src[at]!;
    if (c === " " || c === "\t" || c === "\n" || c === "\r" || ";&|()<>".includes(c)) break;
    if (c === "\\") {
      if (src[at + 1] === "\n") at += 2;
      else {
        word += src[at + 1] ?? "";
        at += 2;
      }
      continue;
    }
    if (c === "'") {
      const close = src.indexOf("'", at + 1);
      const stop = close < 0 ? n : close;
      word += src.slice(at + 1, stop);
      at = stop + 1;
      continue;
    }
    if (c === "$" && src[at + 1] === "'") {
      at += 2;
      while (at < n && src[at] !== "'") {
        if (src[at] === "\\" && at + 1 < n) {
          const e = src[at + 1]!;
          word += e === "n" ? "\n" : e === "t" ? "\t" : e;
          at += 2;
        } else word += src[at++];
      }
      at += 1;
      continue;
    }
    if (c === '"') {
      at += 1;
      while (at < n && src[at] !== '"') {
        if (src[at] === "\\" && '$`"\\\n'.includes(src[at + 1] ?? "")) {
          if (src[at + 1] !== "\n") word += src[at + 1];
          at += 2;
        } else if (src[at] === "$" && src[at + 1] === "(") {
          const close = closing(src, at + 1);
          word += src.slice(at, close);
          at = close;
        } else word += src[at++];
      }
      at += 1;
      continue;
    }
    if (c === "$" && (src[at + 1] === "(" || src[at + 1] === "{")) {
      const close = closing(src, at + 1);
      word += src.slice(at, close);
      at = close;
      continue;
    }
    if (c === "`") {
      const close = src.indexOf("`", at + 1);
      const stop = close < 0 ? n : close + 1;
      word += src.slice(at, stop);
      at = stop;
      continue;
    }
    word += c;
    at += 1;
  }
  return [word, at];
}

/// The index after the bracket that closes the one at `open`, past quotes inside.
function closing(src: string, open: number): number {
  const pair = src[open] === "(" ? ")" : "}";
  let depth = 0;
  let at = open;
  while (at < src.length) {
    const c = src[at]!;
    if (c === "\\") at += 2;
    else if (c === "'") {
      const close = src.indexOf("'", at + 1);
      at = close < 0 ? src.length : close + 1;
    } else if (c === '"') {
      at += 1;
      while (at < src.length && src[at] !== '"') at += src[at] === "\\" ? 2 : 1;
      at += 1;
    } else {
      if (c === src[open]) depth += 1;
      else if (c === pair) {
        depth -= 1;
        if (depth === 0) return at + 1;
      }
      at += 1;
    }
  }
  return src.length;
}

// ---- what the card shows

/// The first line of `prompt` that says something, without Markdown's heading or list marks.
export function promptTitle(prompt: string | undefined): string | undefined {
  const line = prompt
    ?.split("\n")
    .map((text) => text.replace(/^\s*(?:#+|[-*>]|\d+\.)\s+/, "").trim())
    .find(Boolean);
  if (!line) return undefined;
  return line.length > 120 ? `${line.slice(0, 119)}…` : line;
}

/// "gpt-6-astra xhigh": the model and effort a run names, for its card's model.
export function runModel(run: Pick<AgentRun, "model" | "effort">): string | undefined {
  return [run.model, run.effort].filter(Boolean).join(" ") || undefined;
}

/// The family of a harness or profile id (`claude-sr2` is Claude's).
export const harnessFamily = (harness: string) => harness.split(/[-_/]/)[0]!.toLowerCase();

/// A harness's family as a name: "Codex", "Claude".
export function harnessLabel(harness: string): string {
  const family = harnessFamily(harness);
  return family.charAt(0).toUpperCase() + family.slice(1);
}

/// What a run's agent finally said, from the call's output: the shell's own trailer (Claude
/// Code's "Shell cwd was reset") off, and with Codex's log in it (`codex exec … 2>&1`), only what
/// follows its last "tokens used" count, which is the final message. Undefined for no text.
export function runReply(output: string | undefined): string | undefined {
  if (!output) return undefined;
  let text = output.replace(/\n?Shell cwd was reset to [^\n]*\s*$/, "");
  const used = [...text.matchAll(/^tokens used\n[\d,]+\n/gm)].at(-1);
  if (used?.index !== undefined) text = text.slice(used.index + used[0].length);
  text = text.trim();
  if (!text) return undefined;
  // The end is what it said last; a long log keeps its last part.
  return text.length > 6000 ? `…${text.slice(-6000)}` : text;
}

/// Where Claude Code writes a background shell's output ("Output is being written to: /…/x.output."),
/// which a later read of that file shows.
export function backgroundOutputPath(output: string | undefined): string | undefined {
  return output ? /Output is being written to: (\S+?)\.?(?:\s|$)/.exec(output)?.[1] : undefined;
}
