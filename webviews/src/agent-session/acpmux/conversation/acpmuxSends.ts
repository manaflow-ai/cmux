// A shell call that does nothing but send another agent a message with `acpmux send` (or `cmux acp
// send`), read from its command line: who it went to and what it said, so the pane names it
// "Sending message to <target>" or "Sent message to <target>" (the live line, Background tasks,
// the transcript's row) instead of its raw command line.
//
// The line is read as a shell reads it (`shellCommands`): quotes, `$'…'`, backslashes,
// here-documents and here-strings, `$(…)` and backticks kept whole, comments, and the operators
// between commands. A wrapper that runs the command it is given is looked through: `reach HOST '…'`
// (the target then lives on HOST), `bash -c '…'`, `timeout N`, `env X=Y`, `perl -e 'alarm N; exec
// @ARGV'`, `nohup`, `nice`, `command`, `exec`. Only a command in command position counts: `echo
// "acpmux send x y"` prints words. A line that also does other work (`git push && acpmux send …`)
// stays a command row, so that work stays in sight; `cd`, `export`, an echo and filters on the
// send's output that read no file (`| tail -1`) do none. A redirect that writes a file is work, and
// so is a command substitution (`$(…)`, backticks) unless it only reads (`"$(cat note.md)"`).
//
// Options are read per `acpmux send --help`; `--status ID` (a delivery's state) and `--help` send
// nothing. The text is unknown when the prompt comes from stdin that is not in the line (`-`, or no
// prompt) or holds an expansion (`"$(cat note.md)"`): the row then names only the target. No list
// of session names is involved: the target is the word the command gives (`name`, `host/name`,
// `host:name`, `reports:person`).
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type AcpmuxSend = {
  /// The session the message went to, as the command names it; `host/name` when it ran through
  /// `reach HOST` and names no host of its own.
  target: string;
  /// The message, when the command line holds it.
  text?: string;
  /// `--no-wait`: it printed how the daemon took it (`queued`, `steered`) instead of the reply.
  noWait: boolean;
};

/// A send's state as its row reads it.
export type SendState = "sending" | "sent" | "failed";

export type AcpmuxSendCall = AcpmuxSend & { state: SendState };

/// The send a shell call makes, with its state, or nil for every other call.
export function acpmuxSendCall(tool: Tool): AcpmuxSendCall | undefined {
  if (tool.kind !== "execute" || !tool.command) return undefined;
  const send = acpmuxSend(tool.command);
  if (!send) return undefined;
  const running = tool.status === "pending" || tool.status === "in_progress";
  // Failed by its status or a nonzero exit (toolGroups.ts `isFailed`).
  const failed = tool.status === "failed" || (tool.exitCode !== undefined && tool.exitCode !== 0);
  return { ...send, state: running ? "sending" : failed ? "failed" : "sent" };
}

/// One shell word: its text after quote removal, and whether it is that text whatever the shell's
/// state (no `$` expansion, command substitution or backtick in it).
export type ShellWord = { text: string; literal: boolean };

/// A simple command: its words, its stdin when the line gives it (a here-document, a here-string,
/// or `file` for `< path`), the operator after it (`;` for a line break, "" at the end), whether a
/// redirect writes a file (`> out`, not `2>&1` or `>/dev/null`), and the scripts its command
/// substitutions run (`$(…)`, backticks, in its words or an unquoted here-document).
export type ShellCommand = {
  words: ShellWord[];
  stdin?: ShellWord | "file";
  op: "" | ";" | "&&" | "||" | "|" | "&";
  writes?: true;
  runs?: string[];
};

type Pending = Partial<Pick<ShellCommand, "stdin" | "runs">>;

const REDIRECT = /^(?:\d*(?:<<<|<<-|<<|>>|>&|<&|>\||<>|>|<)|&>>|&>)/;
const META = /[\s;&|()<>]/;

