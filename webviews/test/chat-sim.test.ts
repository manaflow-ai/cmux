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

// ST-02, Leo, 2026-11-22 08:29Z (screenshot 1159): "this one seems to have an unnecessary gap due to being a recieved
// message. these aren't categorized properly under our tool call formatting." Another agent's message received mid-turn
// and a "Sent to" line are activity rows: at every step each stands exactly the gap a tool row would stand in its place.
test("chat simulator: received-sent-as-activity: received and sent rows stand a tool row's gap at every step", () => {
  const result = runSimulation(SCENARIOS["received-sent-as-activity"]!());
  const seen = { received: 0, sent: 0 };
  const off: string[] = [];
  for (const step of result.traces)
    for (const row of step.rows ?? []) {
      if (!row.message) continue;
      seen[row.message] += 1;
      if (row.toolGap === undefined || row.gap !== row.toolGap)
        off.push(`${step.label}: ${row.message} ${row.id} ${row.gap}px (a tool row: ${row.toolGap}px)`);
    }
  expect(off).toEqual([]);
  expect(seen.received).toBeGreaterThan(0);
  expect(seen.sent).toBeGreaterThan(0);
  // And at the turn's end, folded, nothing else breaks.
  expect(broken(result, "a-")).toEqual([]);
  expect(broken(result, "b-")).toEqual([]);
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

// Leo, 2026-11-22 22:10Z, on the six minutes from 22:05 to 22:11Z this fixture replays (his acpmux
// chat on cosmic-gray, sanitized): "IMMENSE BULLSHIT JUST HAPPENED. ENTIRE THING FUCKING BLANKED AND
// FUCKING SHIFTED AND PLAYED SOME BULLSHIT ANIMATIONS WHEN YOU STARTED A SUBAGENT AND THE PANE JUST WENT
// CRAZY STUPID". His screenshots showed ~15 "started working" rows a turn, each 6-12 chips, the chips
// squeezed empty or to one or two letters. Rule (d): a turn has one start line, it names at most three
// subagents, each by name and each one the pane saw start (one first read mid-run is not news), and
// the chat never blanks, never moves a settled row, never ends a turn with only its action row, and
// draws a steer where it was sent.
const burst = (from = 0) => {
  const records = parseRecords(readFileSync(join(FIXTURES, "leo-2205-subagent-burst.ndjson"), "utf8"));
  expect(records.length).toBeGreaterThan(2_000);
  return runSimulation(replayScenario("leo-2205-subagent-burst", records.slice(from)), { rowsInTraceUpTo: 0 });
};
describe("chat simulator: Leo's 22:05-22:11Z subagent burst keeps rule d", () => {
  const whole = burst();
  for (const rule of [
    "d-started-pill",
    "d-started-lines",
    "d-blank",
    "d-shift",
    "d-action-only",
    "d-steer-order",
    "b-",
  ])
    test(rule, () => expect(broken(whole, rule)).toEqual([]));
  // The pane reads a chat's newest 400 records first (hub/settled_view.rs MAX_RECORDS), and again after
  // a lag or a reconnect: subagents whose spawn is older than the read are first met mid-run. They are
  // not drawn as starting now (they were the fake ten-chip "started working" rows).
  for (const from of [400, 1_200])
    test(`read from record ${from}: no start line for subagents it never saw start`, () =>
      expect(broken(burst(from), "d-started")).toEqual([]));
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
// "Working for" coming in when a carried prompt's turn starts (`+working`, or `+worked` now that the
// running turn's head line is a `worked` row) is another lane's (the turn's head line; sim map
// `header-arrives-late`), so it is not counted here. Nor is a step of the reader's own (opening a
// fold), which moves what is under it because they asked, as map.ts `landings` reads it.
const CHURN_EXCERPTS = [
  "churn-carried-steer",
  "churn-carried-steer-short",
  "churn-carried-notice",
  "churn-wrap-up-steer",
];
const churned = (result: SimResult) => ({
  flashes: result.flashes.map((flash) => `${flash.label} ${flash.kind} ${flash.id} ${flash.shownMs} ms`),
  midTurnShifts: result.shifts
    .filter(
      (shift) =>
        shift.phase === "mid-turn" &&
        !shift.cause.startsWith("+working ") &&
        !shift.cause.startsWith("+worked ") &&
        !shift.label.startsWith("reader "),
    )
    .map((shift) => `${shift.label} ${shift.cause}`),
});
// What a scenario does that this check counts and the pane means to do, each with why, as the map's
// `known` holds them (sim/map.ts). Each is pinned exactly: one that stops happening comes out of here.
// A turn folds its work under "Worked for" when it ends (rule b), drawn at its `turn_end` (direct.ts
// draws the turn as its result will) or a background turn's end; these scenarios end a turn well
// under a second after its last row came, as no real turn does, so that row folds under a second
// after it was drawn.
const TURN_END_FOLD = "folds with its turn, which the scenario ends under a second after the row came";
// The live Thinking line lasts as long as its turn: a turn the scenario ends under a second after it starts.
const LIVE_LINE = "the live line of a turn the scenario ends under a second after it starts";
// The running turn's head line ("Working for") goes when a turn that only replied ends (a reply alone draws
// no Worked for: map `turn-with-one-thing`); the head line is another lane's (map `header-arrives-late`).
const HEAD_LINE = "the head line of a reply-only turn under a second long; the head line is another lane's";
const KNOWN_CHURN: Record<string, Record<string, string>> = {
  "background-task": { "background_turn activity activity-17 760 ms": TURN_END_FOLD },
  "stopped-turn": { "turn_end activity activity-13 600 ms": TURN_END_FOLD },
  "queued-prompt": { "turn_end activity activity-25 900 ms": TURN_END_FOLD },
  "lost-result": { "turn_end activity activity-13 980 ms": TURN_END_FOLD },
  "empty-turn": {
    "turn_end thinking thinking-live 800 ms": LIVE_LINE,
    "turn_end activity activity-33 900 ms": TURN_END_FOLD,
  },
  "thought-only-turn": {
    "turn_end activity activity-4 740 ms": TURN_END_FOLD,
    "turn_end activity activity-15 500 ms": TURN_END_FOLD,
    "turn_end thinking thinking-live 900 ms": LIVE_LINE,
  },
  "plan-checklist": {
    "turn_end activity activity-26 980 ms": TURN_END_FOLD,
    // The checklist stays the running turn's last row over the live line (map `checklist`), so a reply
    // lands above it: map.ts `landings` counts the checklist as pinned, as the live line is.
    "assistant delta +assistant assistant-8": "lands over the checklist, which stays last (map checklist)",
    "assistant delta +assistant assistant-16": "lands over the checklist, which stays last (map checklist)",
  },
  "received-sent-as-activity": {
    // Another agent's message folds like work once the turn ends (turns.ts `isOwnSteer`), and the
    // scenario ends the turn 660 ms after it came.
    "turn_end user user-31 660 ms": TURN_END_FOLD,
  },
  "incoming-burst": {
    "turn_end worked worked-user-20 900 ms": HEAD_LINE,
    "turn_end thinking thinking-live 900 ms": LIVE_LINE,
    "turn_end worked worked-user-27 980 ms": HEAD_LINE,
    "turn_end thinking thinking-live 980 ms": LIVE_LINE,
    "turn_end activity activity-38 500 ms": TURN_END_FOLD,
    "turn_end worked worked-user-43 980 ms": HEAD_LINE,
    "turn_end worked worked-user-51 900 ms": HEAD_LINE,
  },
};
describe("chat simulator: no sub-second rows and no mid-turn shifts", () => {
  for (const [name, make] of Object.entries(SCENARIOS))
    test(name, () => {
      const known = KNOWN_CHURN[name] ?? {};
      const { flashes, midTurnShifts } = churned(runSimulation(make(), { rowsInTraceUpTo: 0 }));
      expect({
        flashes: flashes.filter((line) => !known[line]),
        midTurnShifts: midTurnShifts.filter((line) => !known[line]),
      }).toEqual({ flashes: [], midTurnShifts: [] });
      expect(Object.keys(known).filter((line) => !flashes.includes(line) && !midTurnShifts.includes(line))).toEqual([]);
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
