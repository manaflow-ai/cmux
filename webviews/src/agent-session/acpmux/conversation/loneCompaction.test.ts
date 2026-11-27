// l10n-allow-file: test fixture prompts, not shipped UI.
// A /compact turn whose only work was the compaction ends with its note in sight, where its live
// "Compacting conversation…" line stood, never shut inside a "Worked for 1s" that hides what it did
// (snappy-bench's compaction transition never saw a note end: Leo, 2026-11-25, "layout shifts and
// awkward looking animations"). A turn that also replied or ran calls still folds its work.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { WORKED, turnView } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const compact = () => row("prompt", "user", { text: "/compact" });
const note = () =>
  row("compaction-1", "compaction", {
    compaction: { state: "completed", preTokens: 152_000, postTokens: 18_000 },
  } as Partial<AcpmuxRow>);
const summary = () => row("summary", "turnSummary", { status: "completed", durationMs: 1_000 } as Partial<AcpmuxRow>);
const view = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { agentFamily: "claude" });

test("a /compact turn of only its compaction draws the note, with no Worked for over it", () => {
  const shown = view([compact(), note(), summary()]);
  expect(shown.some((entry) => entry.kind === WORKED)).toBe(false);
  expect(shown.some((entry) => entry.id === "compaction-1")).toBe(true);
});

test("a turn that compacted and then ran a call still folds its work", () => {
  const call = row("run", "activity", {
    toolCount: 1,
    items: [{ kind: "tool", tool: { id: "run-call", title: "git status", kind: "execute", status: "completed" } }],
  } as Partial<AcpmuxRow>);
  const shown = view([compact(), note(), call, summary()]);
  expect(shown.some((entry) => entry.kind === WORKED)).toBe(true);
});
