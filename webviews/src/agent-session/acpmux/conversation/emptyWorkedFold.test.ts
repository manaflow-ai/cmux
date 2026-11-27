// l10n-allow-file: test fixture prompts, errors and replies, not shipped UI.
// A finished turn draws its "Worked for" only over work it can show (c-763204aef8, asks board: "API-error
// turn shows an empty 'Worked for Ns'"). A turn that died on an API error after only an omitted thought
// (Claude's `display: "omitted"` and redacted thinking reach the pane empty) folded that step under a
// line that opened to nothing; the error card has to stand alone. Every way a turn ends, and each fold
// a steer splits a turn into, must hold to it.
import { afterEach, expect, test } from "bun:test";
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
const RATE_LIMIT =
  "API Error: Request rejected (429) · This request would exceed your account's rate limit. Please try again later.";
const summary = (status: string) =>
  row("summary", "turnSummary", {
    status,
    durationMs: 19_000,
    ...(status === "failed" || status === "error" ? { error: RATE_LIMIT } : {}),
  } as Partial<AcpmuxRow>);
/// A step of thinking with nothing to read: what the pane gets for omitted or redacted thinking.
const omittedThought = (id: string) => row(id, "activity", { items: [{ kind: "thought", text: "" }] as never });
/// A short thought that took under a second draws no row once done either (thoughts.ts isQuietThought).
const quietThought = (id: string) =>
  row(id, "activity", {
    items: [
      { kind: "thought", text: "Let me look." },
      { kind: "thought", text: " " },
    ] as never,
  });
const emptyStep = (id: string) => row(id, "activity", { items: [] as never });
const run = (id: string) =>
  row(id, "activity", {
    toolCount: 1,
    items: [
      { kind: "tool", tool: { id: `${id}-call`, title: "git status", kind: "execute", status: "completed" } },
    ] as never,
  });
const prompt = () => row("prompt", "user", { text: "Run the sidebar tests and fix what fails" });
const steer = () => row("steer", "user", { text: "only the sidebar ones", steer: "landed" });
const reply = (id: string) => row(id, "assistant", { text: "Running just the sidebar tests." });

const folds = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set(), { agentFamily: "codex" }).filter((entry) => entry.kind === WORKED);

afterEach(() => {
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const STATUSES = ["failed", "error", "cancelled", "interrupted", "completed"];
const NOTHING: [string, (id: string) => AcpmuxRow][] = [
  ["an omitted thought", omittedThought],
  ["a quiet thought", quietThought],
  ["an empty step", emptyStep],
];

for (const status of STATUSES)
  for (const [name, step] of NOTHING)
    test(`a ${status} turn of only ${name} draws no Worked for`, () => {
      at = 0;
      expect(folds([prompt(), step("step"), summary(status)])).toEqual([]);
    });

for (const status of STATUSES)
  test(`a ${status} turn whose work draws keeps its Worked for`, () => {
    at = 0;
    const drawn = folds([prompt(), omittedThought("thought"), run("run"), summary(status)]);
    expect(drawn).toHaveLength(1);
  });

for (const arm of [undefined, "split", "in-order", "nested", "nested-open", "header"])
  for (const status of STATUSES)
    test(`a steered ${status} turn draws no Worked for over a stretch with nothing to show (${arm ?? "default"})`, () => {
      at = 0;
      if (arm)
        (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "turn-fold-steered": arm };
      const empty = [prompt(), omittedThought("t1"), reply("r1"), steer(), quietThought("t2"), summary(status)];
      expect(folds(empty)).toEqual([]);
      // Work on one side of the steer still folds; nothing the other side folds alone.
      at = 0;
      const half = [prompt(), run("run"), reply("r1"), steer(), omittedThought("t2"), summary(status)];
      expect(folds(half).length).toBeLessThanOrEqual(1);
      expect(folds(half).length).toBeGreaterThan(0);
    });
