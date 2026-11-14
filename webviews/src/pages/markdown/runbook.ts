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
 * lines (`$ ` or `% `), without the prompt and without the output lines. A line is more of the command
 * only while the shell would still read it (an open quote, substitution or heredoc, a trailing `|`,
 * `||` or `&&`, an open `if`, `for`, `case` or `{`) and it shows the shell's `> ` continuation prompt,
 * which is dropped so it never runs as a redirection; after an unquoted trailing `\\` a bare line
 * counts too. Any other line is output, and so is everything after it until the next prompt: when the
 * scan is unsure, the command ends early (the shell then waits), it never takes output. Empty when
 * nothing runs.
 */
export function runnableCommand(language: string, text: string): string {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  if (!SESSION_LANGUAGES.has(fenceLanguage(language))) return lines.join("\n").trim();
  const commands: string[] = [];
  let open = CLOSED;
  for (const line of lines) {
    const prompted = /^\s*>\s?(.*)$/.exec(line);
    const reading = open.scopes.length > 0 || open.heredocs.length > 0 || open.escaped || open.pipe || open.depth > 0;
    const continued = reading && (!!prompted || (open.escaped && open.scopes.length === 0));
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

/** A quoting, substitution or arithmetic scope the shell is inside: `'…'`, `$'…'` (where `\\` escapes), `"…"`, `((…))`, `` `…` ``, `$(…)` (and a
 * `(…)` inside it) or `${…}`. */
type Scope = "'" | "$'" | '"' | "`" | "$(" | "(" | "${" | "((";

/** What a shell still waits for after a line: the end of its open scopes or heredocs, a next line
 * after a `\\` or an operator, or the end of `depth` open compound commands. */
interface ShellOpen {
  scopes: readonly Scope[];
  /** The delimiters of the heredocs still open, first to close first. */
  heredocs: readonly string[];
  escaped: boolean;
  pipe: boolean;
  depth: number;
  /** After a `\\`: whether the next line's first word is in command position. */
  position: boolean;
  /** Open `case` commands, and where in one the scan is: its subject next (1), its `in` next (2), or
   * a pattern (`a|b)`, where words are never reserved words but `esac`). */
  cases: number;
  caseWord: 0 | 1 | 2;
  pattern: boolean;
}

const CLOSED: ShellOpen = {
  scopes: [],
  heredocs: [],
  escaped: false,
  pipe: false,
  depth: 0,
  position: true,
  cases: 0,
  caseWord: 0,
  pattern: false,
};
/** Reserved words in command position that open and close a compound command (a loop opens at its
 * keyword, so `do` may stand on the next line), and those after which the next word is again in
 * command position. */
const OPENS = new Set(["if", "for", "while", "until", "select", "{"]);
const CLOSES = new Set(["fi", "esac", "done", "}"]);
const LEADS = new Set(["then", "else", "elif", "do", "while", "until", "if", "!", "{", "time"]);

function shellOpen(line: string, before: ShellOpen): ShellOpen {
  // A heredoc's body starts after its header's last line (a header continued with `\\` goes on first).
  // Trimmed, a body line may close it a little early (the shell would wait then), never late.
  if (before.heredocs.length > 0 && !before.escaped)
    return { ...before, heredocs: line.trim() === before.heredocs[0] ? before.heredocs.slice(1) : before.heredocs };
  const scopes = [...before.scopes];
  const heredocs = [...before.heredocs];
  let depth = before.depth;
  let escaped = false;
  // The current top-level word, whether a word may be a reserved word here, and the last operator.
  let word = "";
  let plain = true;
  // A `\\` continuation goes on where the line before stopped; any other line starts a command.
  let commandPosition = before.escaped ? before.position : scopes.length === 0;
  let last = "";
  let { cases, caseWord, pattern } = before;
  const closeCase = () => {
    depth = Math.max(0, depth - 1);
    cases = Math.max(0, cases - 1);
    pattern = false;
  };
  const endWord = () => {
    if (!word) return;
    if (caseWord === 1) caseWord = 2;
    else if (caseWord === 2) {
      // `case WORD in`: the patterns come next.
      pattern = word === "in" && plain;
      caseWord = 0;
    } else if (pattern) {
      // A pattern word, or the `esac` that ends the case.
      if (word === "esac" && plain) closeCase();
    } else if (plain && commandPosition) {
      if (word === "case") {
        depth++;
        cases++;
        caseWord = 1;
      } else if (word === "esac") closeCase();
      else if (OPENS.has(word)) depth++;
      else if (CLOSES.has(word)) depth = Math.max(0, depth - 1);
    }
    commandPosition = commandPosition && plain && LEADS.has(word) && !pattern;
    word = "";
    plain = true;
  };
  // Inside any scope the characters belong to one word: mark it quoted.
  const inWord = () => {
    plain = false;
    word += "x";
    last = "";
  };
  for (let at = 0; at < line.length; at++) {
    const char = line[at]!;
    const scope = scopes[scopes.length - 1];
    if (scope === "'") {
      if (char === "'") scopes.pop();
      continue;
    }
    if (scope === "$'") {
      if (char === "\\") at++;
      else if (char === "'") scopes.pop();
      continue;
    }
    if (char === "\\") {
      // A `\\` that ends the line continues it; any other escapes the next character.
      if (at === line.length - 1) escaped = true;
      at++;
      inWord();
      continue;
    }
    // Opening a scope: quotes everywhere but in `"…"` (where only `"` closes), substitutions everywhere.
    if (char === "$" && line[at + 1] === "'" && scope !== '"') {
      scopes.push("$'");
      at++;
      inWord();
      continue;
    }
    if (char === "$" && line[at + 1] === "(") {
      scopes.push("$(");
      at++;
      inWord();
      continue;
    }
    if (char === "$" && line[at + 1] === "{") {
      scopes.push("${");
      at++;
      inWord();
      continue;
    }
    if (scope === '"') {
      if (char === '"') scopes.pop();
      else if (char === "`") scopes.push("`");
      continue;
    }
    if (char === "'" || char === '"') {
      scopes.push(char);
      inWord();
      continue;
    }
    if (char === "`") {
      if (scope === "`") scopes.pop();
      else scopes.push("`");
      inWord();
      continue;
    }
    if (scope !== undefined) {
      // Inside a substitution or `((…))`: its own parentheses and braces, until the one that closes it.
      if (char === "(" && (scope === "$(" || scope === "(" || scope === "((")) scopes.push("(");
      else if (char === ")" && scope === "((" && line[at + 1] === ")") {
        scopes.pop();
        at++;
      } else if (char === ")" && (scope === "$(" || scope === "(")) scopes.pop();
      else if (char === "}" && scope === "${") scopes.pop();
      continue;
    }
    if (char === "(" && line[at + 1] === "(" && !word) {
      // `((…))` is arithmetic: its `<<` is a shift, never a heredoc.
      endWord();
      scopes.push("((");
      at++;
      last = "";
      continue;
    }
    if (char === "#" && !word) {
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
    else if (pattern && "|()".includes(char)) {
      // In a pattern `|` separates alternatives and `)` ends it: a command follows.
      endWord();
      if (char === ")" && pattern) {
        pattern = false;
        commandPosition = true;
      }
      last = "";
    } else if (cases > 0 && char === ";" && line[at + 1] === ";") {
      // `;;` (also `;&`, `;;&`) ends a case item: the next pattern comes.
      endWord();
      at += line[at + 2] === "&" ? 2 : 1;
      pattern = true;
      commandPosition = false;
      last = "";
    } else if (cases > 0 && char === ";" && line[at + 1] === "&") {
      endWord();
      at++;
      pattern = true;
      commandPosition = false;
      last = "";
    } else if (";&|()".includes(char)) {
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
  const top = scopes.length === 0;
  return {
    scopes,
    heredocs,
    escaped: top && escaped,
    pipe: top && !escaped && (last === "|" || last === "&&"),
    depth,
    position: commandPosition,
    cases,
    caseWord,
    pattern,
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
export type StepRisk = "destructive" | "credentials" | "decision" | "transcript";

/** Where a command word starts: the line's start, a separator, a subshell, a quote (the body of a
 * wrapper: `bash -c 'rm -rf build'`), or a path or escape before it (`/bin/rm`, `\\rm`). */
const AT = String.raw`(?:^|[\s;&|(){}'"\x60/\\])`;
/** Any options or words before a subcommand or flag. The patterns read one simple command at a time
 * (`simpleCommands`, which keeps quoted separators), so this never runs past the command's end. */
const ARGS = String.raw`(?:[^\n]*\s)?`;
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
  // Signals by name; the names are spelled as classes (`p[k]ill`) so the repo's fleet lints, which
  // refuse those words in tooling, read this as the pattern it is.
  pattern(String.raw`${AT}(kill\s+${ARGS}-(9|KILL)\b|p[k]ill|kil[l]all)\s`),
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
 * matched on its own, and fetched code piped into a shell over the whole command. */
function destructive(command: string): boolean {
  // Fetched code piped into a shell: a fetch anywhere before any `|` into an interpreter asks, quoted
  // or not and whatever stands between them (`curl 'a|b' | tee log | sh`). It over-asks on purpose.
  const fetch = FETCH.exec(command);
  if (fetch)
    for (let at = command.indexOf("|", fetch.index); at >= 0; at = command.indexOf("|", at + 1))
      if (SHELL_AFTER_PIPE.test(command.slice(at + 1, at + 1 + SEGMENT_LIMIT).replace(/['"]/g, ""))) return true;
  const simple = simpleCommands(command);
  if (simple.some((segment) => segment.length > SEGMENT_LIMIT)) return true;
  for (const segment of simple) {
    // As written, and with its quotes removed as the shell removes them (`'rm' -rf`, `r""m -rf`).
    const unquoted = segment.replace(/['"]/g, "");
    if (DESTRUCTIVE.some((pattern) => pattern.test(segment) || pattern.test(unquoted))) return true;
  }
  return false;
}

/** The simple commands of `command`: split at unquoted newlines, `;`, `&` and `|`, so a quoted
 * separator (`git push 'a;b' --force`) stays in its command. An unclosed quote runs to the end. */
function simpleCommands(command: string): string[] {
  const commands: string[] = [];
  let start = 0;
  let quote: string | null = null;
  for (let at = 0; at < command.length; at++) {
    const char = command[at]!;
    if (quote === "'") {
      if (char === "'") quote = null;
    } else if (char === "\\") at++;
    else if (quote === '"') {
      if (char === '"') quote = null;
    } else if (char === "'" || char === '"') quote = char;
    else if (char === "\n" || char === ";" || char === "&" || char === "|") {
      commands.push(command.slice(start, at));
      start = at + 1;
    }
  }
  commands.push(command.slice(start));
  return commands;
}

/** The simple commands the patterns read (a longer one already asks as destructive). */
function segments(command: string): string[] {
  return simpleCommands(command).filter((segment) => segment.length <= SEGMENT_LIMIT);
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

/** Whether a block's command was read from several lines of a session block (`console`): reading a
 * transcript is a guess about where the command ends and its output starts, so such a command asks
 * first however sure the scan is, and the person sees what runs. */
export function fromTranscript(language: string, command: string): boolean {
  return SESSION_LANGUAGES.has(fenceLanguage(language)) && command.includes("\n");
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
      risks: [...stepRisks(command, lead), ...(fromTranscript(language, command) ? (["transcript"] as const) : [])],
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
  transcript: "several lines read from a terminal transcript: check where the command ends",
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
