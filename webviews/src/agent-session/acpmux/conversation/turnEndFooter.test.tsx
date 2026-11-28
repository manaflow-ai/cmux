// l10n-allow-file: test fixture prompts, tool output and errors, not shipped UI.
// G04: every finished turn ends on its footer row, as Claude desktop ends every reply with one. A turn
// that only ran tools, or ended in an API error, collapsed to a bare "Worked for" line with no Copy and
// no mark (turns.ts `isEmptyFooter`, TurnRows.tsx TurnFooter, turnCopy.ts `turnCopyParts`).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { translate, type Translate } from "../i18n";
import { MARK_FOOTER_ROW, rowMark } from "../transcriptGrid";
import { isEmptyFooter, turnView, WORKED } from "./turns";
import { turnCopyParts, turnCopyText } from "./turnCopy";
import { TurnFooter } from "./TurnRows";

const t: Translate = (key, values) => translate(key, values, "en");
const options = { now: 200_000, working: false };

const ask = (id: string, at: number): AcpmuxRow => ({ id, version: 1, at, kind: "user", text: "Run the tests" });
const ran = (id: string, at: number, output = "12 pass\n0 fail\n"): AcpmuxRow =>
  ({
    id,
    version: 1,
    at,
    kind: "activity",
    toolCount: 1,
    items: [
      {
        kind: "tool",
        text: "bun test",
        tool: {
          id: `${id}-call`,
          title: "bun test",
          kind: "execute",
          status: "completed",
          command: "bun test",
          output,
        },
      },
    ],
  }) as AcpmuxRow;
const summary = (id: string, at: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "turnSummary",
  status: "completed",
  durationMs: 4_000,
  toolCount: 1,
  ...fields,
});
/// The footer's action row alone (Copy, Retry, Fork, the time): the error card above it keeps its own
/// circled !, so a check for the row's failed mark reads only the row.
const actionRow = (markup: string) => markup.slice(markup.indexOf("cv-turn-actions"));
const errorCard = (markup: string) => markup.slice(0, markup.indexOf("cv-turn-actions"));
const footerOf = (rows: AcpmuxRow[], family = "claude") =>
  turnView(rows, new Set(), { ...options, agentFamily: family }).filter((row) => row.kind === "turnSummary");

for (const family of ["claude", "codex"]) {
  test(`${family}: a turn of tool calls alone ends on its row with Copy`, () => {
    const [footer] = footerOf([ask("a", 1_000), ran("r", 1_500), summary("s", 5_000)], family);
    expect(footer).toBeDefined();
    expect(isEmptyFooter(footer!)).toBe(false);
    expect(rowMark(footer!)).toBe(MARK_FOOTER_ROW);
    const markup = renderToStaticMarkup(<TurnFooter row={footer!} />);
    expect(markup).not.toContain("cv-turn-actions--empty");
    expect(markup).toContain('aria-label="Copy"');
  });

  test(`${family}: a turn that ran tools and then failed keeps its row and its Copy, with no failed mark`, () => {
    const [footer] = footerOf(
      [ask("a", 1_000), ran("r", 1_500), summary("s", 5_000, { status: "failed", error: "API Error: 529 Overloaded" })],
      family,
    );
    expect(footer?.turnCopy?.length).toBeGreaterThan(0);
    const markup = renderToStaticMarkup(<TurnFooter row={footer!} />);
    expect(markup).toContain("cv-turn-actions--failed");
    expect(markup).toContain('aria-label="Copy"');
    // The error card says the turn failed (Leo, 2026-11-27: "remove the extraneous error icon in the
    // bottom area it's not important"): the row draws no failed mark, and never a done check.
    expect(errorCard(markup)).toContain("cv-turn-error__icon");
    expect(actionRow(markup)).not.toContain('aria-label="Failed"');
    expect(actionRow(markup)).not.toContain('data-icon="status.failure"');
    expect(markup).not.toContain('data-icon="action.confirm"');
  });
}

test("a turn that failed before it did anything draws no failed mark and no Copy", () => {
  const [footer] = footerOf([
    ask("a", 1_000),
    summary("s", 2_000, { status: "failed", error: "API Error: 529", toolCount: 0 }),
  ]);
  const markup = renderToStaticMarkup(<TurnFooter row={footer!} />);
  expect(markup).toContain("cv-turn-actions--failed");
  expect(errorCard(markup)).toContain("cv-turn-error__icon");
  expect(actionRow(markup)).not.toContain('aria-label="Failed"');
  expect(actionRow(markup)).not.toContain('data-icon="status.failure"');
  expect(markup).not.toContain('aria-label="Copy"');
});

test("Copy on a tool-only turn copies the calls' lines and the last call's output", () => {
  const parts = turnCopyParts([ran("r1", 1_000, "first\n"), ran("r2", 2_000, "12 pass\n0 fail\n")]);
  expect(parts).toBeDefined();
  const text = turnCopyText(t, parts!);
  expect(text).toContain("12 pass\n0 fail");
  expect(text).not.toContain("first");
});

test("Copy on a turn that spoke copies its words and lines, never a call's output", () => {
  const reply: AcpmuxRow = { id: "m", version: 1, at: 3_000, kind: "assistant", text: "All green." };
  const text = turnCopyText(t, turnCopyParts([ran("r", 1_000), reply])!);
  expect(text).toContain("All green.");
  expect(text).not.toContain("12 pass");
});

test("a turn of bookkeeping alone (nothing said, nothing run) still draws no row at rest", () => {
  const [footer] = footerOf([ask("a", 1_000), summary("s", 2_000, { toolCount: 0 })]);
  expect(footer === undefined || isEmptyFooter(footer)).toBe(true);
});

test("a tool-only turn with no summary that the person's next prompt opened over ends on its row", () => {
  const rows = [ask("a", 1_000), ran("r", 1_500), ask("b", 9_000), summary("s", 12_000, { text: "Done." })];
  const shown = turnView(rows, new Set(), { ...options, agentFamily: "claude" });
  const at = shown.findIndex((row) => row.id === "b");
  const before = shown.slice(0, at).filter((row) => row.kind === "turnSummary");
  expect(before).toHaveLength(1);
  expect(isEmptyFooter(before[0]!)).toBe(false);
});

test("reply-less turns joined under one Worked for end on one row under it", () => {
  const wake = (n: number, at: number): AcpmuxRow[] => [
    { id: `wake-${n}`, version: 1, at, kind: "user", text: "", incoming: { kind: "hidden" } } as AcpmuxRow,
    ran(`run-${n}`, at + 500),
    summary(`sum-${n}`, at + 3_000),
  ];
  const rows = [
    ask("a", 1_000),
    { id: "reply", version: 1, at: 2_000, kind: "assistant", text: "Watching it." } as AcpmuxRow,
    summary("sum-0", 2_100, { toolCount: 0 }),
    ...wake(1, 10_000),
    ...wake(2, 20_000),
    ...wake(3, 30_000),
  ];
  const shown = turnView(rows, new Set(), { ...options, agentFamily: "codex" });
  const line = shown.findIndex((row) => row.kind === WORKED && row.workedRun);
  expect(line).toBeGreaterThanOrEqual(0);
  expect(shown.filter((row) => row.kind === WORKED && row.workedRun)).toHaveLength(1);
  expect(shown[line + 1]?.kind).toBe("turnSummary");
  expect(shown[line + 1]?.id).toBe("sum-3");
  expect(shown.slice(line + 2).some((row) => row.kind === "turnSummary" && !isEmptyFooter(row))).toBe(false);
});
