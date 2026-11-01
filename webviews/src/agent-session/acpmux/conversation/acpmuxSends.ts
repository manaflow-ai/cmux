// A shell call that does nothing but send another agent a message with `acpmux send` (or `cmux acp
// send`), read from its command line: who it went to and what it said, so the pane names it
// "Sending message to <target>" or "Sent message to <target>" (the live line, Background tasks,
// the transcript's row) instead of its raw command line.
//
// The line is read as a shell reads it (`shellCommands`): quotes, `$'…'`, backslashes,
// here-documents and here-strings, `$(…)` and backticks kept whole, comments, and the operators
// between commands. A wrapper that runs the command it is given is looked through: `reach HOST '…'`
// and `ssh [OPTIONS] [USER@]HOST '…'` (the target then lives on HOST), `bash -c '…'`, `timeout N`,
// `env X=Y`, `perl -e 'alarm N; exec @ARGV'`, `nohup`, `nice`, `command`, `exec`. Only a command
// in command position counts: `echo "acpmux send x y"` prints words. A line that also does other
// work (`git push && acpmux send …`) stays a command row, so that work stays in sight; `cd`,
// `export`, an echo and filters on the send's output that read no file (`| tail -1`) do none. A
// redirect that writes a file is work, and so is a command substitution (`$(…)`, backticks) unless
// it only reads (`"$(cat note.md)"`).
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
  /// The file the message is read from when the line does not hold its words (`"$(cat note.md)"`,
  /// `"$(<note.md)"`, `- < note.md`), as the line names it: the row shows it in place of the text.
  file?: string;
  /// `--no-wait`: it printed how the daemon took it (`queued`, `steered`) instead of the reply.
  noWait: boolean;
  /// How many other commands the line runs that do work of their own (`git push && acpmux send …`,
  /// a redirect that writes a file): the row says "and N more", its command behind Raw.
  others?: number;
  /// The call's exit status is the send's: it is the line's last command, its output piped nowhere,
  /// and no `||` before it could skip it. Otherwise (`acpmux send … | tail -1`, `… && make`) the
  /// status is another command's.
  ownsExit?: true;
  /// Whether the send ran is not known from the line: a `&&` or `||` before it may have skipped it.
  unsure?: true;
};

