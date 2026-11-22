// The transcript-at-rest clutter rules (scripts/gallery/transcriptClutter.ts): a row over its control
// budget, the same action twice (on the row, or on the row and in its ⋯ menu), and a timing at rest.
// The first case is the failed subagent row of Leo's 2026-11-11 capture.
import { expect, test } from "bun:test";
import { judgeRow } from "../scripts/gallery/transcriptClutter";

test("Leo's failed subagent row: over budget, its menu repeats an action, 13ms at rest", () => {
  const findings = judgeRow({
    type: "subagent row",
    controls: ["Why only some messages are for…", "Ask parent to retry", "Retry", "Subagent actions"],
    menu: ["Ask parent to retry"],
    text: "Why only some messages are for… Concurrent subagent limit reached Ask parent to retry 13ms",
    running: false,
  });
  expect(findings.map((finding) => finding.rule).sort()).toEqual(["budget", "duplicate", "timing"]);
});

test("a calm row passes: its toggle and one action, no menu repeat, no timing", () => {
  expect(
    judgeRow({
      type: "subagent row",
      controls: ["Search the logs", "Retry"],
      text: "Search the logs Failed",
      running: false,
    }),
  ).toEqual([]);
});

test("a running row may show its clock; a message's age is not a timing", () => {
  expect(judgeRow({ type: "tool row", controls: ["Run tests"], text: "Run tests 4.2s", running: true })).toEqual([]);
  expect(judgeRow({ type: "user message", controls: [], text: "fix it 11 minutes ago", running: false })).toEqual([]);
});

test("the same name twice on one row is a duplicate", () => {
  const findings = judgeRow({
    type: "edited-files card",
    controls: ["Undo", "undo"],
    text: "Edited 2 files",
    running: false,
  });
  expect(findings).toEqual([{ rule: "duplicate", detail: '"undo" 2 times' }]);
});