/// A command line's simple commands, in order, as a POSIX shell (bash, zsh) splits and quotes them.
/// Lenient: an unclosed quote or substitution runs to the end of the line.
export function shellCommands(line: string): ShellCommand[] {
  const commands: ShellCommand[] = [];
  let words: ShellWord[] = [];
  let stdin: ShellCommand["stdin"];
  let writes = false;
  let runs: string[] = [];
  /// Here-documents opened on the current line, read once it ends.
  let pending: { delimiter: string; strip: boolean; quoted: boolean; command: Pending }[] = [];
  // The command being read, so a here-document read after its line lands on it.
  let current: Pending = {};
  let index = 0;
  const end = (op: ShellCommand["op"]) => {
    if (words.length || stdin || writes || runs.length || pending.some((doc) => doc.command === current)) {
      const command: ShellCommand = {
        words,
        op,
        ...(stdin && { stdin }),
        ...(writes && { writes: true as const }),
        ...(runs.length && { runs }),
      };
      commands.push(command);
      // The here-document's body is read after the line; it fills this command's stdin then.
      for (const doc of pending) if (doc.command === current) doc.command = command;
    }
    words = [];
    stdin = undefined;
    writes = false;
    runs = [];
    current = {};
  };
  const readBodies = () => {
    for (const doc of pending) {
      const lines: string[] = [];
      while (index < line.length) {
        const stop = line.indexOf("\n", index);
        const raw = line.slice(index, stop < 0 ? line.length : stop);
        index = stop < 0 ? line.length : stop + 1;
        const text = doc.strip ? raw.replace(/^\t+/, "") : raw;
        if (text === doc.delimiter) break;
        lines.push(text);
      }
      const body = lines.length ? `${lines.join("\n")}\n` : "";
      doc.command.stdin = { text: body, literal: doc.quoted || !/[$`]/.test(body) };
      if (!doc.quoted) {
        const found = substitutions(body);
        if (found.length) doc.command.runs = [...(doc.command.runs ?? []), ...found];
      }
    }
    pending = [];
  };
  while (index < line.length) {
    const char = line[index]!;
    if (char === "\\" && line[index + 1] === "\n") {
      index += 2;
      continue;
    }
    if (char === " " || char === "\t" || char === "\r") {
      index += 1;
      continue;
    }
    if (char === "#" && (index === 0 || /[\s;&|()]/.test(line[index - 1]!))) {
      while (index < line.length && line[index] !== "\n") index += 1;
      continue;
    }
    if (char === "\n") {
      index += 1;
      end(";");
      readBodies();
      continue;
    }
    const redirect = REDIRECT.exec(line.slice(index, index + 8));
    if (redirect) {
      const op = redirect[0].replace(/^\d+/, "");
      index += redirect[0].length;
      while (line[index] === " " || line[index] === "\t") index += 1;
      const start = index;
      const [target, next] = readWord(line, index, runs);
      index = next;
      if (op === ">&" ? !/^(?:\d+|-)$/.test(target.text) : WRITES.has(op) && target.text !== "/dev/null") writes = true;
      if (op === "<<" || op === "<<-") {
        const quoted = /['"\\]/.test(line.slice(start, next));
        pending.push({ delimiter: target.text, strip: op === "<<-", quoted, command: current });
      } else if (op === "<<<") stdin = { text: `${target.text}\n`, literal: target.literal };
      else if (op === "<" || op === "<>") stdin = "file";
      continue;
    }
    if (char === ";" || char === "&" || char === "|" || char === "(" || char === ")") {
      const two = line.slice(index, index + 2);
      if (two === "&&" || two === "||" || two === ";;" || two === "|&") {
        index += 2;
        end(two === "&&" ? "&&" : two === "||" ? "||" : two === "|&" ? "|" : ";");
      } else {
        index += 1;
        end(char === "|" ? "|" : char === "&" ? "&" : ";");
      }
      continue;
    }
    const [word, next] = readWord(line, index, runs);
    const raw = line.slice(index, next);
    index = next;
    // `{ …; }` groups commands; the braces are not words of them.
    if (raw === "{" || raw === "}") {
      end(";");
      continue;
    }
    words.push(word);
  }
  end("");
  readBodies();
  return commands;
}

/// Redirects that write the file they name.
const WRITES = new Set([">", ">>", ">|", "<>", "&>", "&>>"]);

/// The word at `from`, and where it ends; the scripts of its command substitutions go in `runs`.
function readWord(line: string, from: number, runs: string[] = []): [ShellWord, number] {
  let text = "";
  let literal = true;
  let index = from;
  while (index < line.length) {
    const char = line[index]!;
    if (META.test(char)) break;
    if (char === "'") {
      const close = line.indexOf("'", index + 1);
      const stop = close < 0 ? line.length : close;
      text += line.slice(index + 1, stop);
      index = stop + 1;
    } else if (char === "$" && line[index + 1] === "'") {
      index += 2;
      while (index < line.length && line[index] !== "'") {
        if (line[index] === "\\" && index + 1 < line.length) {
          const escape = line[index + 1]!;
          text += ANSI_C[escape] ?? escape;
          index += 2;
        } else text += line[index++];
      }
      index += 1;
    } else if (char === '"') {
      index += 1;
      while (index < line.length && line[index] !== '"') {
        const inner = line[index]!;
        if (inner === "\\" && /[$`"\\\n]/.test(line[index + 1] ?? "")) {
          if (line[index + 1] !== "\n") text += line[index + 1];
          index += 2;
        } else if (inner === "$" || inner === "`") {
          const stop = expansionEnd(line, index, runs);
          if (stop > index + 1) literal = false;
          text += line.slice(index, stop);
          index = stop;
        } else text += line[index++];
      }
      index += 1;
    } else if (char === "\\") {
      if (line[index + 1] !== "\n") text += line[index + 1] ?? "";
      index += 2;
    } else if (char === "$" || char === "`") {
      const stop = expansionEnd(line, index, runs);
      if (stop > index + 1) literal = false;
      text += line.slice(index, stop);
      index = stop;
    } else text += line[index++];
  }
  return [{ text, literal }, index];
}

