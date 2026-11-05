// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A stretch of a turn the person came in on counts as ended: the agent's text before a steer that
// landed (a message sent into the running turn, or one sent now), and a turn with no summary that his
// next prompt opened over, get the end-of-turn footer with Copy, as Claude Code desktop draws them
// (Leo, 2026-11-03: "i also think a lot of these should've been counted as "ended"-ish turns that allow
// me to copy/paste your stuff / cuz look claude code lets that happen if the user comes in").
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { SUPERSEDED, turnView } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 3, 20, 0, 0);
let at = START;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 10_000),
  ...extra,
});
const bash = (id: string) =>
  row(`a-${id}`, "activity", {
    items: [{ kind: "tool", text: "", tool: { id, title: `Run ${id}`, kind: "execute", status: "completed" } }],
  });

const ids = (rows: readonly AcpmuxRow[]) => rows.map((each) => each.id);
const footers = (rows: readonly AcpmuxRow[]) => rows.filter((each) => each.kind === "turnSummary");

const running = (steer: AcpmuxRow["steer"], extra: Partial<AcpmuxRow> = {}) => [
  row("u", "user", { text: "Plan the transfer work" }),
  bash("b0"),
  row("r1", "assistant", { text: "All three are contained Rust changes. Want me to start with the seed?", ...extra }),
  bash("b1"),
  row("s1", "user", { text: "ofc", steer }),
  bash("b2"),
];

for (const family of ["claude", "codex"])
  test(`${family}: a running turn's stretch before a landed steer ends on a footer with Copy`, () => {
    const view = turnView(running("landed"), new Set(), {
      working: true,
      liveRuns: true,
      agentFamily: family,
      now: START + 200_000,
    });
    const list = ids(view);
    const footer = view.find((each) => each.id === `${SUPERSEDED}-s1`);
    expect(footer).toBeDefined();
    expect(footer!.kind).toBe("turnSummary");
    expect(footer!.superseded).toBe(true);
    expect(footer!.text).toContain("Want me to start with the seed?");
    expect(footer!.answerId).toBe("r1");
    expect(footer!.turnCopy?.some((part) => "text" in part && part.text.includes("contained Rust"))).toBe(true);
    // Right over the steer, after the work the stretch ended on.
    expect(list.indexOf(`${SUPERSEDED}-s1`)).toBe(list.indexOf("s1") - 1);
    // Its time is the stretch's, never "Worked for".
    expect(footer!.durationMs).toBeUndefined();
  });

test("an ended turn keeps its own footer and adds one over the steer", () => {
  const rows = [
    ...running("landed"),
    row("r2", "assistant", { text: "Seed is hooked in." }),
    row("sum", "turnSummary", { status: "completed" }),
  ];
  for (const family of ["claude", "codex"]) {
    const view = turnView(rows, new Set(), { liveRuns: true, agentFamily: family, now: START + 400_000 });
    const list = ids(footers(view));
    expect(list).toEqual([`${SUPERSEDED}-s1`, "sum"]);
    // The turn's own footer copies the whole turn as before.
    expect(view.find((each) => each.id === "sum")!.text).toBe("Seed is hooked in.");
  }
});

test("a Send now (the prompt continues the turn it ended) counts too", () => {
  const rows = [
    row("u", "user", { text: "Plan the transfer work" }),
    row("r1", "assistant", { text: "Here is the plan." }),
    bash("b1"),
    row("stop", "turnSummary", { status: "cancelled", continued: true }),
    row("s1", "user", { text: "do it now", continues: true }),
    bash("b2"),
  ];
  const view = turnView(rows, new Set(), { working: true, liveRuns: true, agentFamily: "claude", now: START + 1e6 });
  expect(ids(footers(view))).toEqual([`${SUPERSEDED}-s1`]);
});

test("no footer for a steer the agent has not read, a reply still streaming, or work alone", () => {
  const options = { working: true, liveRuns: true, agentFamily: "claude", now: START + 1e6 };
  expect(footers(turnView(running("waiting"), new Set(), options))).toEqual([]);
  expect(footers(turnView(running("landed", { streaming: true }), new Set(), options))).toEqual([]);
  const workOnly = [
    row("u", "user", { text: "Run it" }),
    bash("w0"),
    row("s1", "user", { text: "and this", steer: "landed" }),
  ];
  expect(footers(turnView(workOnly, new Set(), options))).toEqual([]);
});

test("another agent's message into the turn is not the person coming in", () => {
  const rows = [
    row("u", "user", { text: "Plan the transfer work" }),
    row("r1", "assistant", { text: "Here is the plan." }),
    row("m1", "user", {
      text: "lane report",
      steer: "landed",
      incoming: {
        kind: "message",
        message: { name: "lane", sessionId: "lane-1", text: "lane report", raw: "lane report" },
      } as AcpmuxRow["incoming"],
    }),
    bash("b2"),
  ];
  const view = turnView(rows, new Set(), { working: true, liveRuns: true, agentFamily: "claude", now: START + 1e6 });
  expect(footers(view)).toEqual([]);
});

test("a turn with no summary that the person's next prompt opened over ends on a footer", () => {
  const rows = [
    row("u", "user", { text: "Plan the transfer work" }),
    row("r1", "assistant", { text: "All three are contained Rust changes." }),
    bash("b1"),
    row("u2", "user", { text: "ofc" }),
    row("r2", "assistant", { text: "On it." }),
    row("sum2", "turnSummary", { status: "completed" }),
  ];
  const view = turnView(rows, new Set(), { agentFamily: "claude", now: START + 1e6 });
  const list = ids(view);
  const footer = view.find((each) => each.id.startsWith(`${SUPERSEDED}-`));
  expect(footer?.text).toBe("All three are contained Rust changes.");
  expect(list.indexOf(footer!.id)).toBe(list.indexOf("u2") - 1);
  // Not when another agent's message opened the next turn: this one may still go on.
  const incoming = rows.map((each) =>
    each.id === "u2"
      ? {
          ...each,
          incoming: {
            kind: "message",
            message: { name: "lane", sessionId: "lane-1", text: "lane report", raw: "lane report" },
          } as AcpmuxRow["incoming"],
        }
      : each,
  );
  expect(
    turnView(incoming, new Set(), { agentFamily: "claude", now: START + 1e6 }).some((each) => each.superseded),
  ).toBe(false);
});