/// What acpmux prints when a send fails: its text line (`acpmux: no_session: no session matches
/// "x"; …`), or with `--json` its error object (`{"error":{"code":"no_session",…}}`).
const SEND_ERROR = /^acpmux: [a-z_]+: |"error"\s*:\s*\{\s*"code"/m;

/// What acpmux prints when a `--no-wait` send went: how the daemon took it (`queued`, `steered`,
/// `delivered`), as a word on its own line or a JSON field.
const SEND_TAKEN = /^(?:queued|steered|delivered)\b|"(?:queued|steered|delivered)"\s*:\s*true/m;

/// Whether the send failed: by the call's status and exit code when they are the send's, else by
/// the error line acpmux printed; a failed background run counts either way.
export function sendFailed(send: AcpmuxSend, status: { failed: boolean; output?: string }): boolean {
  if (send.ownsExit) return status.failed;
  return SEND_ERROR.test(status.output ?? "");
}

/// A send's state as its row reads it; `ended` when the call ended but neither its status nor its
/// output says whether the message went (`git push && acpmux send …; git status`).
export type SendState = "sending" | "sent" | "failed" | "ended";

export type AcpmuxSendCall = AcpmuxSend & { state: SendState };

/// The send a shell call makes, with its state, or nil for every other call.
export function acpmuxSendCall(tool: Tool, priorFiles?: ReadonlyMap<string, string>): AcpmuxSendCall | undefined {
  if (tool.kind !== "execute" || !tool.command) return undefined;
  const send = acpmuxSend(tool.command, undefined, 0, priorFiles);
  if (!send) return undefined;
  // A send moved to the background runs, and ends, there (model.ts `background`).
  const background = tool.background?.state;
  // Failed by its status, a nonzero exit (toolGroups.ts `isFailed`), or its background run, even
  // while the call that started it still reads as running.
  const failed =
    sendFailed(send, {
      failed: tool.status === "failed" || (tool.exitCode !== undefined && tool.exitCode !== 0),
      output: tool.output,
    }) ||
    (send.ownsExit === true && (background === "failed" || background === "stopped"));
  const running = tool.status === "pending" || tool.status === "in_progress" || background === "running";
  // A send that may have been skipped went when its status is its own or acpmux said it took it.
  const went = send.ownsExit || !send.unsure || (send.noWait && SEND_TAKEN.test(tool.output ?? ""));
  const state = failed ? "failed" : running ? "sending" : went ? "sent" : "ended";
  return { ...send, state };
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
  stdinQuoted?: boolean;
  stdinUnsafe?: true;
  stdinRedirects?: number;
  /// The path used by a file stdin redirect. It is only resolved when a prior command in
  /// this same recorded shell call wrote a literal here-document to that path.
  stdinFile?: ShellWord;
  op: "" | ";" | "&&" | "||" | "|" | "&";
  writes?: true;
  /// Number of output/path redirects in this command (`2>` counts too).
  redirectWrites?: number;
  /// Redirects are ambiguous for recorded message provenance (append, fd duplication, non-stdout,
  /// dynamic path or a second output target).
  redirectUnsafe?: true;
  grouped?: true;
  /// A literal path written by this command. The parser never reads this path from disk.
  writeFile?: ShellWord;
  /// Its stdout goes somewhere other than the next command (`> out`, `>/dev/null`; not `2>&1`).
  stdout?: true;
  runs?: string[];
};

type Pending = Partial<Pick<ShellCommand, "stdin" | "runs">>;

const REDIRECT = /^(?:\d*(?:<<<|<<-|<<|>>|>&|<&|>\||<>|>|<)|&>>|&>)/;
/// What ends a word: the shell's blanks (a space, a tab, a line break; not U+00A0 or other Unicode
/// spaces, which a shell keeps in the word) and its operators.
const META = /[ \t\r\n;&|()<>]/;

/// A command line's simple commands, in order, as a POSIX shell (bash, zsh) splits and quotes them.
/// Lenient: an unclosed quote or substitution runs to the end of the line.
export function shellCommands(line: string): ShellCommand[] {
  const commands: ShellCommand[] = [];
  let words: ShellWord[] = [];
  let stdin: ShellCommand["stdin"];
  let stdinQuoted = false;
  let stdinUnsafe = false;
  let stdinRedirects = 0;
  let stdinFile: ShellCommand["stdinFile"];
  let writes = false;
  let redirectWrites = 0;
  let redirectUnsafe = false;
  let grouped = false;
  let writeFile: ShellCommand["writeFile"];
  let stdout = false;
  let runs: string[] = [];
  /// Here-documents opened on the current line, read once it ends; `stdin` false when a later
  /// redirect (`<<EOF < file`) took the command's stdin from it.
  let pending: { delimiter: string; strip: boolean; quoted: boolean; stdin: boolean; command: Pending }[] = [];
  /// The here-documents the command being read opened, so their bodies read after its line land on it.
  let docs: (typeof pending)[number][] = [];
  let index = 0;
  /// A `)` just closed a group: the operator after it (`) | tail`, `) && x`) is its last command's.
  let closed = false;
  const end = (op: ShellCommand["op"]) => {
    const empty = !(words.length || stdin || writes || runs.length || docs.length);
    if (empty && closed && op !== ";" && commands.length) commands[commands.length - 1]!.op = op;
    closed = false;
    if (!empty) {
      const command: ShellCommand = {
        words,
        op,
        ...(stdin && { stdin }),
        ...(stdinQuoted && { stdinQuoted: true as const }),
        ...(stdinUnsafe && { stdinUnsafe: true as const }),
        ...(stdinRedirects && { stdinRedirects }),
        ...(stdinFile && { stdinFile }),
        ...(writes && { writes: true as const }),
        ...(redirectWrites && { redirectWrites }),
        ...(redirectUnsafe && { redirectUnsafe: true as const }),
        ...(writeFile && { writeFile }),
        ...(stdout && { stdout: true as const }),
        ...(runs.length && { runs }),
      };
      commands.push(command);
      // The here-document's body is read after the line; it fills this command's stdin then.
      for (const doc of docs) doc.command = command;
    }
    words = [];
    stdin = undefined;
    stdinQuoted = false;
    stdinUnsafe = false;
    stdinRedirects = 0;
    stdinFile = undefined;
    writes = false;
    redirectWrites = 0;
    redirectUnsafe = false;
    writeFile = undefined;
    stdout = false;
    runs = [];
    docs = [];
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
      if (doc.stdin)
        doc.command.stdin = { text: body, literal: doc.quoted || (!/[$`\\]/.test(body) && !body.includes("\\\n")) };
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
      // Stdout leaves the pipe: `> f`, `&> f`, `>&f`, `1> f`; `2> f` keeps the
      // command's output on the terminal and must not become a message body source.
      const fd = /^\d+/.exec(redirect[0])?.[0];
      if (op.startsWith("<")) {
        stdinRedirects += 1;
      }
      if (WRITES.has(op) || op === ">&" || op === "<&") {
        redirectWrites += 1;
        if (
          op !== ">" ||
          (fd !== undefined && fd !== "1") ||
          !target.literal ||
          target.text === "/dev/null" ||
          redirectWrites > 1
        )
          redirectUnsafe = true;
      }
      // A later stdout redirect or fd duplication shadows an earlier candidate. Only one plain
      // truncating `>` to a literal path may remain publishable; append, combined, `>&` and
      // dynamic redirects all clear it, including `1>&2` and `> candidate >> other`.
      if ((fd === undefined || fd === "1") && (op.startsWith(">") || op.startsWith("&>")))
        writeFile = op === ">" && target.literal && target.text !== "/dev/null" ? target : undefined;
      if (redirectUnsafe) writeFile = undefined;
      if (op === ">&" ? !/^(?:\d+|-)$/.test(target.text) : WRITES.has(op) && target.text !== "/dev/null") {
        writes = true;
      }
      if ((op.startsWith(">") || op.startsWith("&>")) && (fd === undefined || fd === "1") && target.text !== "1")
        stdout = true;
      // The last redirect of stdin wins: one after a here-document takes its place. A here-string
      // is handled below and must not be mistaken for a file redirect (`<<<` starts with `<`).
      const takesStdin = (fd === undefined || fd === "0") && (op === "<" || op === "<>" || op === "<<" || op === "<<-");
      if (takesStdin) {
        if ((stdin !== undefined && stdin !== "file") || stdinQuoted || docs.some((doc) => doc.stdin))
          stdinUnsafe = true;
        for (const doc of docs) doc.stdin = false;
        stdinFile = op === "<" || op === "<>" ? target : undefined;
      }
      if (op === "<<" || op === "<<-") {
        if (fd !== undefined && fd !== "0") {
          redirectUnsafe = true;
          stdinUnsafe = true;
        }
        const quoted = /['"\\]/.test(line.slice(start, next));
        const validDelimiter = target.literal;
        if (!validDelimiter) {
          redirectUnsafe = true;
          stdinUnsafe = true;
        }
        const doc = {
          delimiter: target.text,
          strip: op === "<<-",
          quoted: validDelimiter && quoted,
          stdin: validDelimiter && (fd === undefined || fd === "0"),
          command: {},
        };
        pending.push(doc);
        docs.push(doc);
        stdin = undefined;
        stdinFile = undefined;
        // A non-zero descriptor's heredoc is not this command's stdin. Do not leave its quoted
        // metadata behind for stdinOf or a following pipe to mistake for fd 0.
        stdinQuoted = validDelimiter && (fd === undefined || fd === "0") ? quoted : false;
      } else if (op === "<<<") {
        if (fd !== undefined || stdinQuoted || stdinFile !== undefined || docs.some((doc) => doc.stdin))
          stdinUnsafe = true;
        for (const doc of docs) doc.stdin = false;
        if (fd === undefined || fd === "0") stdin = { text: `${target.text}\n`, literal: target.literal };
        else redirectUnsafe = true;
      } else if (op === "<" || op === "<>") {
        stdin = "file";
      }
      // An fd 0 output redirect replaces any earlier heredoc/file source. This is distinct from
      // ordinary stdout `> out`, which leaves a command's stdin intact (`cat <<EOF > out`).
      if (fd === "0" && (op.startsWith(">") || op.startsWith("&>"))) {
        for (const doc of docs) doc.stdin = false;
        stdin = undefined;
        stdinFile = undefined;
        stdinQuoted = false;
        stdinUnsafe = true;
      }
      // Descriptor duplication can close or replace fd 0 (`0<&-`, `0<&3`). It is not a body
      // source and must shadow any heredoc/file that appeared earlier in this command.
      if (op === "<&" && (fd === undefined || fd === "0")) {
        for (const doc of docs) doc.stdin = false;
        stdin = undefined;
        stdinFile = undefined;
        stdinQuoted = false;
        stdinUnsafe = true;
      }
      continue;
    }
    if (char === ";" || char === "&" || char === "|" || char === "(" || char === ")") {
      // Only syntax reached by the lexer counts. Quoted words, substitutions, comments and
      // heredoc bodies are consumed elsewhere and may contain these characters as message text.
      if (char === "(" || char === ")") grouped = true;
      const two = line.slice(index, index + 2);
      if (two === "&&" || two === "||" || two === ";;" || two === "|&") {
        index += 2;
        end(two === "&&" ? "&&" : two === "||" ? "||" : two === "|&" ? "|" : ";");
      } else {
        index += 1;
        end(char === "|" ? "|" : char === "&" ? "&" : ";");
        if (char === ")") closed = true;
      }
      continue;
    }
    const [word, next] = readWord(line, index, runs);
    const raw = line.slice(index, next);
    index = next;
    // `{ …; }` groups commands; the braces are not words of them.
    if (raw === "{" || raw === "}") {
      grouped = true;
      end(";");
      continue;
    }
    words.push(word);
  }
  end("");
  readBodies();
  // A group can close after its command was emitted; mark the complete parsed line once.
  if (grouped) for (const command of commands) command.grouped = true;
  return commands;
}

/**
 * Bodies a preceding recorded shell call wrote to a literal path. This is deliberately a
 * transcript-only projection: it never reads the host filesystem. `undefined` means the path was
 * overwritten by a write whose contents were not safely recorded, so callers must forget it.
 */
export type RecordedMessageBodyChange = { path: string; text?: string } | { reset: true };
const MESSAGE_PATH_MUTATORS = new Set([
  "cd",
  "cp",
  "env",
  "install",
  "mv",
  "popd",
  "pushd",
  "rm",
  "sed",
  "tee",
  "truncate",
]);

function recordedMessageBodyChange(command: ShellCommand): RecordedMessageBodyChange | undefined {
  // `;` is the parser's synthetic terminator for a standalone heredoc command. Every other
  // operator may skip the write or alter its working directory before the send.
  if (command.op !== "" && command.op !== ";") return { reset: true };
  if (
    command.grouped ||
    command.runs?.length ||
    command.stdinUnsafe ||
    (command.stdinRedirects ?? 0) !== 1 ||
    command.redirectUnsafe ||
    (command.redirectWrites ?? 0) > 1
  )
    return { reset: true };
  const words = unwrapped(command.words);
  const name = program(words[0]);
  if (command.writeFile?.literal) {
    const path = command.writeFile.text;
    // Relative paths, dot segments and duplicate separators depend on the writer's cwd or
    // filesystem normalization. Keep the body unresolved unless the recorded path is unambiguous.
    if (!path.startsWith("/") || path.includes("//") || path.includes("/./") || path.includes("/../"))
      return { reset: true };
    const body = command.words.length === 1 && name === "cat" && command.stdinQuoted ? command.stdin : undefined;
    if (!body || typeof body === "string" || !body.literal) return { reset: true };
    return {
      path,
      text: body.text,
    };
  }
  if (command.writes || !name || MESSAGE_PATH_MUTATORS.has(name) || SHELLS.has(name) || REMOTES.has(name))
    return { reset: true };
  // Unknown commands may write through libraries, scripts, xargs or shell APIs. Without a typed
  // recorded-write event, fail closed instead of preserving an older producer body.
  return { reset: true };
}

export function recordedMessageBodyChanges(line: string): RecordedMessageBodyChange[] {
  const commands = shellCommands(line);
  // A control operator can skip a write or change its working directory. Without an event-level
  // execution record, discard every cached producer rather than guessing which branch ran.
  // A heredoc line ends with the parser's synthetic `;`; with no second command it is still a
  // single executed writer. Any other operator means execution or directory state is uncertain.
  if (commands.length !== 1) return [{ reset: true }];
  const command = commands[0]!;
  // A successful standalone send only reads its input. Preserve a prior producer for another
  // send, including through a shell/reach wrapper; writes and uncertain shell state still reset.
  if (
    !command.grouped &&
    !command.writes &&
    !command.runs?.length &&
    !command.redirectUnsafe &&
    !command.stdinUnsafe &&
    (command.stdinRedirects ?? 0) <= 1
  ) {
    const provenance = { unsafe: false };
    const send = readAcpmuxSend(line, undefined, 0, undefined, undefined, provenance);
    if (!provenance.unsafe && send?.ownsExit && !send.unsure && !send.others) return [];
  }
  const change = recordedMessageBodyChange(commands[0]!);
  return change ? [change] : [];
}

// Tool rows are immutable snapshots but the enclosing turn is rebuilt as streamed calls arrive.
// Keep parsing by tool snapshot identity plus command revision so appending a later call does not
// reparse earlier shell lines, even for turns longer than a fixed cache cap. Weak ownership keeps
// entries only as long as their tool snapshots are live; no cache entry retains a transcript row.
let recordedBodyCache = new WeakMap<object, { command: string; changes: readonly RecordedMessageBodyChange[] }>();
let recordedBodyParseCount = 0;

export function recordedMessageBodyChangesForTool(tool: {
  id: string;
  command?: string;
}): readonly RecordedMessageBodyChange[] {
  if (!tool.command) return [];
  const cached = recordedBodyCache.get(tool);
  if (cached?.command === tool.command) return cached.changes;
  recordedBodyParseCount += 1;
  const changes = recordedMessageBodyChanges(tool.command);
  recordedBodyCache.set(tool, { command: tool.command, changes });
  return changes;
}

function applyRecordedMessageBodyChange(command: ShellCommand, files: Map<string, ShellWord>): void {
  const change = recordedMessageBodyChange(command);
  if (!change) return;
  if ("reset" in change) {
    files.clear();
    return;
  }
  if (change.text === undefined) files.delete(change.path);
  else files.set(change.path, { text: change.text, literal: true });
}

/** Test-only observability for the lifetime-owned revision memo. */
export function resetRecordedMessageBodyCacheForTests(): void {
  recordedBodyCache = new WeakMap();
  recordedBodyParseCount = 0;
}

/** Test-only observability for the lifetime-owned revision memo. */
export function recordedMessageBodyParseCountForTests(): number {
  return recordedBodyParseCount;
}

/// What an unclosed quote leaves among a command's scripts: the shell refuses the line, so the
/// command runs nothing a send row could name (`onlyReads` reads it as no reader).
const UNCLOSED = "\u0000";

/// Redirects that write the file they name.
const WRITES = new Set([">", ">>", ">|", "<>", "&>", "&>>"]);

/// The word at `from`, and where it ends; the scripts of its command substitutions go in `runs`.
function readWord(line: string, from: number, runs: string[] = []): [ShellWord, number] {
  let text = "";
  let literal = true;
  let brace = false;
  let index = from;
  while (index < line.length) {
    const char = line[index]!;
    if (META.test(char)) break;
    if (char === "'") {
      const close = line.indexOf("'", index + 1);
      const stop = close < 0 ? line.length : close;
      if (close < 0) runs.push(UNCLOSED);
      text += line.slice(index + 1, stop);
      index = stop + 1;
    } else if (char === "$" && line[index + 1] === "'") {
      index += 2;
      while (index < line.length && line[index] !== "'") {
        if (line[index] === "\\" && index + 1 < line.length) {
          const escape = line[index + 1]!;
          // `\x41`, `\u00e9`, octal and the like: not read here, so the word is not the text shown.
          if (!Object.prototype.hasOwnProperty.call(ANSI_C, escape)) literal = false;
          text += ANSI_C[escape] ?? escape;
          index += 2;
        } else text += line[index++];
      }
      if (index >= line.length) runs.push(UNCLOSED);
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
      if (index >= line.length) runs.push(UNCLOSED);
      index += 1;
    } else if (char === "\\") {
      if (line[index + 1] !== "\n") text += line[index + 1] ?? "";
      index += 2;
    } else if (char === "$" || char === "`") {
      const stop = expansionEnd(line, index, runs);
      if (stop > index + 1) literal = false;
      text += line.slice(index, stop);
      index = stop;
    } else {
      // An unquoted glob (`*`, `?`, `[`) or brace expansion (`{a,b}`) is not the word as typed.
      if (char === "*" || char === "?" || char === "[" || (char === "}" && brace)) literal = false;
      // `~` at a word's start is a home directory.
      if (char === "~" && index === from) literal = false;
      if (char === "{") brace = true;
      text += line[index++];
    }
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
    runs.push(index < line.length ? line.slice(from + 1, index) : UNCLOSED);
    return Math.min(line.length, index + 1);
  }
  const next = line[from + 1];
  if (next === "(" || next === "{") {
    const close = balancedEnd(line, from + 1);
    if (close < 0) {
      runs.push(UNCLOSED);
      return line.length;
    }
    // `${V:-$(cmd)}` runs cmd too.
    runs.push(...(next === "(" ? [line.slice(from + 2, close - 1)] : substitutions(line.slice(from + 2, close - 1))));
    return close;
  }
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

/// The end of the bracket at `open` and what it holds, quotes inside kept whole; -1 when it never closes.
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
  return -1;
}

/// Words that only set the stage for the command after them.
const RESERVED = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "time"]);
/// Programs that run the command their arguments give: the options that take a value, and the
/// flags, that still run it. Any other option (`--help`, `env -S`) is not looked through.
type Runner = { values: ReadonlySet<string>; flags: RegExp };
const RUNNERS: Record<string, Runner> = {
  nohup: { values: new Set(), flags: /^$/ },
  command: { values: new Set(), flags: /^-p$/ },
  exec: { values: new Set(["-a"]), flags: /^-[cl]+$/ },
  nice: { values: new Set(["-n", "--adjustment"]), flags: /^-\d+$/ },
  env: { values: new Set(["-u", "--unset", "-C", "--chdir"]), flags: /^(?:-i|-|--ignore-environment)$/ },
  timeout: {
    values: new Set(["-s", "--signal", "-k", "--kill-after"]),
    flags: /^(?:--foreground|--preserve-status|-v|--verbose)$/,
  },
};
/// Steps that only set up the shell, or report: they do no work a send row would hide.
const SETUP = new Set(["cd", "pushd", "popd", "export", "set", "unset", "true", ":", "wait", "echo", "printf"]);
/// Steps a send's output may pipe through (`| tail -1`): how many operands each may have (a
/// pattern, a jq filter) and the options it may take, none of which reads or writes a file. A word
/// that is a number is an option's value (`-n 5`). They only cut what the send printed.
const FILTERS: Record<string, { operands: number; options: RegExp; values?: ReadonlySet<string> }> = {
  tail: { operands: 0, options: /^-(?:[nc]?\d*|[qv])$/, values: new Set(["-n", "-c"]) },
  head: { operands: 0, options: /^-(?:[nc]?\d*|[qv])$/, values: new Set(["-n", "-c"]) },
  cat: { operands: 0, options: /^-[AbeEnstuv]+$/ },
  wc: { operands: 0, options: /^-[lwcmL]+$/ },
  grep: { operands: 1, options: /^-[ivcnqxwoEFGPhsHmABC]+\d*$/, values: new Set(["-m", "-A", "-B", "-C"]) },
  jq: { operands: 1, options: /^-(?:[rcjaMSCe]+|-raw-output|-compact-output|-exit-status|-join-output)$/ },
};
/// What a command substitution may run and still only read (`"$(cat note.md)"`).
const READERS = new Set(["cat", "head", "tail", "date", "basename", "dirname", "pwd", "echo", "printf"]);
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh", "fish"]);
/// `reach`'s options that take a value and still run the command (`reach --help`); any other
/// option (`--help`, `--list`, `--why`, …) does something else.
const REACH_VALUES = new Set(["--origin", "--registry", "--timeout"]);
/// Wrappers that run their command line on another machine: `reach HOST '…'` and `ssh HOST '…'`.
/// The session a send there names is on that host unless it names its own.
const REMOTES = new Set(["reach", "ssh"]);
/// `ssh`'s options that take a value (`ssh -p 22 -o X=Y host …`), and its flags that still run the
/// command. -G, -N, -O, -Q, -V, -W and -s do something else (print, forward, control, a subsystem).
const SSH_VALUES = "BbcDEeFIiJLlmoPpRSw";
const SSH_FLAGS = "46AaCfgKkMnqTtvXxYy";
/// ssh options that point its stdin at /dev/null (`-n`, `-f`): no stream reaches the remote send.
const SSH_NO_STDIN = /^-[^-]*[nf]/;
/// `-o` keys that change what ssh runs or where its stdin goes (SessionType=none is -N, StdinNull
/// is -n, LocalCommand runs a local command): the line is not read as a plain remote send.
const SSH_REFUSED_KEYS =
  /^(?:sessiontype|stdinnull|forkafterauthentication|localcommand|permitlocalcommand|remotecommand)\b/i;

/// The host and command line a remote wrapper runs, or nil when the words run no command there
/// (an option that does something else, a missing value, no host or no command).
function remoteRun(
  name: string,
  words: readonly ShellWord[],
): { host: string; inner: ShellWord[]; stdin: boolean } | undefined {
  let at = 1;
  let stdin = true;
  if (name === "reach") {
    while (REACH_VALUES.has(words[at]?.text ?? "")) {
      // A missing value, or one that looks like an option, is a line reach refuses.
      if ((words[at + 1]?.text ?? "-").startsWith("-")) return undefined;
      at += 2;
    }
  } else {
    for (; at < words.length; at++) {
      const word = words[at]!;
      if (!word.literal) return undefined;
      if (word.text === "--") {
        at += 1;
        break;
      }
      if (!word.text.startsWith("-") || word.text === "-") break;
      // A cluster of flags, possibly ending in one option with its value (`-tt`, `-qp22`, `-i key`).
      let place = 1;
      for (; place < word.text.length; place++) {
        const letter = word.text[place]!;
        if (SSH_VALUES.includes(letter)) {
          // -E writes a log file: work of its own.
          if (letter === "E") return undefined;
          let value = word.text.slice(place + 1);
          if (!value) {
            if (at + 1 >= words.length) return undefined;
            at += 1;
            value = words[at]!.text;
          }
          // An -o value must be read to know it runs the command (`-i ~/.ssh/key` need not be).
          if (letter === "o" && (!words[at]!.literal || SSH_REFUSED_KEYS.test(value.trim()))) return undefined;
          break;
        }
        if (!SSH_FLAGS.includes(letter)) return undefined;
      }
      if (SSH_NO_STDIN.test(word.text.slice(0, place + 1))) stdin = false;
    }
  }
  const destination = words[at];
  const inner = words.slice(at + 1);
  if (!destination?.literal || destination.text.startsWith("-") || !inner.length) return undefined;
  // `user@host`, `ssh://user@host:22`: the session lives on the host. ssh takes the user up to the
  // last `@`; only the URI form carries a port.
  const uri = destination.text.match(/^ssh:\/\/(.*?)(?::\d+)?$/);
  const host = name === "ssh" ? (uri ? uri[1]! : destination.text).replace(/^.*@/, "") : destination.text;
  if (!host) return undefined;
  return { host, inner, stdin };
}
/// `acpmux send`'s options that take a value, and its flags (`acpmux send --help`).
const SEND_VALUES = new Set(["--timeout", "--on-permission", "--stall", "--prompt-id", "--from", "--supersede"]);
/// The values clap checks (`--timeout 30`, `--on-permission deny`).
const SEND_VALUE_FORMS: Record<string, RegExp> = {
  "--timeout": /^\d+$/,
  "--stall": /^\d+$/,
  "--on-permission": /^(?:wait|deny|fail)$/,
};
const SEND_FLAGS = new Set(["--json", "--steer", "--no-steer", "--suppress-reads", "--no-wait", "-q", "--quiet"]);
/// `acpmux`'s own flags, which may come before `send` (`acpmux --help`).
const ACPMUX_FLAGS = new Set(["--json", "--suppress-reads"]);

const ASSIGNMENT = /^[A-Za-z_]\w*=/;
const own = (record: object, key: string) => Object.prototype.hasOwnProperty.call(record, key);
const program = (word: ShellWord | undefined) => (word?.literal ? (word.text.split("/").pop() ?? "") : "");

/// The words of the command a wrapper runs: assignments, `env`, `timeout`, `nohup` and the like
/// before it left out.
function unwrapped(words: readonly ShellWord[]): ShellWord[] {
  let rest = [...words];
  for (let guard = 0; guard < 16 && rest.length; guard++) {
    const head = rest[0]!;
    const name = program(head);
    if (head.literal && (ASSIGNMENT.test(head.text) || RESERVED.has(head.text))) rest = rest.slice(1);
    else if (own(RUNNERS, name) || name === "gtimeout") {
      const runner = RUNNERS[name === "gtimeout" ? "timeout" : name]!;
      const after = afterOptions(rest.slice(1), runner, name === "env");
      if (!after) return rest;
      // `timeout [OPTIONS] DURATION COMMAND…`, the duration a number with an optional unit.
      if (runner === RUNNERS.timeout && !/^\d+(?:\.\d+)?[smhd]?$/.test(after[0]?.text ?? "")) return rest;
      rest = runner === RUNNERS.timeout ? after.slice(1) : after;
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
const PERL_EXEC = /^\s*alarm\s+\d+\s*;\s*exec\s+@ARGV\s*;?\s*$/;

/// The words after a runner's options (and, for `env`, its assignments), or nil at an option that
/// does not run the command.
function afterOptions(words: ShellWord[], runner: Runner, assignments = false): ShellWord[] | undefined {
  let index = 0;
  while (index < words.length) {
    const text = words[index]!.text;
    if (text === "--") return words.slice(index + 1);
    const name = text.split("=", 1)[0]!;
    if (assignments && ASSIGNMENT.test(text)) index += 1;
    else if (runner.values.has(name)) {
      // A value that looks like an option is a missing value: the runner refuses the line.
      if (!text.includes("=") && (words[index + 1]?.text ?? "-").startsWith("-")) return undefined;
      index += text.includes("=") ? 1 : 2;
    } else if (text.startsWith("-") && (text.length > 1 || assignments)) {
      if (!runner.flags.test(text)) return undefined;
      index += 1;
    } else break;
  }
  return words.slice(index);
}

/// The send a command line makes, or nil when it makes none, makes more than one, or does other work.
export function acpmuxSend(
  line: string,
  host?: string,
  depth = 0,
  priorFiles?: ReadonlyMap<string, string>,
  // A shell/reach wrapper's recorded stdin, inherited unless its inner command replaces it.
  inheritedStdin?: ShellWord | "file",
): AcpmuxSend | undefined {
  return readAcpmuxSend(line, host, depth, priorFiles, inheritedStdin, undefined, { sends: 0, opaque: false });
}

type SendScan = { sends: number; opaque: boolean };

function readAcpmuxSend(
  line: string,
  host: string | undefined,
  depth: number,
  priorFiles?: ReadonlyMap<string, string>,
  inheritedStdin?: ShellWord | "file",
  provenance?: { unsafe: boolean },
  scan?: SendScan,
): AcpmuxSend | undefined {
  const sendScan = scan ?? { sends: 0, opaque: false };
  if (depth > 3) {
    sendScan.opaque = true;
    return undefined;
  }
  if (!/acp/.test(line)) return undefined;
  const commands = shellCommands(line);
  // File-backed bodies come only from recorded writers in this turn. Pass the current safe map
  // through wrappers; resolving a path never reads the host filesystem.
  const recordedFiles = new Map<string, ShellWord>(
    [...(priorFiles ?? [])].map(([path, text]) => [path, { text, literal: true }]),
  );
  // A shell line with more than one simple command is intentionally opaque. Producer inference
  // is only for a standalone writer; cross-tool Bash calls use the bounded turn map instead.
  const uncertainControlFlow =
    commands.length > 1 || commands.some((command) => command.op !== "" && command.op !== ";");
  // A chain of bare cats only forwards the wrapper's already-captured stdin. Other compound
  // shell work remains opaque; no prefix may replace stdin, write, expand or group commands.
  const forwardingPipeline =
    commands.length > 1 &&
    commands.every(
      (command, index) =>
        !command.grouped &&
        !command.writes &&
        !command.runs?.length &&
        !command.redirectUnsafe &&
        !command.stdinUnsafe &&
        (index === commands.length - 1
          ? command.op === "" || command.op === ";"
          : command.op === "|" &&
            command.words.length === 1 &&
            program(command.words[0]) === "cat" &&
            !command.stdin &&
            !command.stdinRedirects),
    );
  if (uncertainControlFlow) {
    recordedFiles.clear();
    if (!forwardingPipeline) {
      inheritedStdin = undefined;
      if (provenance) provenance.unsafe = true;
    }
  }
  let found: AcpmuxSend | undefined;
  let at = -1;
  /// The send came from `acpmux send`'s own words here, not from a nested line.
  let direct = false;
  /// Commands that send, read or not (`acpmux send "$LANE" hi` is a send whose target is unknown).
  for (const [index, command] of commands.entries()) {
    // Apply producer events in shell order before examining a send. A later unknown write or
    // shadowing redirect therefore cannot reuse an earlier heredoc body.
    const commandWords = unwrapped(command.words);
    const commandName = program(commandWords[0]);
    const isSendCommand =
      ((commandName === "acpmux" || commandName === "acpmux-debug-cli") &&
        commandWords.some((word) => word.text === "send")) ||
      (commandName === "cmux" && commandWords[1]?.text === "acp" && commandWords[2]?.text === "send");
    if (
      (isSendCommand || REMOTES.has(commandName) || SHELLS.has(commandName)) &&
      (command.grouped ||
        command.writes ||
        command.runs?.length ||
        command.redirectUnsafe ||
        (command.stdinUnsafe && command.stdin !== "file"))
    ) {
      recordedFiles.clear();
      inheritedStdin = undefined;
      if (provenance) provenance.unsafe = true;
    }
    const words = unwrapped(command.words);
    const name = program(words[0]);
    let send: AcpmuxSend | undefined;
    if (REMOTES.has(name)) {
      const remote = remoteRun(name, words);
      if (remote && remote.inner.every((word) => word.literal))
        send = readAcpmuxSend(
          remote.inner.map((word) => word.text).join(" "),
          remote.host,
          depth + 1,
          // Paths inside the remote script belong to that host. Only stdin already opened by
          // the local wrapper is a known stream; a remote redirect must resolve independently.
          undefined,
          remote.stdin ? stdinOf(commands, index, recordedFiles, inheritedStdin) : undefined,
          provenance,
          sendScan,
        );
      // A host or command that is not literal (`reach "$H" "$CMD"`) may hold a send of its own.
      else if (remote || words.slice(1).some((word) => !word.literal || /\bacp/.test(word.text)))
        sendScan.opaque = true;
    } else if (SHELLS.has(name)) {
      // `-c` among the options before the first operand (`bash script -c …` runs script).
      let flag = -1;
      // Only options that still run the script (`-n` only checks it, `-o` takes a value).
      for (let place = 1; place < words.length && words[place]!.text.startsWith("-"); place++) {
        if (!/^-[cilex]+$/.test(words[place]!.text)) break;
        if (words[place]!.text.includes("c")) {
          flag = place;
          break;
        }
      }
      const script = flag > 0 ? words[flag + 1] : undefined;
      if (script?.literal)
        send = readAcpmuxSend(
          script.text,
          host,
          depth + 1,
          new Map([...recordedFiles].map(([path, body]) => [path, body.text])),
          stdinOf(commands, index, recordedFiles, inheritedStdin),
          provenance,
          sendScan,
        );
      else if (flag > 0) sendScan.opaque = true;
    } else if (name === "acpmux" || name === "acpmux-debug-cli") {
      let sub = 1;
      while (ACPMUX_FLAGS.has(words[sub]?.text ?? "")) sub += 1;
      if (words[sub]?.text === "send") {
        sendScan.sends += 1;
        send = sendArgs(
          words.slice(sub + 1),
          stdinOf(commands, index, recordedFiles, inheritedStdin),
          host,
          pathOf(command),
        );
      }
    } else if (name === "cmux" && words[1]?.text === "acp" && words[2]?.text === "send") {
      sendScan.sends += 1;
      send = sendArgs(words.slice(3), stdinOf(commands, index, recordedFiles, inheritedStdin), host, pathOf(command));
    }
    if (!uncertainControlFlow && !send) applyRecordedMessageBodyChange(command, recordedFiles);
    if (sendScan.sends > 1) return undefined;
    if (send) {
      if (found) return undefined;
      found = send;
      at = index;
      direct = !REMOTES.has(name) && !SHELLS.has(name);
    }
  }
  if (!found) {
    // A command substitution can contain a send even when the nested parser cannot resolve it
    // (for example, a dynamic target). Scan its executable runs before returning so an outer send
    // cannot be mistaken for the only message; quoted mentions produce no runs and stay harmless.
    for (const command of commands) {
      const busy = (command.runs ?? []).filter((script) => !onlyReads(script, depth));
      if (busy.some((script) => /\bacp/.test(script))) {
        sendScan.opaque = true;
        break;
      }
    }
  }
  if (!found || sendScan.sends > 1 || sendScan.opaque) return undefined;
  // Every other step that does more than set up, report, feed the send or filter what it printed
  // is other work, and so is a step that writes a file or runs a substitution that does more than
  // read: the row counts them ("and 1 more"). A line the shell refuses (an unclosed quote), a send
  // inside a substitution (a second message), or an `exit` before the send is no send row.
  let others = found.others ?? 0;
  let pipedFromSend = false;
  for (const [index, command] of commands.entries()) {
    pipedFromSend = index > at && commands[index - 1]!.op === "|" && (index === at + 1 || pipedFromSend);
    const runs = command.runs ?? [];
    if (runs.includes(UNCLOSED)) return undefined;
    const busy = runs.filter((script) => !onlyReads(script, depth));
    if (busy.some((script) => /\bacp/.test(script))) {
      // A substitution or unquoted here-document can run a nested send. The command's
      // descriptor is no longer safe to resolve; propagate that ambiguity to the outer scan so
      // a later direct send cannot be mistaken for the only message.
      sendScan.opaque = true;
      return undefined;
    }
    const words = unwrapped(command.words);
    const name = program(words[0]);
    if (name === "exit" && index < at) return undefined;
    if (command.writes || busy.length) others += 1;
    else if (index === at) continue;
    else if (SETUP.has(name) || command.words.every((word) => word.literal && ASSIGNMENT.test(word.text))) continue;
    else if (forwardingPipeline && index < at) continue;
    // A filter reads the send's output only when nothing else is its stdin (`| tail -1 < log`).
    else if (pipedFromSend && !command.stdin && own(FILTERS, name) && onlyFilters(words.slice(1), FILTERS[name]!))
      continue;
    // `cat <<EOF | acpmux send x -`: cat only hands the send its text.
    else if (name === "cat" && index === at - 1 && command.op === "|" && command.words.length === 1) continue;
    else others += 1;
  }
  const send: AcpmuxSend = { ...found };
  delete send.others;
  delete send.ownsExit;
  delete send.unsure;
  if (others) send.others = others;
  // A nested line (`reach host '…'`, `bash -c '…'`) passes on whether its send owns its status
  // and whether it surely ran.
  const before = commands.slice(0, at).map((command) => command.op);
  const skippable = before.includes("||");
  if (found.unsure || skippable || before.includes("&&")) send.unsure = true;
  // `! acpmux send …` inverts the status: it is not the send's.
  const inverted = commands[at]!.words[0]?.literal === true && commands[at]!.words[0]!.text === "!";
  const last = !inverted && at === commands.length - 1 && commands[at]!.op !== "|" && commands[at]!.op !== "&";
  if (last && !skippable && (direct || found.ownsExit)) send.ownsExit = true;
  return send;
}

/// Whether a filter's words are options it may take, their numbers (`-n 5`), and at most its operands.
function onlyFilters(words: readonly ShellWord[], filter: (typeof FILTERS)[string]): boolean {
  let operands = 0;
  for (const [index, word] of words.entries()) {
    if (!word.literal) return false;
    if (word.text.length > 1 && word.text.startsWith("-")) {
      if (!filter.options.test(word.text)) return false;
    } else if (filter.values?.has(words[index - 1]?.text ?? "") && /^\+?\d+$/.test(word.text)) continue;
    else if (++operands > filter.operands) return false;
  }
  return true;
}

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
/// here-string, or an `echo`, `printf` or a chain of bare cats piped into it.
function stdinOf(
  commands: readonly ShellCommand[],
  index: number,
  recordedFiles: ReadonlyMap<string, ShellWord>,
  inheritedStdin?: ShellWord | "file",
): ShellWord | "file" | undefined {
  // Walk bare-cat input pipes iteratively so even a long forwarding chain uses constant stack.
  while (true) {
    const command = commands[index]!;
    // Any competing stdin source (including a later fd-0 output or here-string) makes the final
    // source ambiguous; do not fall back to a recorded file when stdinUnsafe is set.
    if (command.stdinUnsafe) return undefined;
    const own = command.stdin;
    if (own) {
      if (own === "file" && command.stdinFile?.literal) return recordedFiles.get(command.stdinFile.text) ?? own;
      return own;
    }
    const before = commands[index - 1];
    // Its stdout sent elsewhere (`echo x >/dev/null | …`), nothing comes down the pipe.
    if (before?.op !== "|") return inheritedStdin;
    if (before.stdout || before.stdinUnsafe) return undefined;
    const words = unwrapped(before.words);
    const name = program(words[0]);
    if (name === "cat" && words.length === 1) {
      index -= 1;
      continue;
    }
    if (name === "echo") {
      const args = words.slice(1);
      while (args[0] && /^-[neE]+$/.test(args[0].text)) args.shift();
      const text = args.map((word) => word.text).join(" ");
      // zsh's echo, and bash's with -e, turn backslash escapes into characters.
      return { text, literal: !text.includes("\\") && args.every((word) => word.literal) };
    }
    // `printf 'text\n'`: its format is the text when it formats nothing.
    if (name === "printf" && words.length === 2) {
      const format = words[1]!;
      return {
        text: format.text.replace(/\\n/g, "\n").replace(/\\t/g, "\t"),
        literal: format.literal && !/[%\\]/.test(format.text.replace(/\\[nt]/g, "")),
      };
    }
    if (name === "printf") return { text: "", literal: false };
    return undefined;
  }
}

/// The literal path a command's `< path` stdin names.
const pathOf = (command: ShellCommand) => (command.stdinFile?.literal ? command.stdinFile.text : undefined);

/// `acpmux send [OPTIONS] [SESSION] [PROMPT]...`, read as clap reads it: options anywhere until
/// `--`, the first other word the session, the rest the prompt; none or `-` reads stdin.
function sendArgs(
  args: readonly ShellWord[],
  stdin: ShellWord | "file" | undefined,
  host?: string,
  /// The path of a `< path` stdin, when the line names it literally.
  stdinPath?: string,
) {
  const positional: ShellWord[] = [];
  let noWait = false;
  let steer: string | undefined;
  let options = true;
  for (let index = 0; index < args.length; index++) {
    const word = args[index]!;
    const text = word.text;
    if (options && text === "--") options = false;
    else if (options && text.startsWith("-") && text !== "-") {
      const name = text.split("=", 1)[0]!;
      // `--status ID` reads a delivery's state; help prints usage. Neither sends anything.
      if (name === "--status" || name === "--help" || /^-[a-zA-Z]*h/.test(name)) return undefined;
      // An option acpmux does not know, a value on a flag, or both --steer and --no-steer fail the
      // call: it sends nothing.
      if (SEND_FLAGS.has(name) ? text.includes("=") : !SEND_VALUES.has(name)) return undefined;
      if (name === "--steer" || name === "--no-steer") {
        if (steer && steer !== name) return undefined;
        steer = name;
      }
      if (name === "--no-wait") noWait = true;
      if (SEND_VALUES.has(name)) {
        const value = text.includes("=") ? text.slice(name.length + 1) : args[++index]?.text;
        // clap parses these: a value it rejects fails the call.
        // A missing value, or one clap would read as an option, fails the call too.
        if (value === undefined || (!text.includes("=") && value.startsWith("-"))) return undefined;
        if (!(SEND_VALUE_FORMS[name]?.test(value) ?? true)) return undefined;
      }
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
  // The words are not known but where they come from is: `"$(cat note.md)"` or a `< note.md` stdin.
  const file = text?.trim()
    ? undefined
    : fromStdin
      ? stdin === "file"
        ? stdinPath
        : undefined
      : words.length === 1
        ? readFileOf(words[0]!.text)
        : undefined;
  return { target, ...(text?.trim() && { text }), ...(file && { file }), noWait } satisfies AcpmuxSend;
}

/// `$(cat PATH)`, `$(cat -- PATH)`, `$(<PATH)` or `$(< PATH)`, PATH one word with no expansion left
/// in it (quotes allowed): the file a prompt word reads, else nil.
const READ_FILE = /^\$\((?:\s*cat\s+(?:--\s+)?|\s*<\s*)(["']?)([^\s"'$`;&|<>()]+)\1\s*\)$/;
function readFileOf(text: string): string | undefined {
  return READ_FILE.exec(text)?.[2];
}

// Several messages from one shell call: a coordinator's batch, read so each message draws as its
// own sent-message row (Leo 2026-10-30: "these should be properly rendered too/acpmux batch send
// tools given to you rendered consistently with other stuff"). The shapes it reads:
//   s(){ acpmux send --no-wait --from me "$1" "$(cat "$2")" 2>&1 | tail -1; }; s a a.md; s b b.md
//   for lane in a b c; do acpmux send --no-wait "$lane" "$(cat "/tmp/briefs/$lane.md")"; done
//   acpmux send a 'one' && acpmux send b 'two'
// A shell function's `$1`…`$9` take each call's words, a `for NAME in WORDS` loop's `$NAME` takes
// each word, and a send's prompt that only reads a file (`"$(cat "$2")"`) names that file. A send
// whose target is still an expansion afterwards (`"$LANE"`, a glob, `while read`), a wrapper that
// runs a script (`bash -c`, `reach`), a send inside a substitution, or more than `BATCH_CAP` sends
// leave the call a command row: nothing is guessed. Other work is counted as a single send counts
// it (`others`); its command, as always, stays behind Raw.

/// One message of a batch, as its row names it.
export type AcpmuxBatchSend = { target: string; text?: string; file?: string; noWait: boolean };
export type AcpmuxSendBatch = { sends: AcpmuxBatchSend[]; others?: number };

/// More sends than this from one call stay a command row: the transcript lists no unbounded fan-out.
const BATCH_CAP = 64;
const FUNCTION_HEAD = /(?:function[ \t]+)?([A-Za-z_][\w-]*)[ \t]*\([ \t]*\)[ \t\n]*\{/y;
const FUNCTION_KEYWORD = /function[ \t]+([A-Za-z_][\w-]*)[ \t\n]*\{/y;
const NAME = /^[A-Za-z_]\w*$/;
/// Words that start or branch a construct whose body may not run: its sends are not known to go.
const CONDITIONAL = new Set(["while", "until", "if", "then", "elif", "else", "fi", "case", "esac", "select"]);
/// `$(<path)`: bash's way to read a file, which does nothing else.
const READS_FILE = /^\s*<\s*[^\s;&|<>()]+\s*$/;

/// The line with its function definitions taken out, and their bodies by name; nil for a
/// definition that never closes. A line with a here-document keeps its text as is (its body may
/// hold anything), so it defines no function.
function splitFunctions(line: string): { rest: string; functions: Map<string, string> } | undefined {
  const functions = new Map<string, string>();
  if (line.includes("<<")) return { rest: line, functions };
  let rest = "";
  let index = 0;
  let start = true;
  while (index < line.length) {
    const char = line[index]!;
    if (char === " " || char === "\t" || char === "\r") {
      rest += char;
      index += 1;
      continue;
    }
    if (start) {
      FUNCTION_HEAD.lastIndex = index;
      FUNCTION_KEYWORD.lastIndex = index;
      const head = FUNCTION_HEAD.exec(line) ?? FUNCTION_KEYWORD.exec(line);
      if (head) {
        const open = index + head[0].length - 1;
        const close = balancedEnd(line, open);
        if (close < 0) return undefined;
        functions.set(head[1]!, line.slice(open + 1, close - 1));
        rest += ";";
        index = close;
        start = false;
        continue;
      }
    }
    if (char === "#" && start) {
      while (index < line.length && line[index] !== "\n") index += 1;
      continue;
    }
    if (";&|(){}\n".includes(char)) {
      rest += char;
      index += 1;
      start = true;
      continue;
    }
    if (char === "<" || char === ">") {
      rest += char;
      index += 1;
      continue;
    }
    const [, next] = readWord(line, index);
    const stop = Math.max(next, index + 1);
    rest += line.slice(index, stop);
    index = stop;
    start = false;
  }
  return { rest, functions };
}

/// A word with the values the batch knows put in: a function's `$1`…`$9`, a loop's `$NAME` and
/// `${NAME}`. It is literal again when no expansion is left in it.
function bound(word: ShellWord, values: ReadonlyMap<string, string>): ShellWord {
  if (word.literal || !values.size) return word;
  const text = word.text.replace(/\$(?:\{(\w+)\}|(\d|[A-Za-z_]\w*))/g, (whole, braced, bare) => {
    const value = values.get(braced ?? bare);
    return value ?? whole;
  });
  return { text, literal: !/[$`]/.test(text) };
}

/// The messages a shell call sends, read as a batch; nil when it is not one this can name in full.
export function acpmuxSendBatch(line: string): AcpmuxSendBatch | undefined {
  if (!/acp/.test(line)) return undefined;
  const split = splitFunctions(line);
  if (!split) return undefined;
  const sends: AcpmuxBatchSend[] = [];
  let others = 0;
  let refused = false;
  const walk = (commands: readonly ShellCommand[], values: ReadonlyMap<string, string>, depth: number) => {
    if (depth > 3) {
      refused = true;
      return;
    }
    let loop: { name: string; words: string[]; body: ShellCommand[]; nested: number } | undefined;
    for (const [index, command] of commands.entries()) {
      if (refused) return;
      const head = command.words[0];
      if (loop) {
        const first = head?.literal ? head.text : "";
        if (first === "for" || first === "while" || first === "until") loop.nested += 1;
        if (first === "done" && command.words.length === 1 && loop.nested-- === 0) {
          const { name, words, body } = loop;
          loop = undefined;
          for (const word of words) walk(body, new Map([...values, [name, word]]), depth + 1);
          continue;
        }
        loop.body.push(command);
        continue;
      }
      if (head?.literal && head.text === "for" && command.words[2]?.text === "in") {
        const name = command.words[1];
        const words = command.words.slice(3).map((word) => bound(word, values));
        if (!name?.literal || !NAME.test(name.text) || !words.every((word) => word.literal)) {
          refused = true;
          return;
        }
        loop = { name: name.text, words: words.map((word) => word.text), body: [], nested: 0 };
        continue;
      }
      // A `while` or `until` loop's targets come from what it reads: not known here. Whether a
      // send after `exit` or a `||` runs is not known from the line either (the single reader
      // refuses those too).
      if ((head?.literal && CONDITIONAL.has(head.text)) || program(head) === "exit" || command.op === "||") {
        refused = true;
        return;
      }
      const words = unwrapped(command.words).map((word) => bound(word, values));
      // Reserved words alone (`do`, `then` on a line of their own) do nothing.
      if (!words.length && !command.writes && !command.runs?.length) continue;
      const name = program(words[0]);
      const runs = command.runs ?? [];
      if (runs.includes(UNCLOSED)) {
        refused = true;
        return;
      }
      const body = split.functions.get(name);
      if (body !== undefined) {
        const args = new Map(values);
        for (let at = 1; at <= 9; at++) {
          const arg = words[at];
          // An argument that is still an expansion leaves whatever uses it unknown.
          if (arg?.literal) args.set(String(at), arg.text);
          else args.delete(String(at));
        }
        walk(shellCommands(body), args, depth + 1);
        continue;
      }
      let sub = 1;
      while (ACPMUX_FLAGS.has(words[sub]?.text ?? "")) sub += 1;
      const args =
        (name === "acpmux" || name === "acpmux-debug-cli") && words[sub]?.text === "send"
          ? words.slice(sub + 1)
          : name === "cmux" && words[1]?.text === "acp" && words[2]?.text === "send"
            ? words.slice(3)
            : undefined;
      // A substitution that does more than read is work of its own, and may itself send; a wrapper
      // that runs a script with a send in it is not read as a batch.
      const busy = runs.filter((script) => !onlyReads(script, depth) && !READS_FILE.test(script));
      if (
        busy.some((script) => /\bacp/.test(script)) ||
        ((SHELLS.has(name) || REMOTES.has(name)) && command.words.some((word) => /\bacp/.test(word.text)))
      ) {
        refused = true;
        return;
      }
      if (args) {
        // A send that also writes a file or runs a substitution that does more than read does
        // work of its own: counted, as a single send counts it.
        if (command.writes || busy.length) others += 1;
        const send = sendArgs(args, stdinOf(commands, index, new Map()), undefined, pathOf(command));
        if (!send) {
          // `--status`, `--help`, a malformed line, or a target still an expansion.
          refused = true;
          return;
        }
        if (sends.length >= BATCH_CAP) {
          refused = true;
          return;
        }
        sends.push(send);
        continue;
      }
      if (command.writes || busy.length) others += 1;
      else if (!words.length) continue;
      else if (SETUP.has(name) || name === "done" || name === "sleep") continue;
      else if (
        commands[index - 1]?.op === "|" &&
        !command.stdin &&
        own(FILTERS, name) &&
        onlyFilters(words.slice(1), FILTERS[name]!)
      )
        continue;
      else if (name === "cat" && command.op === "|" && command.words.length === 1) continue;
      else others += 1;
    }
    // A loop left open: the shell refuses the line.
    if (loop) refused = true;
  };
  walk(shellCommands(split.rest), new Map(), 0);
  if (refused || !sends.length) return undefined;
  return { sends, ...(others && { others }) };
}

/// What each `--no-wait` send of a batch printed, in order, when every send's output is one line
/// (`2>&1 | tail -1`): how the daemon took it or acpmux's error.
const BATCH_LINE = /^(?:(queued|steered|delivered)\b|acpmux: [a-z_]+: )/;

/// One message of a shell call with its state: a single send (`acpmuxSendCall`) or one of a
/// batch's (`acpmuxSendBatch`); `index` and `count` place a batch's message among its others.
export type AcpmuxSendCallPart = AcpmuxSendCall & {
  index?: number;
  count?: number;
  /// How the daemon took this message, read from its own line of the batch's output.
  delivery?: "queued" | "delivered";
};

/// The states of a batch's messages. A message whose line of output says how it went takes that;
/// the others take the call's state: sending while it runs, sent once it ended well, and `ended`
/// (not known whether it went) when it failed or printed an error no line can be matched to.
function batchCalls(tool: Tool, batch: AcpmuxSendBatch): AcpmuxSendCallPart[] {
  const background = tool.background?.state;
  const running = tool.status === "pending" || tool.status === "in_progress" || background === "running";
  const failed =
    tool.status === "failed" ||
    (tool.exitCode !== undefined && tool.exitCode !== 0) ||
    background === "failed" ||
    background === "stopped";
  const output = tool.output ?? "";
  const lines = output
    .split("\n")
    .map((text) => text.trim())
    .filter((text) => text && !/^Exit code \d+$/.test(text));
  const matched = lines.length <= batch.sends.length && lines.every((text) => BATCH_LINE.test(text));
  const error = SEND_ERROR.test(output);
  const count = batch.sends.length;
  return batch.sends.map((send, index): AcpmuxSendCallPart => {
    const said = matched ? BATCH_LINE.exec(lines[index] ?? "") : null;
    const state: SendState = said
      ? said[1]
        ? "sent"
        : "failed"
      : running
        ? "sending"
        : failed || error
          ? "ended"
          : "sent";
    const delivery = said?.[1] ? (said[1] === "queued" ? "queued" : "delivered") : undefined;
    return {
      ...send,
      state,
      index,
      count,
      ...(batch.others && { others: batch.others }),
      ...(delivery && { delivery }),
    };
  });
}

// Every streamed update rebuilds the turn's groups (toolGroups.ts), but a call's snapshot only
// changes when that call does: keep its reading by snapshot identity and revision, so a token
// elsewhere in the turn never parses this call's command line again.
type SendCallsMemo = {
  command: string;
  status: Tool["status"];
  output: string | undefined;
  exitCode: number | undefined;
  background: string | undefined;
  calls: readonly AcpmuxSendCallPart[] | undefined;
};
let sendCallsCache = new WeakMap<object, SendCallsMemo>();
let sendCallsParseCount = 0;

/// The messages a shell call sends, each with its state: one for a single `acpmux send`, several
/// for a batch, nil for any other call. Memoized per call snapshot when no recorded message files
/// are in play (those depend on the calls before it).
export function acpmuxSendCalls(
  tool: Tool,
  priorFiles?: ReadonlyMap<string, string>,
): readonly AcpmuxSendCallPart[] | undefined {
  if (tool.kind !== "execute" || !tool.command) return undefined;
  const memoizable = !priorFiles?.size;
  if (memoizable) {
    const memo = sendCallsCache.get(tool);
    if (
      memo &&
      memo.command === tool.command &&
      memo.status === tool.status &&
      memo.output === tool.output &&
      memo.exitCode === tool.exitCode &&
      memo.background === tool.background?.state
    )
      return memo.calls;
  }
  sendCallsParseCount += 1;
  const single = acpmuxSendCall(tool, priorFiles);
  let calls: readonly AcpmuxSendCallPart[] | undefined;
  if (single) calls = [single];
  else {
    const batch = acpmuxSendBatch(tool.command);
    calls = batch ? batchCalls(tool, batch) : undefined;
  }
  if (memoizable)
    sendCallsCache.set(tool, {
      command: tool.command,
      status: tool.status,
      output: tool.output,
      exitCode: tool.exitCode,
      background: tool.background?.state,
      calls,
    });
  return calls;
}

/** Test-only: how many times `acpmuxSendCalls` read a command line instead of its memo. */
export function acpmuxSendCallsParseCountForTests(): number {
  return sendCallsParseCount;
}

/** Test-only: forget every memoized reading. */
export function resetAcpmuxSendCallsCacheForTests(): void {
  sendCallsCache = new WeakMap();
  sendCallsParseCount = 0;
}