const ANSI_C: Record<string, string> = { n: "\n", t: "\t", r: "\r", "'": "'", '"': '"', "\\": "\\", e: "\u001b" };

/// Where an expansion at `from` (`$name`, `${…}`, `$(…)`, `` `…` ``) ends; a lone `$` is one
/// character. A command substitution's script goes in `runs`.
function expansionEnd(line: string, from: number, runs: string[] = []): number {
  if (line[from] === "`") {
    let index = from + 1;
    while (index < line.length && line[index] !== "`") index += line[index] === "\\" ? 2 : 1;
    runs.push(line.slice(from + 1, index));
    return Math.min(line.length, index + 1);
  }
  const next = line[from + 1];
  if (next === "(") {
    const stop = balancedEnd(line, from + 1);
    runs.push(line.slice(from + 2, line[stop - 1] === ")" ? stop - 1 : stop));
    return stop;
  }
  if (next === "{") return balancedEnd(line, from + 1);
  const name = /^(?:[A-Za-z_]\w*|[0-9#?$!@*-])/.exec(line.slice(from + 1));
  return name ? from + 1 + name[0].length : from + 1;
}

/// The scripts of the command substitutions in an unquoted here-document's body.
function substitutions(body: string): string[] {
  const runs: string[] = [];
  for (let index = 0; index < body.length;) {
    const char = body[index]!;
    if (char === "\\") index += 2;
    else if (char === "`" || (char === "$" && body[index + 1] === "(")) index = expansionEnd(body, index, runs);
    else index += 1;
  }
  return runs;
}

/// The end of the bracket at `open` and what it holds, quotes inside kept whole.
function balancedEnd(line: string, open: number): number {
  const close = line[open] === "(" ? ")" : "}";
  let depth = 0;
  for (let index = open; index < line.length; index++) {
    const char = line[index]!;
    if (char === "\\") index += 1;
    else if (char === "'") {
      const stop = line.indexOf("'", index + 1);
      index = stop < 0 ? line.length : stop;
    } else if (char === '"') {
      index += 1;
      while (index < line.length && line[index] !== '"') index += line[index] === "\\" ? 2 : 1;
    } else if (char === line[open]) depth += 1;
    else if (char === close && --depth === 0) return index + 1;
  }
  return line.length;
}

/// Words that only set the stage for the command after them.
const RESERVED = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "time"]);
/// Programs that run the command their arguments give, with the options that take a value.
const RUNNERS: Record<string, Set<string>> = {
  nohup: new Set(),
  command: new Set(),
  exec: new Set(["-a"]),
  nice: new Set(["-n"]),
  env: new Set(["-u", "-C", "-S", "--unset", "--chdir"]),
};
/// Steps that only set up the shell, or report: they do no work a send row would hide.
const SETUP = new Set(["cd", "pushd", "popd", "export", "set", "unset", "true", ":", "wait", "exit", "echo", "printf"]);
/// Steps a send's output may pipe through (`| tail -1`), with how many operands each takes besides
/// its options: they only cut what it printed, and read no file and write none.
const FILTERS: Record<string, number> = { tail: 0, head: 0, cat: 0, wc: 0, cut: 0, grep: 1, jq: 1, tr: 2 };
/// What a command substitution may run and still only read (`"$(cat note.md)"`).
const READERS = new Set(["cat", "head", "tail", "date", "basename", "dirname", "pwd", "echo", "printf"]);
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh", "fish"]);
/// `reach`'s options that take a value (`reach --help`).
const REACH_VALUES = new Set(["--origin", "--registry", "--keep-tunnel", "--timeout"]);
/// `acpmux send`'s options that take a value, and its flags (`acpmux send --help`).
const SEND_VALUES = new Set(["--timeout", "--on-permission", "--stall", "--prompt-id", "--from", "--supersede"]);
const SEND_FLAGS = new Set(["--json", "--steer", "--no-steer", "--suppress-reads", "--no-wait", "-q", "--quiet"]);
/// `acpmux`'s own flags, which may come before `send` (`acpmux --help`).
const ACPMUX_FLAGS = new Set(["--json", "--suppress-reads"]);

