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
 * lines (`$ ` or `% `), without the prompt and without the output lines. Empty when nothing runs.
 */
export function runnableCommand(language: string, text: string): string {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  if (!SESSION_LANGUAGES.has(fenceLanguage(language))) return lines.join("\n").trim();
  const commands: string[] = [];
  let continued = false;
  for (const line of lines) {
    const prompt = /^\s*[$%#]\s+(.*)$/.exec(line);
    if (prompt || continued) {
      const command = prompt ? prompt[1]! : line;
      commands.push(command);
      continued = /\\\s*$/.test(command);
    }
  }
  return commands.join("\n").trim();
}

/** Why the agent, or the Run button, asks before a step runs. */
export type StepRisk = "destructive" | "credentials" | "decision";

/** Commands that delete, overwrite, force, deploy or run code fetched from the network. A tool's
 * global flags may stand before its subcommand (`kubectl --context prod delete`): `[^\n;&|]*\s`
 * spans them, never past the command's end. */
const DESTRUCTIVE: RegExp[] = [
  /(^|[\s;&|(])rm\s+(-[a-z]*[rf][a-z]*\b|--recursive|--force)/i,
  /(^|[\s;&|(])sudo\s/,
  /\bgit\b[^\n;&|]*\s(reset\s+--hard|clean\s+-[a-z]*f|push\b[^\n;&|]*\s(--force(-with-lease)?|-f)\b|branch\s+-D\b|checkout\s+--\s+\.|restore\s+\.|stash\s+(drop|clear))/,
  /\b(drop|truncate)\s+(table|database|schema)\b/i,
  /\bdelete\s+from\b/i,
  /\b(kubectl|oc)\b[^\n;&|]*\s(delete|drain|replace\b[^\n;&|]*--force)\b/,
  /\bhelm\b[^\n;&|]*\s(uninstall|delete)\b/,
  /\bterraform\b[^\n;&|]*\s(destroy\b|apply\b[^\n;&|]*-auto-approve)/,
  /\bdocker\b[^\n;&|]*\s(system\s+prune|volume\s+(rm|prune)|rm\s+-f|rmi\b)/,
  /\baws\b[^\n;&|]*\ss3\s+(rm|rb)\b|\bgsutil\b[^\n;&|]*\srm\b|\bgcloud\b[^\n;&|]*\sdelete\b/,
  /(^|[\s;&|(])(dd\s+.*\bof=|mkfs(\.\w+)?\s|fdisk\s|diskutil\s+erase)/,
  /(^|[\s;&|(])(shutdown|reboot|halt)(\s|$)/,
  /(^|[\s;&|(])(kill\s+-9|pkill|killall)\s/,
  /(^|[\s;&|(])chmod\s+-R\s|(^|[\s;&|(])chown\s+-R\s/,
  /\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|fi)?sh\b/,
  /\b(npm|pnpm|yarn|cargo)\b[^\n;&|]*\spublish\b|\bgh\b[^\n;&|]*\srelease\s+create\b/,
  /(^|[\s;&|(])deploy\b|\b(wrangler|fly|flyctl|vercel)\b[^\n;&|]*\s(deploy|destroy|--prod)\b/,
];

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
  if (DESTRUCTIVE.some((pattern) => pattern.test(command))) risks.push("destructive");
  if (CREDENTIALS.some((pattern) => pattern.test(command))) risks.push("credentials");
  if (DECISION.test(lead)) risks.push("decision");
  return risks;
}

/** Whether the Run button asks before it sends this command (destructive commands always ask). */
export function runAsks(command: string): boolean {
  return stepRisks(command).includes("destructive");
}

/** Whether a Markdown source has a runnable step (the toolbar's Run all shows only then). */
export function hasRunbookSteps(source: string): boolean {
  return parseRunbook(source).length > 0;
}

/** One runnable block of a runbook. */
export interface RunbookStep {
  /** 1-based, in document order. */
  index: number;
  /** The nearest heading above the block ("" before the first heading). */
  section: string;
  /** The paragraph just above the block, flattened to one line (at most `LEAD_LIMIT` characters). */
  lead: string;
  language: string;
  command: string;
  /** The 1-based line of the opening fence. */
  line: number;
  risks: StepRisk[];
}

const LEAD_LIMIT = 240;

/**
 * The runnable steps of a Markdown source: its fenced shell blocks with a command, in order. One
 * pass over the lines, so a long doc costs a scan and nothing per render. A fence opens at most
 * three spaces past its container (the page, or the list item it is in), as CommonMark reads it:
 * a line indented further is an indented code block's text, which the viewer shows without Run.
 */
export function parseRunbook(source: string): RunbookStep[] {
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  const steps: RunbookStep[] = [];
  let section = "";
  let paragraph: string[] = [];
  // Where the content of the list item the scan is in starts (null outside a list).
  let listContent: number | null = null;
  for (let at = 0; at < lines.length; at++) {
    const line = lines[at]!;
    const indent = line.length - line.trimStart().length;
    if (line.trim()) {
      const item = /^(\s*)([-*+]|\d{1,9}[.)])(\s+)\S/.exec(line);
      if (item && (listContent === null ? item[1]!.length <= 3 : item[1]!.length < listContent + 4))
        listContent = item[1]!.length + item[2]!.length + item[3]!.length;
      else if (listContent !== null && indent < listContent && (!lines[at - 1]?.trim() || /^\s{0,3}#/.test(line)))
        listContent = null;
    }
    const container = listContent !== null && indent >= listContent ? listContent : 0;
    const fence = /^(\s*)(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence && indent - container <= 3 && !(fence[2]![0] === "`" && fence[3]!.includes("`"))) {
      const [, indent, marker, info] = fence;
      const body: string[] = [];
      const start = at;
      for (at++; at < lines.length; at++) {
        const closing = /^\s*(`{3,}|~{3,})\s*$/.exec(lines[at]!);
        if (closing && closing[1]![0] === marker![0] && closing[1]!.length >= marker!.length) break;
        body.push(lines[at]!.startsWith(indent!) ? lines[at]!.slice(indent!.length) : lines[at]!.trimStart());
      }
      const language = fenceLanguage(info!);
      const command = isRunnableLanguage(language) ? runnableCommand(language, body.join("\n")) : "";
      if (command) {
        const lead = flatten(paragraph.join(" "));
        steps.push({
          index: steps.length + 1,
          section,
          lead,
          language,
          command,
          line: start + 1,
          risks: stepRisks(command, lead),
        });
      }
      paragraph = [];
      continue;
    }
    const heading = /^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$/.exec(line);
    if (heading) {
      section = flatten(heading[1]!);
      paragraph = [];
    } else if (!line.trim()) {
      // A blank line ends a paragraph only once the next one starts.
    } else {
      if (at > 0 && !lines[at - 1]!.trim()) paragraph = [];
      paragraph.push(line.trim());
    }
  }
  return steps;
}

/** Markdown inline syntax out, whitespace folded, cut at `LEAD_LIMIT`. */
function flatten(text: string): string {
  const plain = text
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*_]{1,2}([^*_]+)[*_]{1,2}/g, "$1")
    .replace(/^\s*([-*+]|\d+[.)])\s+/, "")
    .replace(/\s+/g, " ")
    .trim();
  return plain.length > LEAD_LIMIT ? `${plain.slice(0, LEAD_LIMIT - 1)}…` : plain;
}

/** The most step text one Run all prompt carries; past it the agent reads the rest from the file. */
const PROMPT_STEPS_LIMIT = 48_000;

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
    const fence = step.command.includes("```") ? "~~~~" : "```";
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
    if (entry.length > budget) {
      listed.push(`(Steps ${step.index} to ${total} are in the file: read them there.)`);
      break;
    }
    budget -= entry.length + 2;
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
