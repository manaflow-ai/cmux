// A browser walkthrough an agent ran before it said a UI change was done: the REPL's
// `verifyFlow(port, steps)` (cmux-browser-host js/api.js) clicks through the flow, takes one
// screenshot per step and ends its printed result with one `cmux.walkthrough {json}` line. This
// reads that line back out of the call's output, wherever the call ran (`browser_repl_eval`, a
// `cmux_exec` script, `cmux-browser-host eval` in a shell), so the turn draws the walkthrough as a
// strip under its answer (Walkthrough.tsx) with a pass or fail mark per step.
import type { AcpmuxActivity, AcpmuxRow } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type WalkthroughStep = {
  n: number;
  line: string;
  ok: boolean;
  skipped: boolean;
  error?: string;
  /// The step's screenshot file, when the page could be drawn.
  image?: string;
};

export type Walkthrough = {
  url: string;
  passed: boolean;
  /// Why the flow could not start (no dev server), when it could not.
  error?: string;
  steps: WalkthroughStep[];
};

const MARK = "cmux.walkthrough ";
/// verifyFlow runs at most 12 steps, plus the open it adds.
const MAX_STEPS = 13;
const MAX_LINE = 140;
const MAX_ERROR = 240;
/// `[Image 1280x720 jpeg: /path/run-1.jpg]`, as the REPL prints an image.
const IMAGE = /^\[Image \d+x\d+ \w+: (\/[^\]]+)\]$/;

const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const text = (value: unknown, max: number): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim().slice(0, max) : undefined;

function step(value: unknown, index: number): WalkthroughStep | undefined {
  const raw = record(value);
  const line = raw && text(raw.line, MAX_LINE);
  if (!raw || !line) return undefined;
  const shot = typeof raw.screenshot === "string" ? IMAGE.exec(raw.screenshot)?.[1] : undefined;
  const error = text(raw.error, MAX_ERROR);
  return {
    n: typeof raw.n === "number" ? raw.n : index + 1,
    line,
    ok: raw.ok === true,
    skipped: raw.skipped === true,
    ...(error && { error }),
    ...(shot && { image: shot }),
  };
}

/// The walkthrough a `cmux.walkthrough` line holds, or undefined when it holds none.
export function parseWalkthrough(json: string): Walkthrough | undefined {
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    return undefined;
  }
  const raw = record(value);
  if (!raw || raw.walkthrough !== 1 || !Array.isArray(raw.steps)) return undefined;
  const steps = raw.steps
    .slice(0, MAX_STEPS)
    .map(step)
    .filter((s): s is WalkthroughStep => s !== undefined);
  if (!steps.length) return undefined;
  const error = text(raw.error, MAX_ERROR);
  return {
    url: text(raw.url, 2048) ?? "",
    // Passed only when every step it shows did: a forged `passed` never draws green over a red step.
    passed: raw.passed === true && steps.every((s) => s.ok),
    ...(error && { error }),
    steps,
  };
}

/// The last walkthrough line in some text.
function fromText(output: string): Walkthrough | undefined {
  const at = output.lastIndexOf(MARK);
  if (at < 0) return undefined;
  const end = output.indexOf("\n", at);
  return parseWalkthrough(output.slice(at + MARK.length, end < 0 ? undefined : end));
}

/// How deep the envelope walk goes, counting each JSON string it decodes as a level: an MCP
/// result's `content[].text`, a `cmux_exec` answer's `logs[]` holding the REPL's result as JSON,
/// sit well inside it. Deeper output (any tool can print 5,000 nested arrays) is not looked at.
const MAX_DEPTH = 12;
/// The most values the walk visits, so a wide envelope costs no more than a deep one.
const MAX_VISITS = 4096;

/// The last walkthrough inside a JSON envelope: its strings, and the JSON a string holds (a
/// serialized REPL result in a script's logs), walked without recursion and within both bounds.
function fromEnvelope(root: unknown): Walkthrough | undefined {
  const stack: { value: unknown; depth: number }[] = [{ value: root, depth: 0 }];
  for (let visits = 0; stack.length && visits < MAX_VISITS; visits += 1) {
    const { value, depth } = stack.pop()!;
    if (depth > MAX_DEPTH) continue;
    if (typeof value === "string") {
      if (!value.includes(MARK)) continue;
      const read = fromText(value) ?? decoded(value, depth);
      // Strings are popped last first: the first one read is the output's last walkthrough.
      if (read) return read;
      continue;
    }
    const children = Array.isArray(value)
      ? value
      : value && typeof value === "object"
        ? Object.values(value as Record<string, unknown>)
        : [];
    for (const child of children) stack.push({ value: child, depth: depth + 1 });
  }
  return undefined;

  function decoded(text: string, depth: number): Walkthrough | undefined {
    const trimmed = text.trim();
    if (!/^[[{"]/.test(trimmed)) return undefined;
    try {
      stack.push({ value: JSON.parse(trimmed), depth: depth + 1 });
    } catch {
      // Not JSON: a string that only mentions the mark.
    }
    return undefined;
  }
}

/// The walkthrough a finished call printed, read from its output as it came or from inside the
/// JSON envelope a harness wrapped it in. Cheap for every other call: it looks for the mark first.
/// Never throws: a call's output is any text a tool printed, and turn shaping must not fail on it.
export function toolWalkthrough(tool: Tool | undefined): Walkthrough | undefined {
  const output = tool?.output;
  if (!output || tool.status !== "completed" || !output.includes("cmux.walkthrough")) return undefined;
  try {
    const direct = fromText(output);
    if (direct) return direct;
    const trimmed = output.trim();
    return /^[[{]/.test(trimmed) ? fromEnvelope(JSON.parse(trimmed)) : undefined;
  } catch {
    return undefined;
  }
}

/// The last walkthrough among a turn's rows: the one the turn ends on, after any fix it made.
export function lastWalkthrough(rows: readonly AcpmuxRow[]): Walkthrough | undefined {
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind !== "activity") continue;
    const items = row.items ?? [];
    for (let index = items.length - 1; index >= 0; index -= 1) {
      const found = toolWalkthrough(items[index]!.tool);
      if (found) return found;
    }
  }
  return undefined;
}
