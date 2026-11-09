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

/// Every string in a JSON envelope (an MCP result's `content[].text`), deepest last.
function strings(value: unknown, out: string[]): string[] {
  if (typeof value === "string") out.push(value);
  else if (Array.isArray(value)) for (const item of value) strings(item, out);
  else if (value && typeof value === "object") for (const item of Object.values(value)) strings(item, out);
  return out;
}

/// The walkthrough a finished call printed, read from its output as it came or from inside the
/// JSON envelope a harness wrapped it in. Cheap for every other call: it looks for the mark first.
export function toolWalkthrough(tool: Tool | undefined): Walkthrough | undefined {
  const output = tool?.output;
  if (!output || tool.status !== "completed" || !output.includes("cmux.walkthrough")) return undefined;
  const direct = fromText(output);
  if (direct) return direct;
  let envelope: unknown;
  try {
    envelope = JSON.parse(output);
  } catch {
    return undefined;
  }
  const found = strings(envelope, []).filter((s) => s.includes(MARK));
  return found.length ? fromText(found[found.length - 1]!) : undefined;
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
