// The chat simulator (src/agent-session/acpmux/sim/README.md): every scenario, a sanitized replay
// of a recorded chat and a long run go through the pane's real reducer, turn view and layout on
// virtual time, and the spacing and fold rules hold at every step.
//
// Leo, 2026-11-21: "it is noticeably bad when you start a new working for whatever and there is no
// space before. we should be able to extremely easily catch this." Rule (a) is red until
// #48597 (and a fix for the live Thinking line under another agent's line) lands.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runSimulation, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { parseRecords, sanitizeRecords, scrubText } from "../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, SIM_SESSION } from "../src/agent-session/acpmux/sim/script";
import { SCENARIOS, longRun } from "../src/agent-session/acpmux/sim/scenarios";
import { ROW_GAP_LOOKS } from "../src/agent-session/acpmux/transcriptGrid";

const FIXTURES = join(import.meta.dir, "fixtures", "chat-sim");
const broken = (result: SimResult, prefix: string) =>
  result.violations
    .filter((violation) => violation.rule.startsWith(prefix))
    .map((violation) => `${violation.label}: ${violation.detail}`);

// Rule (a) holds in every scenario. Two of them reproduce Leo's screenshot: a turn that another agent's
// notice or message opens drew "Working for" flush (0px) under it (transcriptGap's "two one-line rows sit
// flush" rule). Now "Working for", the "Worked for" that replaces it and the live "Thinking" line all stand
// the gap "Worked for" stands under any one-line row (ROW_GAP_LOOKS.shipped.workedAfterLine, 16, #48591).
describe("chat simulator: (a) a turn's first rows keep their gaps, (b) nothing folds before its turn ends", () => {
  for (const [name, make] of Object.entries(SCENARIOS)) {
    for (const rule of ["a-", "b-"]) {
      test(`${name}: rule ${rule.slice(0, 1)}`, () => {
        expect(broken(runSimulation(make()), rule)).toEqual([]);
      });
    }
  }
});

/** The gap over each head of turn 2 ("thinking", "working") in `name`, at the first step it is drawn. */
const headGaps = (name: string) => {
  const gaps: Record<string, number> = {};
  for (const step of runSimulation(SCENARIOS[name]!()).traces)
    for (const row of step.rows ?? []) if (row.head && row.turn === 2 && !(row.kind in gaps)) gaps[row.kind] = row.gap;
  return gaps;
};

for (const name of ["incoming-notice-turn", "incoming-message-turn"])
  test(`chat simulator: ${name}: Thinking and Working for stand the head gap under another agent's line (Leo's screenshot)`, () => {
    const gaps = headGaps(name);
    expect(Object.keys(gaps)).toEqual(expect.arrayContaining(["thinking", "working"]));
    const want = ROW_GAP_LOOKS.shipped.workedAfterLine;
    expect(want).toBeGreaterThan(0);
    expect({ thinking: gaps.thinking, working: gaps.working }).toEqual({ thinking: want, working: want });
  });

test("chat simulator: a person's prompt keeps the block gap over Working for", () => {
  const result = runSimulation(SCENARIOS.basic!());
  const trace = result.traces.find((step) => step.rows?.some((row) => row.kind === "working" && row.head));
  const head = trace!.rows!.find((row) => row.kind === "working" && row.head)!;
  expect(head.gap).toBeGreaterThanOrEqual(24);
});

const replayed = () => {
  const records = parseRecords(readFileSync(join(FIXTURES, "replay-lane-session.ndjson"), "utf8"));
  expect(records.length).toBeGreaterThan(2_000);
  return runSimulation(replayScenario("replay-lane-session", records), { rowsInTraceUpTo: 0 });
};
test("chat simulator: a sanitized replay of a recorded lane chat keeps rule b", () => {
  expect(broken(replayed(), "b-")).toEqual([]);
});
test("chat simulator: a sanitized replay of a recorded lane chat keeps rule a", () => {
  expect(broken(replayed(), "a-")).toEqual([]);
});

