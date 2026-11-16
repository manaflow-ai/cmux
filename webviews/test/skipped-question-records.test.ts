// l10n-allow-file: transcript fixture prompts and question outcomes.
import { expect, test } from "bun:test";
import pending from "../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-single.json";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { AgentQuestion, State } from "../src/agent-session/acpmux/question/model";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";
import { isVisiblyEmptyMessage } from "../src/agent-session/acpmux/conversation/visibleMessage";

const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  at: 1_000,
  version: 1,
  ...fields,
});
const record = (state: State) =>
  row("question-permission", "questionRecord", {
    text: "Which authentication method? Skipped",
    question: { ...(pending as AgentQuestion), state },
  });
const skipped = record({ kind: "cancelled", reason: "skipped" });
const prompt = row("prompt", "user", { text: "Add authentication" });
const call = row("ask", "activity", {
  items: [
    {
      kind: "tool",
      text: "AskUserQuestion",
      tool: { id: "ask-call", title: "AskUserQuestion", kind: "other", status: "completed" },
    },
  ],
});
const answer = row("answer", "assistant", { text: "I will continue with the default." });
const summary = row("summary", "turnSummary", { status: "completed", durationMs: 5_000, toolCount: 1 });
const source = [prompt, call, skipped, answer, summary];
const options = { now: 10_000, agentFamily: "codex" };
const calls = (rows: readonly AcpmuxRow[]) => rows.flatMap((entry) => entry.items ?? []).map((item) => item.tool?.id);

test("only an explicitly skipped question receipt is invisible", () => {
  expect(isVisiblyEmptyMessage(skipped)).toBe(true);
  for (const state of [
    { kind: "pending" },
    { kind: "answered", answer: { selections: {} } },
    { kind: "cancelled", reason: "stopped" },
    { kind: "cancelled", reason: "answeredInChat" },
    { kind: "cancelled" },
  ] satisfies State[]) {
    const kept = record(state);
    expect(isVisiblyEmptyMessage(kept)).toBe(false);
    expect(turnView([prompt, kept, answer, summary], new Set(), options).some((entry) => entry.id === kept.id)).toBe(
      true,
    );
  }
  expect(isVisiblyEmptyMessage({ ...skipped, kind: "permissionRecord" })).toBe(false);
});

test("skipping removes the receipt while keeping the question tool in live and opened work", () => {
  const live = turnView(source.slice(0, -1), new Set(), { ...options, working: true });
  const closed = turnView(source, new Set(), options);
  const opened = turnView(source, new Set([`${WORKED}-${prompt.id}`]), options);
  for (const view of [live, closed, opened]) expect(view.some((entry) => entry.id === skipped.id)).toBe(false);
  expect(calls(live)).toContain("ask-call");
  expect(calls(closed)).not.toContain("ask-call");
  expect(calls(opened)).toContain("ask-call");
  expect(closed.find((entry) => entry.kind === WORKED)?.toolCount).toBe(1);
  expect(source).toContain(skipped);
  expect(skipped.question?.state).toEqual({ kind: "cancelled", reason: "skipped" });
});

test("a skipped receipt at a history-page boundary leaves no row", () => {
  const withRecord = turnView([skipped, ...source.filter((entry) => entry !== skipped)], new Set(), options);
  const withoutRecord = turnView(
    source.filter((entry) => entry !== skipped),
    new Set(),
    options,
  );
  expect(withRecord.map((entry) => entry.id)).toEqual(withoutRecord.map((entry) => entry.id));
});

test("skipped receipts add no virtual height or gap in live, closed or opened turns", () => {
  for (const working of [false, true])
    for (const expanded of [new Set<string>(), new Set([`${WORKED}-${prompt.id}`])]) {
      const rows = working ? source.slice(0, -1) : source;
      const shown = turnView(rows, expanded, { ...options, working });
      const baseline = turnView(
        rows.filter((entry) => entry !== skipped),
        expanded,
        { ...options, working },
      );
      const actual = layoutConversation(shown, 760);
      const expected = layoutConversation(baseline, 760);
      expect(actual.totalHeight).toBe(expected.totalHeight);
      expect([...actual.tops]).toEqual([...expected.tops]);
      expect([...actual.heights]).toEqual([...expected.heights]);
    }
});
