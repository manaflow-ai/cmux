// The transcript-at-rest clutter rules: what a row of the agent chat may show with no pointer on it
// and no key focus in it. scripts/gallery/transcript-clutter.ts measures gallery states in Chromium
// and hands each row's measure to `judgeRow`; the rules live here so a unit test pins them.
//
// Leo, 2026-11-11, on a failed subagent row that drew "Ask parent to retry", a ↺, a ⋯ whose menu
// repeated "Ask parent to retry", and "13ms" at rest, and on the edited-files card's Second opinion:
// "this is kind of weird tbh", "why were all these added in the first place?", "holy f*** it's so
// sh***y to look at the transcript right now". Each control was added at rest by its own change and
// nothing counted them; this is the count.

/** A row type of the transcript, the CSS that finds it, and how many controls it may show at rest. */
export type RowType = { name: string; selector: string; budget: number; why: string };

/// The budgets. A control is a visible button, link or menu trigger, the row's own toggle included.
/// A row type nested in another (a tool row inside a subagent row) is counted only as the inner one.
export const ROW_TYPES: readonly RowType[] = [
  {
    name: "subagent row",
    selector: ".cv-subagent-done-row, .cv-subagent-row",
    budget: 2,
    why: "its toggle and one action (Retry); a menu and the rest wait for hover",
  },
  {
    name: "tool row",
    // A subagent's line is drawn with tool-row classes; it is the subagent row's, not a tool row.
    selector:
      ".cv-tool:not(:is(.cv-subagent-done-row, .cv-subagent-row), :is(.cv-subagent-done-row, .cv-subagent-row) *)",
    budget: 1,
    why: "its own toggle; a tool row has no buttons at rest",
  },
  {
    name: "user message",
    selector: ".cv-user",
    budget: 1,
    why: "a Show more at most; Copy, Retry, Fork and the rest show on hover",
  },
  {
    name: "edited-files card",
    selector: ".acpmux-edited",
    budget: 3,
    why: "the latest card's Undo, View changes and chevron; its file rows are content and do not count",
  },
];

/** One row as the page measured it, at rest. */
export type RowMeasure = {
  type: string;
  /** Each visible control's accessible name (aria-label, title or text), as drawn. */
  controls: string[];
  /** The names in a menu one of the row's controls opens (the ⋯ menu), when the runner opened it. */
  menu?: string[];
  /** The row's visible text. */
  text: string;
  /** A running row may show its clock. */
  running: boolean;
};

export type Finding = { rule: "budget" | "duplicate" | "timing"; detail: string };

const name = (label: string) => label.replace(/\s+/g, " ").trim().toLowerCase();

/// A duration as a row writes it: "13ms", "4.2s", "2 s", "1m 05s". Words such as "11 minutes ago" are
/// a message's age, not a timing, and are not matched.
const TIMING = /(?<![\w.])\d+(?:\.\d+)?\s?(?:ms|s|m)(?![\w])/;

export function judgeRow(row: RowMeasure, types: readonly RowType[] = ROW_TYPES): Finding[] {
  const findings: Finding[] = [];
  const type = types.find((candidate) => candidate.name === row.type);
  if (type && row.controls.length > type.budget)
    findings.push({
      rule: "budget",
      detail: `${row.controls.length} controls at rest, budget ${type.budget}: ${row.controls.map((c) => c || "(unnamed)").join(" | ")}`,
    });
  const seen = new Map<string, number>();
  for (const label of row.controls.map(name).filter(Boolean)) seen.set(label, (seen.get(label) ?? 0) + 1);
  for (const [label, count] of seen)
    if (count > 1) findings.push({ rule: "duplicate", detail: `"${label}" ${count} times` });
  for (const item of new Set((row.menu ?? []).map(name).filter(Boolean)))
    if (seen.has(item)) findings.push({ rule: "duplicate", detail: `"${item}" on the row and again in its menu` });
  const timing = row.running ? undefined : TIMING.exec(row.text);
  if (timing) findings.push({ rule: "timing", detail: `"${timing[0]}" shown at rest on a row that is not running` });
  return findings;
}