// Leo, 2026-11-22: "i am still seeing flickers and flashes of bullshit. sub-second in and out
// bullshit." and "the content within neeeds to be fucking settling fucking night instantly without
// extraneous movement". No row is drawn for under a second (FLASH_MS), and no row comes in mid-turn
// over what the reader follows, in every scenario and in four sanitized excerpts of coordinator
// chats, each of which did one of them before:
// - churn-carried-steer: a steer the turn ended without reading drew its stretch's footer over it
//   and folded the turn around it for 8 ms, then moved again when the next turn took it.
// - churn-carried-steer-short: the same steer moved under the turn's summary only once the next turn
//   started, a few ms after the summary came.
// - churn-carried-notice: an inbox notice the turn ended on drew under the turn for 989 ms, then
//   folded with it.
// - churn-wrap-up-steer: the live wrap-up card went back into its run at the next call, which came
//   in under the steer, above rows already drawn.
// "Working for" coming in when a carried prompt's turn starts (`+working`) is another lane's (the
// turn's head line), so it is not counted here.
const CHURN_EXCERPTS = [
  "churn-carried-steer",
  "churn-carried-steer-short",
  "churn-carried-notice",
  "churn-wrap-up-steer",
];
const churned = (result: SimResult) => ({
  flashes: result.flashes.map((flash) => `${flash.label} ${flash.kind} ${flash.id} ${flash.shownMs} ms`),
  midTurnShifts: result.shifts
    .filter((shift) => shift.phase === "mid-turn" && !shift.cause.startsWith("+working "))
    .map((shift) => `${shift.label} ${shift.cause}`),
});
describe("chat simulator: no sub-second rows and no mid-turn shifts", () => {
  for (const [name, make] of Object.entries(SCENARIOS))
    test(name, () => {
      expect(churned(runSimulation(make(), { rowsInTraceUpTo: 0 }))).toEqual({ flashes: [], midTurnShifts: [] });
    });
  for (const name of CHURN_EXCERPTS)
    test(`${name} (sanitized excerpt)`, () => {
      const records = parseRecords(readFileSync(join(FIXTURES, `${name}.ndjson`), "utf8"));
      const result = runSimulation(replayScenario(name, records), { rowsInTraceUpTo: 0 });
      expect(result.steps).toBeGreaterThan(50);
      expect(churned(result)).toEqual({ flashes: [], midTurnShifts: [] });
    });
});

test("chat simulator: the sanitizer keeps a call's title that is its tool's name", () => {
  const [clean] = sanitizeRecords([
    {
      sessionId: "s",
      seq: 1,
      at: 1,
      dir: "in",
      kind: "tool_call",
      msg: {
        params: {
          update: {
            sessionUpdate: "tool_call",
            toolCallId: "toolu_1",
            title: "mcp__acpmux__wrap_up",
            _meta: { claude: { tool: "mcp__acpmux__wrap_up" } },
          },
        },
      },
    },
  ] as unknown as Parameters<typeof sanitizeRecords>[0]);
  const update = (clean!.msg as { params: { update: { title: string } } }).params.update;
  expect(update.title).toBe("mcp__acpmux__wrap_up");
});

test("chat simulator: the sanitizer keeps the shape and drops every word", () => {
  const raw = [
    { sessionId: "real-id", seq: 7, at: 1_000, dir: "out", kind: "claude.stdin", msg: { text: "secret" } },
    {
      sessionId: "real-id",
      seq: 8,
      at: 2_000,
      dir: "in",
      kind: "tool_call",
      msg: {
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: "real-id",
          update: {
            sessionUpdate: "tool_call",
            toolCallId: "toolu_01Abc9",
            status: "pending",
            title: "git log <someone@example.com> /home/someone/.ssh/id_rsa",
          },
        },
      },
    },
    {
      sessionId: "real-id",
      seq: 9,
      at: 3_000,
      dir: "in",
      kind: "tool_call_update",
      msg: {
        params: { update: { sessionUpdate: "tool_call_update", toolCallId: "toolu_01Abc9", status: "completed" } },
      },
    },
  ];
  const clean = sanitizeRecords(raw);
  expect(clean.map((record) => record.seq)).toEqual([1, 2]);
  expect(clean[0]!.sessionId).toBe(SIM_SESSION);
  expect(clean[1]!.at - clean[0]!.at).toBe(1_000);
  const text = JSON.stringify(clean);
  for (const word of ["secret", "someone", "example", "ssh", "id_rsa", "real-id", "01Abc9"])
    expect(text).not.toContain(word);
  const update = clean[0]!.msg.params.update;
  expect(update.sessionUpdate).toBe("tool_call");
  expect(update.status).toBe("pending");
  expect(update.title.length).toBe("git log <someone@example.com> /home/someone/.ssh/id_rsa".length);
  // A recurring id maps to the same stand-in, so a call still pairs with its result.
  expect(clean[1]!.msg.params.update.toolCallId).toBe(update.toolCallId);
  // An id keeps its kind (the reducer reads `toolu_`, `bg-done-`), not its unique part.
  expect(update.toolCallId).toStartWith("toolu_");
  expect(scrubText("## Fix it\n- one")).toMatch(/^## \S+ \S+\n- \S+$/);
});

// 300 turns by default (about 3 s); CHAT_SIM_LONG=1 runs 1,800 (10k+ rows, 40 h simulated, about 90 s).
const LONG = process.env.CHAT_SIM_LONG === "1";
test(`chat simulator: a ${LONG ? "monstrously " : ""}long run (${LONG ? "10k+" : "1.5k+"} rows, hours of virtual time) runs and keeps rule b`, () => {
  const result = runSimulation(longRun(LONG ? 1_800 : 300), { rowsInTraceUpTo: 0 });
  expect(result.recordRows).toBeGreaterThan(LONG ? 10_000 : 1_500);
  expect(result.virtualMs).toBeGreaterThan((LONG ? 30 : 6) * 3_600_000);
  expect(broken(result, "b-")).toEqual([]);
}, 300_000);