const ASSIGNMENT = /^[A-Za-z_]\w*=/;
const program = (word: ShellWord | undefined) => (word?.literal ? (word.text.split("/").pop() ?? "") : "");

/// The words of the command a wrapper runs: assignments, `env`, `timeout`, `nohup` and the like
/// before it left out.
function unwrapped(words: readonly ShellWord[]): ShellWord[] {
  let rest = [...words];
  for (let guard = 0; guard < 16 && rest.length; guard++) {
    const head = rest[0]!;
    const name = program(head);
    if (head.literal && (ASSIGNMENT.test(head.text) || RESERVED.has(head.text))) rest = rest.slice(1);
    else if (name in RUNNERS) rest = afterOptions(rest.slice(1), RUNNERS[name]!, name === "env");
    else if (name === "timeout" || name === "gtimeout") {
      // `timeout [-s SIG] [-k DUR] [--foreground] DURATION COMMAND…`.
      rest = afterOptions(rest.slice(1), new Set(["-s", "-k", "--signal", "--kill-after"])).slice(1);
    } else if (name === "perl") {
      // `perl -e 'alarm N; exec @ARGV' COMMAND…`: a script that does nothing but run its arguments.
      const flag = rest[1]?.text;
      if ((flag !== "-e" && flag !== "-E") || !PERL_EXEC.test(rest[2]?.text ?? "")) return rest;
      rest = rest.slice(3);
    } else return rest;
  }
  return rest;
}

/// `alarm N; exec @ARGV` and nothing else.
const PERL_EXEC = /^\s*(?:alarm\s*\(?\s*\d+\s*\)?\s*;\s*)?exec\s*\(?\s*@ARGV\s*\)?\s*;?\s*$/;

/// The words after a runner's options (and, for `env`, its assignments).
function afterOptions(words: ShellWord[], values: ReadonlySet<string>, assignments = false): ShellWord[] {
  let index = 0;
  while (index < words.length) {
    const text = words[index]!.text;
    if (text === "--") return words.slice(index + 1);
    if (assignments && ASSIGNMENT.test(text)) index += 1;
    else if (text.startsWith("-") && text.length > 1) index += values.has(text) ? 2 : 1;
    else break;
  }
  return words.slice(index);
}

/// The send a command line makes, or nil when it makes none, makes more than one, or does other work.
export function acpmuxSend(line: string, host?: string, depth = 0): AcpmuxSend | undefined {
  if (depth > 3 || !/acp/.test(line)) return undefined;
  const commands = shellCommands(line);
  let found: AcpmuxSend | undefined;
  let at = -1;
  for (const [index, command] of commands.entries()) {
    const words = unwrapped(command.words);
    const name = program(words[0]);
    let send: AcpmuxSend | undefined;
    if (name === "reach") {
      const rest = afterOptions(words.slice(1), REACH_VALUES);
      const inner = rest.slice(1);
      if (rest[0]?.literal && inner.length && inner.every((word) => word.literal))
        send = acpmuxSend(inner.map((word) => word.text).join(" "), rest[0].text, depth + 1);
    } else if (SHELLS.has(name)) {
      const flag = words.findIndex((word, place) => place > 0 && /^-[a-z]*c[a-z]*$/.test(word.text));
      const script = flag > 0 ? words[flag + 1] : undefined;
      if (script?.literal) send = acpmuxSend(script.text, host, depth + 1);
    } else if (name === "acpmux" || name === "acpmux-debug-cli") {
      let sub = 1;
      while (ACPMUX_FLAGS.has(words[sub]?.text ?? "")) sub += 1;
      if (words[sub]?.text === "send") send = sendArgs(words.slice(sub + 1), stdinOf(commands, index), host);
    } else if (name === "cmux" && words[1]?.text === "acp" && words[2]?.text === "send")
      send = sendArgs(words.slice(3), stdinOf(commands, index), host);
    if (send) {
      if (found) return undefined;
      found = send;
      at = index;
    }
  }
  if (!found) return undefined;
  // No step writes a file or runs a substitution that does more than read, and every step but the
  // send only sets up, reports, feeds the send, or filters what it printed.
  let pipedFromSend = false;
  for (const [index, command] of commands.entries()) {
    pipedFromSend = index > at && commands[index - 1]!.op === "|" && (index === at + 1 || pipedFromSend);
    if (command.writes || !(command.runs ?? []).every((script) => onlyReads(script, depth))) return undefined;
    if (index === at) continue;
    const words = unwrapped(command.words);
    const name = program(words[0]);
    if (SETUP.has(name) || command.words.every((word) => word.literal && ASSIGNMENT.test(word.text))) continue;
    if (pipedFromSend && name in FILTERS && operands(words.slice(1)) <= FILTERS[name]!) continue;
    // `cat <<EOF | acpmux send x -`: cat only hands the send its text.
    if (name === "cat" && index === at - 1 && command.op === "|" && command.words.length === 1) continue;
    return undefined;
  }
  return found;
}

