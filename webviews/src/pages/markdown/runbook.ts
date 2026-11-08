// Runbooks: a Markdown file's fenced shell blocks as steps someone can run. A Run button on a shell
// block sends its command to a new terminal in the doc's repository (`cmux.markdown.runBlock`);
// Run all hands the whole runbook to an agent chat there (`cmux.markdown.runAll`) with a prompt
// that makes the agent run the steps in order, check each step's output, keep a "Step N of M"
// checklist, and stop to ask at every decision, destructive command or credential. Everything here
// is pure: the page and the tests share it, and nothing runs without the person's click.

/** Fence languages whose blocks are shell commands. `console` blocks carry prompts and output. */
const SHELL_LANGUAGES = new Set(["sh", "bash", "zsh", "shell", "fish", "ksh", "console", "shellsession", "terminal"]);
/** Languages whose lines mix `$ command` prompts and the command's output. */
const SESSION_LANGUAGES = new Set(["console", "shellsession", "terminal"]);

/** The fence info string's language (`bash`, `bash title="x"` and `{bash}` all give `bash`). */
export function fenceLanguage(info: string): string {
  return (
    info
      .trim()
      .replace(/^\{\.?/, "")
      .split(/[\s{},]/)[0]
      ?.toLowerCase() ?? ""
  );
}

/** Whether a code block of this fence language gets a Run button. */
export function isRunnableLanguage(language: string): boolean {
  return SHELL_LANGUAGES.has(fenceLanguage(language));
}

/**
 * The command a block runs: its text as written, or for a session block (`console`) only its prompt
 * lines (`$ ` or `% `), without the prompt and without the output lines. A line counts as more of the
 * command only while the shell would still read it: after a trailing `\\`, in an open quote or
 * heredoc (the line as shown, its `> ` continuation prompt dropped so it never runs as a
 * redirection), and after a trailing `|`, `||` or `&&` or in an open `if`, `for`, `case` or `{`
 * (only a `> ` prompt line: a real transcript shows one there). Any other line is output. Empty when
 * nothing runs.
 */
export function runnableCommand(language: string, text: string): string {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  if (!SESSION_LANGUAGES.has(fenceLanguage(language))) return lines.join("\n").trim();
  const commands: string[] = [];
  let open = CLOSED;
  for (const line of lines) {
    const prompted = /^\s*>\s?(.*)$/.exec(line);
    const continued =
      open.quote !== null || open.heredocs.length > 0 || open.escaped || ((open.pipe || open.depth > 0) && !!prompted);
    const prompt = continued ? null : /^\s*[$%]\s+(.*)$/.exec(line);
    if (!prompt && !continued) {
      open = CLOSED;
      continue;
    }
    const command = prompt ? prompt[1]! : prompted ? prompted[1]! : line;
    commands.push(command);
    open = shellOpen(command, prompt ? CLOSED : open);
  }
  return commands.join("\n").trim();
}

/** What a shell still waits for after a line: the end of a quote or of a heredoc, a next line after a
 * `\\` or an operator, or the end of `depth` open compound commands. */
interface ShellOpen {
  quote: "'" | '"' | null;
  /** The delimiters of the heredocs still open, first to close first. */
  heredocs: readonly string[];
  escaped: boolean;
  pipe: boolean;
  depth: number;
  /** After a `\\`: whether the next line's first word is in command position. */
  position: boolean;
}

const CLOSED: ShellOpen = { quote: null, heredocs: [], escaped: false, pipe: false, depth: 0, position: true };
/** Reserved words in command position that open and close a compound command (a loop opens at its
 * keyword, so `do` may stand on the next line), and those after which the next word is again in
 * command position. */
const OPENS = new Set(["if", "case", "for", "while", "until", "select", "{"]);
const CLOSES = new Set(["fi", "esac", "done", "}"]);
const LEADS = new Set(["then", "else", "elif", "do", "while", "until", "if", "!", "{", "time"]);

function shellOpen(line: string, before: ShellOpen): ShellOpen {
  // A heredoc line is its body. Trimmed, it may close a little early (the shell would wait then), never late.
  if (before.heredocs.length > 0)
    return { ...before, heredocs: line.trim() === before.heredocs[0] ? before.heredocs.slice(1) : before.heredocs };
  let quote = before.quote;
  const heredocs = [...before.heredocs];
  let depth = before.depth;
  let escaped = false;
  // The current unquoted word, whether a word may be a reserved word here, and the last operator.
  let word = "";
  let plain = true;
  // A `\\` continuation goes on where the line before stopped; any other line starts a command.
  let commandPosition = before.escaped ? before.position : quote === null;
  let last = "";
  const endWord = () => {
    if (word && plain && commandPosition) {
      if (OPENS.has(word)) depth++;
      else if (CLOSES.has(word)) depth = Math.max(0, depth - 1);
    }
    if (word) commandPosition = commandPosition && plain && LEADS.has(word);
    word = "";
    plain = true;
  };
  for (let at = 0; at < line.length; at++) {
    const char = line[at]!;
    if (quote === "'") {
      if (char === "'") quote = null;
      continue;
    }
    if (char === "\\") {
      // A `\\` that ends the line continues it; any other escapes the next character.
      if (at === line.length - 1) escaped = true;
      at++;
      plain = false;
      word += "x";
      last = "";
      continue;
    }
    if (quote === '"') {
      if (char === '"') quote = null;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      plain = false;
      word += "x";
      last = "";
    } else if (char === "#" && !word) {
      // A comment runs to the line's end: nothing in it continues the line.
      break;
    } else if (char === "<" && line[at + 1] === "<") {
      endWord();
      // `<<<` is a here-string, not a heredoc.
      if (line[at + 2] === "<") at += 2;
      else {
        const delimiter = heredocWord(line, at + (line[at + 2] === "-" ? 3 : 2));
        if (delimiter) {
          heredocs.push(delimiter.word);
          at = delimiter.end - 1;
        } else at++;
      }
      last = "";
    } else if (/\s/.test(char)) endWord();
    else if (";&|()".includes(char)) {
      endWord();
      commandPosition = char !== ")";
      last = char === "&" && line[at + 1] === "&" ? "&&" : char === "|" ? "|" : char;
      if (last === "&&" || (char === "|" && line[at + 1] === "|")) at++;
    } else {
      word += char;
      last = "";
    }
  }
  endWord();
  return {
    quote,
    heredocs,
    escaped: quote === null && escaped,
    pipe: quote === null && !escaped && (last === "|" || last === "&&"),
    depth,
    position: commandPosition,
  };
}

/** A heredoc's delimiter after its `<<` (from `from`): the whole shell word, its quotes and `\\`
 * escapes removed, up to unquoted whitespace or an operator; `end` is the index after it. Null when no
 * word follows (the shell's syntax error), so nothing is read as a body. */
function heredocWord(line: string, from: number): { word: string; end: number } | null {
  let at = from;
  while (line[at] === " " || line[at] === "\t") at++;
  let word = "";
  let quote: string | null = null;
  for (; at < line.length; at++) {
    const char = line[at]!;
    if (quote) {
      if (char === quote) quote = null;
      else if (char === "\\" && quote === '"' && at + 1 < line.length) word += line[++at];
      else word += char;
    } else if (char === "'" || char === '"') quote = char;
    else if (char === "\\" && at + 1 < line.length) word += line[++at];
    else if (/[\s;&|<>()]/.test(char)) break;
    else word += char;
  }
  return word && !quote ? { word, end: at } : null;
}

/** Why the agent, or the Run button, asks before a step runs. */
export type StepRisk = "destructive" | "credentials" | "decision";

/** Where a command word starts: the line's start, a separator, a subshell, a quote (the body of a
 * wrapper: `bash -c 'rm -rf build'`), or a path or escape before it (`/bin/rm`, `\\rm`). */
const AT = String.raw`(?:^|[\s;&|(){}'"\x60/\\])`;
/** Any options or words before a subcommand or flag, never past the command's end. */
const ARGS = String.raw`(?:[^\n;&|]*\s)?`;
const pattern = (source: string, flags = "") => new RegExp(source, flags);
/** A shell or interpreter at the start of a pipe's next command, after any `sudo` or `env` and their
 * options or assignments, by name, path or escape (`sh`, `/bin/bash`, `\\sh`, `sudo -E python3`). */
const INTERPRETER = String.raw`(?:\S*/|\\)?(?:(?:ba|z|fi|da|k|tc|c|a)?sh|python[\d.]*|perl|ruby|node|bun|deno|php)\b`;

/** Commands that delete, overwrite, force, deploy or run code fetched from the network. A tool's
 * global flags and options may stand anywhere before the word that makes it destructive
 * (`kubectl --context prod delete`, `git reset --quiet --hard`). Matching is a reader's net, not a
 * sandbox: an obfuscated command (`eval "$(echo … | base64 -d)"`) is not caught, and every Run is
 * still the person's own click on a command they can read. */
const DESTRUCTIVE: RegExp[] = [
  pattern(String.raw`${AT}rm\s+${ARGS}(-[a-zA-Z]*[rRf][a-zA-Z]*\b|--recursive|--force)`),
  pattern(String.raw`${AT}(sudo|doas)\s`),
  pattern(
    String.raw`${AT}git\s+${ARGS}(reset\s+${ARGS}--hard|clean\s+${ARGS}-[a-zA-Z]*f|push\s+${ARGS}(--force(-with-lease)?\b|-[a-zA-Z]*f\b|\+\S)|branch\s+${ARGS}-D\b|checkout\s+${ARGS}(--\s+)?\.(\s|$)|restore\s+${ARGS}\.(\s|$)|stash\s+(drop|clear)|filter-branch|update-ref\s+-d)`,
  ),
  /\b(drop|truncate)\s+(table|database|schema)\b/i,
  /\bdelete\s+from\b/i,
  pattern(String.raw`${AT}(kubectl|oc)\s+${ARGS}(delete|drain|replace\s+${ARGS}--force)\b`),
  pattern(String.raw`${AT}helm\s+${ARGS}(uninstall|delete)\b`),
  pattern(String.raw`${AT}terraform\s+${ARGS}(destroy\b|apply\s+${ARGS}-auto-approve)`),
  pattern(String.raw`${AT}docker\s+${ARGS}(system\s+prune|volume\s+(rm|prune)|rm\s+${ARGS}-[a-zA-Z]*f|rmi\b)`),
  pattern(String.raw`${AT}(aws\s+${ARGS}s3\s+(rm|rb)|gsutil\s+${ARGS}rm|gcloud\s+${ARGS}delete)\b`),
  pattern(String.raw`${AT}(dd\s+.*\bof=|mkfs(\.\w+)?\s|fdisk\s|diskutil\s+erase|shred\s|truncate\s+-s)`),
  pattern(String.raw`${AT}(shutdown|reboot|halt)(\s|$)`),
  pattern(String.raw`${AT}(kill\s+${ARGS}-(9|KILL)\b|pkill|killall)\s`),
  pattern(String.raw`${AT}(chmod|chown)\s+${ARGS}-[a-zA-Z]*R`),
  pattern(String.raw`${AT}find\s+${ARGS}(-delete\b|-exec\s+rm\b)`),
  // Fetched code run without a pipe: `bash <(curl …)`, `sh -c "$(curl …)"`, `eval "$(wget …)"`.
  pattern(String.raw`${AT}(?:${INTERPRETER}|eval|source|\.)\s[^\n]{0,64}?(?:<\(|\$\(|\x60)\s*(?:curl|wget)\b`),
  pattern(String.raw`${AT}(npm|pnpm|yarn|cargo)\s+${ARGS}publish\b|${AT}gh\s+${ARGS}release\s+(create|delete)\b`),
  pattern(String.raw`${AT}deploy\b|${AT}(wrangler|fly|flyctl|vercel)\s+${ARGS}(deploy|destroy|--prod)\b`),
];

/** The longest simple command the patterns read; a longer one always asks (the patterns backtrack
 * over its words, so a bound keeps the check off the frame budget). */
const SEGMENT_LIMIT = 512;

/** Whether `command` is destructive: each simple command (split at newlines and `;`, `&`, `|`) is
 * matched on its own, and a pipe into a shell over the whole command. */
function destructive(command: string): boolean {
  // Each `|` once: the part before it fetches (`curl`, `wget` on its last line), the part after runs a shell.
  const piped = command.split("|");
  for (let at = 1; at < piped.length; at++) {
    const before = piped[at - 1]!;
    if (
      SHELL_AFTER_PIPE.test(piped[at]!) &&
      FETCH.test(before.slice(before.lastIndexOf("\n") + 1).slice(-SEGMENT_LIMIT))
    )
      return true;
  }
  if (command.split(/[\n;&|]/).some((segment) => segment.length > SEGMENT_LIMIT)) return true;
  for (const segment of segments(command)) {
    if (DESTRUCTIVE.some((pattern) => pattern.test(segment))) return true;
  }
  return false;
}

/** The simple commands of `command` the patterns read (a longer one already asks as destructive). */
function segments(command: string): string[] {
  return command.split(/[\n;&|]/).filter((segment) => segment.length <= SEGMENT_LIMIT);
}

/** Code fetched from the network (`curl … | sh`), run by a shell. */
const FETCH = /\b(curl|wget)\b/;
const SHELL_AFTER_PIPE = pattern(
  String.raw`^\s*(?:(?:\S*/)?(?:sudo|doas|env|command|exec|nohup)\s+(?:-\S*\s+|\w+=\S*\s+)*)*${INTERPRETER}`,
);

/** Commands that log in, take a secret, or carry a placeholder the reader fills in. */
const CREDENTIALS: RegExp[] = [
  /\b(login|auth\s+login)\b|\baws\s+configure\b/,
  /\b[A-Z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|ACCESS_KEY|PRIVATE_KEY)\b/,
  /--(password|token|secret)\b/i,
  /<[A-Za-z][\w -]*>|\{\{\s*\w+\s*\}\}|\bYOUR_[A-Z_]+\b/,
];

/** Prose that leaves a choice to the reader ("if this prints X, run Y"). */
const DECISION = /\b(if|unless|otherwise|depending|choose|either|whether|in case|only when|make sure)\b/i;

/** The risks of one step: its command, and the prose that leads into it. */
export function stepRisks(command: string, lead = ""): StepRisk[] {
  const risks: StepRisk[] = [];
  // A `\\` line continuation joins one command (`git push \\` then `--force`): match it as one line.
  command = command.replace(/\\\r?\n\s*/g, " ");
  if (destructive(command)) risks.push("destructive");
  if (segments(command).some((segment) => CREDENTIALS.some((pattern) => pattern.test(segment))))
    risks.push("credentials");
  if (DECISION.test(lead)) risks.push("decision");
  return risks;
}

/** Whether the Run button asks before it sends this command (destructive commands always ask). */
export function runAsks(command: string): boolean {
  return stepRisks(command).includes("destructive");
}

/** One runnable block of a runbook. */
export interface RunbookStep {
  /** 1-based, in document order. */
  index: number;
  /** The nearest heading above the block ("" before the first heading). */
  section: string;
  /** The paragraph just above the block, on one line (at most `LEAD_LIMIT` characters). */
  lead: string;
  language: string;
  command: string;
  /** The 1-based source line of the block's opening fence. */
  line: number;
  risks: StepRisk[];
}

const LEAD_LIMIT = 240;

/** What the viewer holds of one code block: the editor reads these from its own document, so Run
 * all has exactly the blocks that show Run (MarkdownEditor.runbookSteps). */
export interface RunbookBlock {
  section: string;
  lead: string;
  language: string;
  text: string;
  line: number;
}

/** The steps of a document's code blocks: the shell blocks with a command, numbered in order. */
export function runbookSteps(blocks: Iterable<RunbookBlock>): RunbookStep[] {
  const steps: RunbookStep[] = [];
  for (const block of blocks) {
    const language = fenceLanguage(block.language);
    const command = isRunnableLanguage(language) ? runnableCommand(language, block.text) : "";
    if (!command) continue;
    const lead = oneLine(block.lead);
    steps.push({
      index: steps.length + 1,
      section: oneLine(block.section),
      lead,
      language,
      command,
      line: block.line,
      risks: stepRisks(command, lead),
    });
  }
  return steps;
}

/** Whitespace folded, cut at `LEAD_LIMIT`. */
function oneLine(text: string): string {
  const plain = text.replace(/\s+/g, " ").trim();
  return plain.length > LEAD_LIMIT ? `${plain.slice(0, LEAD_LIMIT - 1)}…` : plain;
}

/** The most step text, in UTF-8 bytes (the host's unit), one Run all prompt carries; past it the
 * agent reads the rest from the file. With the contract it stays far under the host's 128 KiB. */
const PROMPT_STEPS_LIMIT = 48_000;
const utf8 = new TextEncoder();

const RISK_NOTE: Record<StepRisk, string> = {
  destructive: "destructive",
  credentials: "needs credentials",
  decision: "a decision in the doc",
};

/**
 * The Run all prompt: the runbook as a numbered step list and the contract the agent follows. The
 * agent starts in the doc's repository and reads the file itself for the prose, so the prompt stays
 * bounded however long the doc is.
 */
export function runbookPrompt(path: string, steps: readonly RunbookStep[]): string {
  const total = steps.length;
  const listed: string[] = [];
  let budget = PROMPT_STEPS_LIMIT;
  for (const step of steps) {
    const where = [step.section, `line ${step.line}`].filter(Boolean).join(", ");
    const asks = step.risks.length ? ` ASK FIRST (${step.risks.map((risk) => RISK_NOTE[risk]).join(", ")})` : "";
    // A backtick fence longer than any backtick run in the command, so no line of it closes the fence.
    let longest = 2;
    for (const run of step.command.matchAll(/`+/g)) longest = Math.max(longest, run[0].length);
    const fence = "`".repeat(longest + 1);
    const entry = [
      `${step.index}. Step ${step.index} of ${total} (${where})${asks}`,
      step.lead ? `   The doc says: ${step.lead}` : "",
      `${fence}${step.language}`,
      step.command,
      fence,
    ]
      .filter(Boolean)
      .join("\n");
    // The whole entry counts, so many short steps stay as bounded as a few long ones. A first
    // step too long for the budget is left to the file too.
    const bytes = utf8.encode(entry).length;
    if (bytes > budget) {
      listed.push(`(Steps ${step.index} to ${total} are in the file: read them there.)`);
      break;
    }
    budget -= bytes + 2;
    listed.push(entry);
  }
  return [
    `Run this runbook for me, step by step: ${path}`,
    "",
    "Read the whole file first for context. You start in its repository. It has these steps, in order:",
    "",
    listed.join("\n\n"),
    "",
    "How to run it:",
    `- Keep a checklist with your plan tool: one item per step, titled "Step N of ${total}: <what it does>". Mark each one done when its check passes.`,
    "- Run the steps in a terminal, in order, exactly as written. Do not skip, reorder or combine steps, and run nothing the doc does not say.",
    "- After each step, read its output and check it did what the doc says it should. Say in one line what you checked.",
    '- Stop and ask me with your question tool (one question, concrete options) before: any step marked ASK FIRST; anything that deletes, overwrites, force-pushes, publishes, deploys or touches production; anything that needs a login, a credential or a secret (never guess or invent one, and never print one); and every judgment call the doc leaves to the reader, such as "if this prints X, do Y".',
    "- When a step fails, stop. Explain the failure in the doc's terms: which step, what the doc expected, what happened, and the likely cause. Propose a fix and ask before you run anything the doc does not say.",
    `- End with a short report: how far you got (step N of ${total}), what passed, and what is left.`,
  ].join("\n");
}
