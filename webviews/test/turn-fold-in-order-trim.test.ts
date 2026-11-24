// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// The `trim-*` arms of turn-fold-steered trim `in-order` (RFD 0085's follow-up): the steer stays where
// it arrived and each stretch keeps its own Worked for, but a Worked for above the person's steer draws
// quieter and the turn has one footer, under its answer. The default `in-order` is unchanged.
// Gallery: agent-pane.steered-turn-trim.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { SUPERSEDED, turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 24, 9, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const shell = (id: string, command: string): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: command, kind: "execute", status: "completed", command },
});
const calls = (id: string, second: number, commands: string[]): AcpmuxRow =>
  row(id, "activity", second, { items: commands.map((command, index) => shell(`${id}-${index}`, command)) });

/// Work, a reply, the person's steer, work, a reply, a second steer, work, the answer.
const prompt = row("u-0", "user", 0, { text: "Land the fold fix" });
const firstStretch = [
  calls("t-1", 1, ["cmux-ci build", "git status"]),
  row("a-1", "assistant", 60, { text: "Both builds are running." }),
  row("s-1", "user", 70, { text: "Also check the nightly", steer: "landed" }),
  calls("t-2", 71, ["gh run list"]),
  row("a-2", "assistant", 100, { text: "The nightly is running too." }),
];
const secondSteer = row("s-2", "user", 110, { text: "and the docs", steer: "landed" });
const ended = [
  prompt,
  ...firstStretch,
  secondSteer,
  calls("t-3", 111, ["rg docs"]),
  row("a-final", "assistant", 200, { text: "All green; the docs are updated." }),
  row("sum", "turnSummary", 210, { status: "completed", durationMs: 210_000, toolCount: 4 }),
];
/// The same turn still running: a call in flight after the second steer.
const running = [
  prompt,
  ...firstStretch,
  secondSteer,
  row("t-3", "activity", 111, {
    items: [{ ...shell("t-3-0", "rg docs"), tool: { ...shell("t-3-0", "rg docs").tool!, status: "in_progress" } }],
  }),
];

const arm = (name: string | undefined) => {
  globalThis.cmuxExperiments = name ? { "turn-fold-steered": name } : undefined;
};
const view = (rows: AcpmuxRow[], working = false) =>
  turnView(rows, new Set(), { agentFamily: "claude", now: START + 400_000, working }).filter(
    (shown) => shown.kind !== "date",
  );
const footers = (rows: AcpmuxRow[]) => rows.filter((shown) => shown.kind === "turnSummary").map((shown) => shown.id);
const worked = (rows: AcpmuxRow[]) => rows.filter((shown) => shown.kind === WORKED);
const steerFooters = (rows: AcpmuxRow[]) => footers(rows).filter((id) => id.startsWith(`${SUPERSEDED}-`));

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

test("in-order, the default, keeps a footer over each steer and no quiet line", () => {
  arm(undefined);
  const rows = view(ended);
  expect(steerFooters(rows)).toEqual([`${SUPERSEDED}-s-1`, `${SUPERSEDED}-s-2`]);
  expect(worked(rows).map((shown) => shown.workedQuiet)).toEqual([undefined, undefined, undefined]);
});

for (const [name, quiet] of [
  ["trim-muted", "muted"],
  ["trim-bare", "bare"],
  ["trim-at-end", "muted"],
] as const)
  test(`${name}: the steers stay where they arrived, the lines above them are quiet, one footer`, () => {
    arm("in-order");
    const shipped = view(ended).filter((shown) => shown.kind !== "turnSummary");
    arm(name);
    const rows = view(ended);
    // Every row but the footers draws as in-order, in the same order.
    expect(rows.filter((shown) => shown.kind !== "turnSummary").map((shown) => shown.id)).toEqual(
      shipped.map((shown) => shown.id),
    );
    expect(steerFooters(rows)).toEqual([]);
    expect(footers(rows)).toHaveLength(1);
    expect(rows.at(-1)!.kind).toBe("turnSummary");
    // The lines above a steer are quiet; the turn's last one is not.
    expect(worked(rows).map((shown) => shown.workedQuiet)).toEqual([quiet, quiet, undefined]);
  });

test("while the turn runs, trim-at-end keeps each steer's footer, the other trims draw none", () => {
  arm("in-order");
  const shipped = steerFooters(view(running, true));
  expect(shipped.length).toBeGreaterThan(0);
  arm("trim-at-end");
  expect(steerFooters(view(running, true))).toEqual(shipped);
  for (const name of ["trim-muted", "trim-bare"]) {
    arm(name);
    expect(steerFooters(view(running, true))).toEqual([]);
  }
});