/// How many of a filter's words are operands (a pattern, a file), not options or their numbers;
/// an expansion counts as one.
const operands = (words: readonly ShellWord[]) =>
  words.filter((word) => !word.literal || !(word.text.startsWith("-") || /^\+?\d+[a-zA-Z]?$/.test(word.text))).length;

/// Whether a command substitution's script only reads: readers piped or listed, writing nothing.
function onlyReads(script: string, depth: number): boolean {
  if (depth > 3) return false;
  return shellCommands(script).every(
    (command) =>
      !command.writes &&
      READERS.has(program(command.words[0])) &&
      (command.runs ?? []).every((inner) => onlyReads(inner, depth + 1)),
  );
}

/// The text the command at `index` reads from stdin, when the line holds it: its here-document or
/// here-string, or an `echo`, `printf` or bare `cat <<EOF` piped into it.
function stdinOf(commands: readonly ShellCommand[], index: number): ShellWord | "file" | undefined {
  const own = commands[index]!.stdin;
  if (own) return own;
  const before = commands[index - 1];
  if (before?.op !== "|") return undefined;
  const words = unwrapped(before.words);
  const name = program(words[0]);
  if (name === "cat" && words.length === 1) return before.stdin;
  if (name === "echo") {
    const args = words.slice(1);
    while (args[0] && /^-[neE]+$/.test(args[0].text)) args.shift();
    return { text: args.map((word) => word.text).join(" "), literal: args.every((word) => word.literal) };
  }
  if (name === "printf" && words[1])
    return { text: words[1].text.replace(/\\n/g, "\n").replace(/\\t/g, "\t"), literal: words[1].literal };
  return undefined;
}

/// `acpmux send [OPTIONS] [SESSION] [PROMPT]...`, read as clap reads it: options anywhere until
/// `--`, the first other word the session, the rest the prompt; none or `-` reads stdin.
function sendArgs(args: readonly ShellWord[], stdin: ShellWord | "file" | undefined, host?: string) {
  const positional: ShellWord[] = [];
  let noWait = false;
  let options = true;
  for (let index = 0; index < args.length; index++) {
    const word = args[index]!;
    const text = word.text;
    if (options && text === "--") options = false;
    else if (options && text.startsWith("-") && text !== "-") {
      const name = text.split("=", 1)[0]!;
      // `--status ID` reads a delivery's state; help prints usage. Neither sends anything.
      if (name === "--status" || name === "--help" || /^-[a-zA-Z]*h/.test(name)) return undefined;
      // An option acpmux does not know fails the call: it sends nothing.
      if (!SEND_FLAGS.has(name) && !SEND_VALUES.has(name)) return undefined;
      if (name === "--no-wait") noWait = true;
      if (SEND_VALUES.has(name) && !text.includes("=")) index += 1;
    } else positional.push(word);
  }
  const session = positional[0];
  if (!session?.literal || !session.text.trim()) return undefined;
  const words = positional.slice(1);
  const fromStdin = words.length === 0 || (words.length === 1 && words[0]!.text === "-");
  const said = fromStdin ? (stdin === "file" ? undefined : stdin) : undefined;
  const text = fromStdin
    ? said?.literal
      ? said.text
      : undefined
    : words.every((word) => word.literal)
      ? words.map((word) => word.text).join(" ")
      : undefined;
  const name = session.text.trim();
  const target = host && !/[/:]/.test(name) ? `${host}/${name}` : name;
  return { target, ...(text?.trim() && { text }), noWait } satisfies AcpmuxSend;
}
