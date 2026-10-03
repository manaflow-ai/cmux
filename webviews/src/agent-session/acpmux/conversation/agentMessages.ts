// Tool calls that send a message to another agent: `tell-coordinator`, `cmux send`, a write
// into a coordinator mailbox (`coordinator-inbox/<name>.jsonl`) and Claude Code's SendMessage. The transcript draws
// them as message cards (MessageCard.tsx) instead of raw shell or JSON.
import type { AcpmuxActivity } from "../model";

/// How the message went out, for the card's quiet label.
export type AgentMessageChannel = "coordinator" | "terminal" | "mailbox" | "agent";

export type AgentMessage = {
  channel: AgentMessageChannel;
  /// Who the sender says it is (`--from`), when the call names it.
  from?: string;
  /// The recipient: a session, a terminal surface or workspace, or a mailbox.
  to?: string;
  /// The message, or its summary when the tool carries one; empty when it came from stdin.
  text: string;
};

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The message a tool call sends, or nil for every other call.
export function agentMessage(tool: Tool): AgentMessage | undefined {
  if (tool.command) return commandMessage(tool.command);
  const input = parseInput(tool.inputSummary);
  // Claude Code's own tool, by its exact name: an MCP tool such as `mcp__gmail__send_message`
  // is not a message to an agent.
  if (input && /^send ?message$/i.test(tool.title.trim()) && typeof input.to === "string") {
    const body = input.message ?? input.summary ?? input.content;
    const text = typeof body === "string" ? body : body === undefined ? "" : JSON.stringify(body, null, 2);
    return { channel: "agent", to: input.to, text: oneMessage(text) };
  }
  // A file tool that creates or appends to a message in a mailbox. A rewrite of an existing
  // file is an edit, whatever folder it is in.
  const diffs = tool.diffs ?? [];
  if (diffs.length === 1) {
    const diff = diffs[0]!;
    const to = mailboxRecipient(diff.path);
    const before = diff.oldText ?? "";
    if (to && diff.newText.startsWith(before))
      return { channel: "mailbox", to, text: oneMessage(diff.newText.slice(before.length)) };
  }
  return undefined;
}

