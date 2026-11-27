// l10n-allow-file: test fixtures.
// A closed "Worked for" says what it hides once Settings > Advanced > Experiments > Fold Summary
// Counts is on: "Worked for 36s · ran 4 commands, edited 2 files", the runs' words and their
// "(1 failed)". Off (the default), the line is the time alone, as before.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { translate } from "../i18n";
import { setExperimentSwitches } from "../../../experiments/switches";
import { FOLD_COUNTS_SWITCH, WORKED, turnView, workedCountsText, workedLabel } from "./turns";
import { WorkedFor } from "./TurnRows";

const t = translate;

afterEach(() => setExperimentSwitches({}));

let next = 0;
const call = (kind: string, extra: Record<string, unknown> = {}) => ({
  kind: "tool",
  text: "Step",
  tool: { id: `c${next++}`, title: "Step", kind, status: "completed", ...extra },
});
const prompt: AcpmuxRow = { id: "p", version: 1, at: 0, kind: "user", text: "Fix it" };
const work = (id: string, at: number, items: ReturnType<typeof call>[]) =>
  ({ id, version: 1, at, kind: "activity", items }) as AcpmuxRow;
const say = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });
const end: AcpmuxRow = {
  id: "s",
  version: 1,
  at: 36_000,
  kind: "turnSummary",
  status: "completed",
  durationMs: 36_000,
};
const worked = (rows: AcpmuxRow[], agentFamily = "codex") =>
  turnView(rows, new Set(), { now: 40_000, agentFamily }).find((row) => row.kind === WORKED)!;

const commands = (n: number, failed = 0) =>
  Array.from({ length: n }, (_, i) => call("execute", i < failed ? { status: "failed" } : {}));
const edits = (...paths: string[]) => paths.map((path) => call("edit", { locations: [{ path }] }));

test("the fold's own calls count as the runs name them, in the order the turn first did each", () => {
  const row = worked([
    prompt,
    work("w", 1_000, [...commands(4), ...edits("a.ts", "b.ts")]),
    say("a", 30_000, "Done."),
    end,
  ]);
  expect(workedCountsText(t, row)).toEqual({ text: "ran 4 commands, edited 2 files", failed: 0 });
});

test("one of each reads in the singular", () => {
  const row = worked([prompt, work("w", 1_000, [...edits("a.ts"), ...commands(1)]), say("a", 30_000, "Done."), end]);
  expect(workedCountsText(t, row)?.text).toBe("edited a file, ran a command");
});

test("failed calls are counted apart", () => {
  const row = worked([prompt, work("w", 1_000, commands(3, 1)), say("a", 30_000, "Done."), end]);
  expect(workedCountsText(t, row)).toEqual({ text: "ran 3 commands", failed: 1 });
});

test("a fold that hides no call has no counts", () => {
  const row = { id: "w", version: 1, at: 0, kind: WORKED, durationMs: 5_000, status: "completed" } as AcpmuxRow;
  expect(workedCountsText(t, row)).toBeUndefined();
});

test("the label builder is unchanged: the time alone", () => {
  const row = worked([prompt, work("w", 1_000, commands(4)), say("a", 30_000, "Done."), end]);
  expect(workedLabel(t, row)).toBe("Worked for 36s");
});

// The worked-line experiment's default arm is `time` again (workedForTimeOnly.test.tsx); its
// `outcome` arm names the work on every line. The two tests below pin the time arm either way.
type ArmHost = { cmuxExperiments?: Record<string, string> };
const timeOnly = () => {
  (globalThis as ArmHost).cmuxExperiments = { "worked-line": "time" };
};
afterEach(() => {
  delete (globalThis as ArmHost).cmuxExperiments;
});

const html = (row: AcpmuxRow) => renderToStaticMarkup(<WorkedFor row={row} expanded={false} onToggle={() => {}} />);

test("off by default: the line reads the time alone, with its chevron", () => {
  timeOnly();
  const row = worked([
    prompt,
    work("w", 1_000, [...commands(4), ...edits("a.ts", "b.ts")]),
    say("a", 30_000, "Done."),
    end,
  ]);
  const out = html(row);
  expect(out).toContain("Worked for");
  expect(out).not.toContain("ran 4 commands");
  expect(out).toContain("cv-worked__chevron");
});

test("switched on: the line names its counts in the quiet tone, failures in the failure tone", () => {
  timeOnly();
  setExperimentSwitches({ [FOLD_COUNTS_SWITCH]: true });
  const row = worked([
    prompt,
    work("w", 1_000, [...commands(4, 1), ...edits("a.ts", "b.ts")]),
    say("a", 30_000, "Done."),
    end,
  ]);
  const out = html(row);
  expect(out).toContain('<span class="cv-worked__work"> · ran 4 commands, edited 2 files');
  expect(out).toContain('<span class="cv-tool__failed is-count"> (1 failed)</span>');
  expect(out).toContain("cv-worked__chevron");
  expect(out).toContain('aria-expanded="false"');
});
