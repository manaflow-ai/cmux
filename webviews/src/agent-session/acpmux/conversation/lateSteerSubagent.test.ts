// l10n-allow-file: test fixture row ids, not shipped UI.
// A steer the agent went on working after keeps its place at the turn's end (turns.ts
// `lateSteersLast`), also when that work was a subagent it started: its Agent call can draw no row of
// its own, only the start line. Leo's leo-0522-midturn-inbox replay: he steered while the agent was
// thinking, it then started a subagent and answered, and once the turn ended the subagent's start
// line drew over his steer (chat-sim d-steer-order). Leo, on cmux#52785: "we need to compare against
// current behaviour. current im still seeing a few weird folds/animations".
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { lateSteersLast } from "./turns";

const row = (id: string, kind: AcpmuxRow["kind"], at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at, kind, ...extra }) as AcpmuxRow;

const steer = row("steer", "user", 1_000, { text: "Check the cache step first.", steer: "landed" });
const thought = row("thought", "activity", 2_000, { items: [] });
const answer = row("answer", "assistant", 9_000, { text: "The cache key changed with every commit." });
const summary = row("summary", "turnSummary", 9_500, { status: "completed" });

test("a subagent started after the person's steer keeps the steer over its start line", () => {
  const started = row("subagentStarted:g", "subagentStarted", 3_000);
  const rows = [steer, thought, started, answer, summary];
  expect(lateSteersLast(rows).map((r) => r.id)).toEqual(["steer", "thought", "subagentStarted:g", "answer", "summary"]);
});

test("a subagent started before the steer still lets the late steer draw over the answer", () => {
  const started = row("subagentStarted:g", "subagentStarted", 500);
  const rows = [started, steer, answer, summary];
  expect(lateSteersLast(rows).map((r) => r.id)).toEqual(["subagentStarted:g", "steer", "answer", "summary"]);
  // The answer the agent was writing when the steer came still moves under it.
  const early = [started, answer, steer, summary];
  expect(lateSteersLast(early).map((r) => r.id)).toEqual(["subagentStarted:g", "steer", "answer", "summary"]);
});

test("a background turn's subagent is not this turn's work: the late steer still draws over the answer", () => {
  const started = row("subagentStarted:bg", "subagentStarted", 3_000, { inBackground: "bg-1" } as Partial<AcpmuxRow>);
  const rows = [steer, started, answer, summary];
  expect(lateSteersLast(rows).map((r) => r.id)).toEqual(["subagentStarted:bg", "steer", "answer", "summary"]);
});