function parseInput(summary: string | undefined): Record<string, unknown> | undefined {
  if (!summary) return undefined;
  try {
    const value = JSON.parse(summary);
    return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

/// The recipient of a coordinator mailbox, `coordinator-inbox/<name>.jsonl`, the one mailbox
/// convention agents write. Any other folder named inbox (`first-party-apps/inbox/strings/`,
/// `src/inbox/reducer.ts`) holds source files.
export function mailboxRecipient(path: string): string | undefined {
  return /(?:^|\/)coordinator-inbox\/([\w-]+)\.jsonl$/.exec(path)?.[1];
}

/// A shell command line's message: its first step that sends one.
export function commandMessage(command: string): AgentMessage | undefined {
  const heredoc = heredocBody(command);
  const steps = shellSteps(withoutHeredoc(command)).map(parseStep);
  for (const [index, step] of steps.entries()) {
    // `CMUX_TAG=x scripts/cmux-debug-cli.sh send …`: assignments before the program are not it.
    const words = step.words.slice(
      Math.max(
        0,
        step.words.findIndex((word) => !/^\w+=/.test(word)),
      ),
    );
    const redirects = step.redirects;
    const program = words[0]?.split("/").pop();
    if (program === "tell-coordinator") return coordinatorMessage(words.slice(1), heredoc);
    if ((program === "cmux" || program === "cmux-debug-cli.sh") && words[1] === "send")
      return sendMessage(words.slice(2));
    // `… >> inbox/leo/note` or `… | tee -a inbox/leo/note`: the text is the here-document's,
    // or what this step or the one piped into it echoes.
    const targets = program === "tee" ? words.slice(1).filter((word) => !word.startsWith("-")) : redirects;
    const to = targets.map(mailboxRecipient).find(Boolean);
    if (to) {
      const text =
        heredoc ?? echoedText(words) ?? (program === "tee" ? echoedText(steps[index - 1]?.words) : undefined);
      return { channel: "mailbox", to, text: oneMessage(text ?? "") };
    }
  }
  return undefined;
}

/// `--name value` or `--name=value`: the value and how many words it took, or nil for another word.
function option(args: readonly string[], index: number, name: string): [string | undefined, number] | undefined {
  const word = args[index]!;
  if (word === name) return [args[index + 1], 2];
  if (word.startsWith(`${name}=`)) return [word.slice(name.length + 1), 1];
  return undefined;
}

/// `tell-coordinator [--to NAME] [--re ID] [--from CLAIM] TEXT|-`, read as the script reads it:
/// options until the first other word, which starts the text. Without `--to` it goes to the
/// coordinator; `-h` or `--help` among the options sends nothing.
function coordinatorMessage(args: string[], heredoc: string | undefined): AgentMessage | undefined {
  const message: AgentMessage = { channel: "coordinator", to: "coordinator", text: "" };
  let index = 0;
  for (; index < args.length; index += 2) {
    const word = args[index];
    if (word === "-h" || word === "--help") return undefined;
    if (word === "--to") message.to = args[index + 1] ?? message.to;
    else if (word === "--from") message.from = args[index + 1];
    else if (word !== "--re") break;
  }
  const text = args.slice(index).join(" ");
  message.text = oneMessage(text === "-" || !text ? (heredoc ?? "") : text);
  return message;
}

/// `cmux send [--workspace W] [--surface S] TEXT`: typed into another terminal, usually another agent's.
function sendMessage(args: string[]): AgentMessage | undefined {
  if (args.includes("--help") || args.includes("-h")) return undefined;
  let workspace: string | undefined;
  let surface: string | undefined;
  const rest: string[] = [];
  for (let index = 0; index < args.length;) {
    const inWorkspace = option(args, index, "--workspace");
    const inSurface = option(args, index, "--surface");
    if (inWorkspace) workspace = inWorkspace[0];
    else if (inSurface) surface = inSurface[0];
    else if (!args[index]!.startsWith("--")) rest.push(args[index]!);
    index += (inWorkspace ?? inSurface)?.[1] ?? 1;
  }
  return { channel: "terminal", to: surface ?? workspace, text: oneMessage(rest.join(" ")) };
}

const HEREDOC = /<<-?\s*(['"]?)(\w+)\1[^\n]*\n/;

/// The body of the command's first here-document (`<<'EOF' … EOF`).
function heredocBody(command: string): string | undefined {
  const start = HEREDOC.exec(command);
  if (!start) return undefined;
  const body = command.slice(start.index + start[0].length);
  const end = new RegExp(`^\\s*${start[2]}\\s*$`, "m").exec(body);
  return end ? body.slice(0, end.index) : body;
}

/// The command with its here-document's body cut, so the body's lines are not read as steps.
function withoutHeredoc(command: string): string {
  const start = HEREDOC.exec(command);
  if (!start) return command;
  const rest = command.slice(start.index + start[0].length);
  const end = new RegExp(`^\\s*${start[2]}\\s*$`, "m").exec(rest);
  return command.slice(0, start.index + start[0].length) + (end ? rest.slice(end.index + end[0].length) : "");
}

/// A command line's steps, split at `&&`, `||`, `|`, `&`, `;` and line breaks outside quotes.
/// An `&` in a redirect (`2>&1`, `&>`) is part of its step.
export function shellSteps(command: string): string[] {
  const steps: string[] = [];
  let step = "";
  let quote: "'" | '"' | undefined;
  for (let index = 0; index < command.length; index++) {
    const char = command[index]!;
    if (quote) {
      step += char;
      if (char === quote) quote = undefined;
      else if (char === "\\" && quote === '"' && index + 1 < command.length) step += command[++index];
      continue;
    }
    if (char === "\\") {
      step += char + (command[++index] ?? "");
      continue;
    }
    if (char === "'" || char === '"') quote = char;
    const redirect = char === "&" && (command[index - 1] === ">" || command[index + 1] === ">");
    if (char === ";" || char === "\n" || char === "|" || (char === "&" && !redirect)) {
      if (command[index + 1] === char) index++;
      steps.push(step.trim());
      step = "";
      continue;
    }
    step += char;
  }
  steps.push(step.trim());
  return steps.filter(Boolean);
}

/// What `echo` or `printf` prints, when the step is one.
function echoedText(words: readonly string[] | undefined): string | undefined {
  if (words?.[0] !== "echo" && words?.[0] !== "printf") return undefined;
  return words
    .slice(1)
    .filter((word) => !/^-[a-zA-Z]+$/.test(word))
    .join(" ");
}

/// A message's text with line breaks kept and the surrounding blank space trimmed.
function oneMessage(text: string): string {
  return text.replace(/\\n/g, "\n").trim();
}

/// A command step's words as a POSIX shell reads quotes and backslashes, and the files its
/// output redirects (`>`, `>>`, `&>`) write. An input redirect or here-document takes its word
/// from neither; a file descriptor before a redirect (`2>&1`) is not a word.
export function parseStep(line: string): { words: string[]; redirects: string[] } {
  const words: string[] = [];
  const redirects: string[] = [];
  let word = "";
  let quote: "'" | '"' | undefined;
  let started = false;
  /// Where the next word goes: an argument, a redirect's file, or nowhere (`<`, `>&1`).
  let into: "word" | "redirect" | "skip" = "word";
  const end = () => {
    if (!started) return;
    if (into === "word") words.push(word);
    else if (into === "redirect") redirects.push(word);
    into = "word";
    word = "";
    started = false;
  };
  for (let index = 0; index < line.length; index++) {
    const char = line[index]!;
    if (quote) {
      if (char === quote) quote = undefined;
      // In double quotes a backslash escapes only $ ` " \ and a line break; elsewhere it stays.
      else if (char === "\\" && quote === '"' && /[$`"\\\n]/.test(line[index + 1] ?? "")) word += line[++index];
      else word += char;
    } else if (char === "'" || char === '"') {
      quote = char;
      started = true;
    } else if (char === "\\" && index + 1 < line.length) {
      word += line[++index];
      started = true;
    } else if (/\s/.test(char)) {
      end();
    } else if (char === ">" || char === "<") {
      // `2>`: the digits before a redirect name a descriptor, not a word.
      if (started && /^\d+$/.test(word)) {
        word = "";
        started = false;
      }
      end();
      if (line[index + 1] === char) index++;
      if (line[index + 1] === "&") {
        index++;
        into = "skip";
      } else into = char === ">" ? "redirect" : "skip";
    } else if (char === "&" && line[index + 1] === ">") {
      end();
    } else {
      word += char;
      started = true;
    }
  }
  end();
  return { words, redirects };
}

/// A step's words, without its redirects.
export function shellWords(line: string): string[] {
  return parseStep(line).words;
}
