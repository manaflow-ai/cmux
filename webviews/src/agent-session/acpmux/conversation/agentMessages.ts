// Tool calls that send a message to another agent: `tell-coordinator`, `cmux send`, a write
// into a mailbox (`inbox/<name>/…`) and Claude Code's SendMessage. The transcript draws them
// as message cards (MessageCard.tsx) instead of raw shell or JSON.
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
  if (input && /send.?message/i.test(tool.title) && typeof input.to === "string") {
    const text = [input.message, input.summary, input.content].find((value) => typeof value === "string");
    return { channel: "agent", to: input.to, text: oneMessage(String(text ?? "")) };
  }
  // A file tool writing into a mailbox: the recipient is the folder under inbox/.
  for (const diff of tool.diffs ?? []) {
    const to = mailboxRecipient(diff.path);
    if (to) return { channel: "mailbox", to, text: oneMessage(diff.newText.slice(diff.oldText?.length ?? 0)) };
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

/// `inbox/<name>/…` or the coordinator's `coordinator-inbox/<name>.jsonl`.
export function mailboxRecipient(path: string): string | undefined {
  return /(?:^|\/)(?:coordinator-)?inbox\/([\w.-]+?)(?:\.jsonl)?(?:\/|$)/.exec(path)?.[1];
}

/// A shell command line's message: its first step that sends one.
export function commandMessage(command: string): AgentMessage | undefined {
  const heredoc = heredocBody(command);
  for (const step of shellSteps(withoutHeredoc(command))) {
    const words = shellWords(step);
    const program = words[0]?.split("/").pop();
    if (program === "tell-coordinator") return coordinatorMessage(words.slice(1), heredoc);
    if ((program === "cmux" || program === "cmux-debug-cli.sh") && words[1] === "send")
      return sendMessage(words.slice(2));
  }
  const mailbox = /(?:>>?|\btee(?:\s+-a)?)\s+["']?(\S*?inbox\/[\w.-]+\S*?)["']?(?:\s|$)/.exec(command);
  const to = mailbox && mailboxRecipient(mailbox[1]!);
  if (to) return { channel: "mailbox", to, text: oneMessage(heredoc ?? echoedText(command) ?? "") };
  return undefined;
}

function coordinatorMessage(args: string[], heredoc: string | undefined): AgentMessage {
  const message: AgentMessage = { channel: "coordinator", to: "coordinator", text: "" };
  const rest: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const word = args[index]!;
    if (word === "--to") message.to = args[++index];
    else if (word === "--from") message.from = args[++index];
    else if (word === "--re") index++;
    else rest.push(word);
  }
  const text = rest.join(" ");
  message.text = oneMessage(text === "-" || !text ? (heredoc ?? "") : text);
  return message;
}

/// `cmux send [--workspace W] [--surface S] TEXT`: typed into another terminal, usually another agent's.
function sendMessage(args: string[]): AgentMessage {
  let workspace: string | undefined;
  let surface: string | undefined;
  const rest: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const word = args[index]!;
    if (word === "--workspace") workspace = args[++index];
    else if (word === "--surface") surface = args[++index];
    else if (!word.startsWith("--")) rest.push(word);
  }
  return { channel: "terminal", to: surface ?? workspace, text: oneMessage(rest.join(" ")) };
}

/// The body of the command's first here-document (`<<'EOF' … EOF`).
function heredocBody(command: string): string | undefined {
  const start = /<<-?\s*(['"]?)(\w+)\1[^\n]*\n/.exec(command);
  if (!start) return undefined;
  const body = command.slice(start.index + start[0].length);
  const end = new RegExp(`^\\s*${start[2]}\\s*$`, "m").exec(body);
  return end ? body.slice(0, end.index) : body;
}

/// The command with its here-document's body cut, so the body's lines are not read as steps.
function withoutHeredoc(command: string): string {
  const start = /<<-?\s*(['"]?)(\w+)\1[^\n]*\n/.exec(command);
  if (!start) return command;
  const rest = command.slice(start.index + start[0].length);
  const end = new RegExp(`^\\s*${start[2]}\\s*$`, "m").exec(rest);
  return command.slice(0, start.index + start[0].length) + (end ? rest.slice(end.index + end[0].length) : "");
}

/// A command line's steps, split at `&&`, `||`, `|`, `;` and line breaks outside quotes.
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
    if (char === ";" || char === "\n" || char === "|" || (char === "&" && command[index + 1] === "&")) {
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

/// What `echo` or `printf` prints in the step that writes the mailbox.
function echoedText(command: string): string | undefined {
  for (const step of shellSteps(withoutHeredoc(command))) {
    const words = shellWords(step);
    if (words[0] === "echo" || words[0] === "printf")
      return words
        .slice(1)
        .filter((word) => !word.startsWith("-"))
        .join(" ");
  }
  return undefined;
}

/// A message's text with line breaks kept and the surrounding blank space trimmed.
function oneMessage(text: string): string {
  return text.replace(/\\n/g, "\n").trim();
}

/// A command line split into words as a POSIX shell reads quotes and backslashes; stops at
/// a redirect or here-document so their targets are not taken as arguments.
export function shellWords(line: string): string[] {
  const words: string[] = [];
  let word = "";
  let quote: "'" | '"' | undefined;
  let started = false;
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
      if (started) words.push(word);
      word = "";
      started = false;
    } else if (char === "<" || char === ">" || char === "|") {
      break;
    } else {
      word += char;
      started = true;
    }
  }
  if (started) words.push(word);
  return words;
}
