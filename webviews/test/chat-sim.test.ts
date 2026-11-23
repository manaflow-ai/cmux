// The chat simulator (src/agent-session/acpmux/sim/README.md): every scenario, a sanitized replay
// of a recorded chat and a long run go through the pane's real reducer, turn view and layout on
// virtual time, and the spacing and fold rules hold at every step.
//
// Leo, 2026-11-21: "it is noticeably bad when you start a new working for whatever and there is no
// space before. we should be able to extremely easily catch this." Rule (a) is red until
// #48597 (and a fix for the live Thinking line under another agent's line) lands.
import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  countChanges,
  fixtures,
  freshness,
  playedKinds,
  readSessionRecords,
  ruleCounts,
  seenKinds,
} from "../src/agent-session/acpmux/sim/library";
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
    expect({ thinking: gaps.thinking, working: gaps.working }).toEqual({
      thinking: want,
      working: want,
    });
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
  return runSimulation(replayScenario("replay-lane-session", records), {
    rowsInTraceUpTo: 0,
  });
};
test("chat simulator: a sanitized replay of a recorded lane chat keeps rule b", () => {
  expect(broken(replayed(), "b-")).toEqual([]);
});
test("chat simulator: a sanitized replay of a recorded lane chat keeps rule a", () => {
  expect(broken(replayed(), "a-")).toEqual([]);
});

test("chat simulator: the sanitizer keeps the shape and drops every word", () => {
  const raw = [
    {
      sessionId: "real-id",
      seq: 7,
      at: 1_000,
      dir: "out",
      kind: "claude.stdin",
      msg: { text: "secret" },
    },
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
        params: {
          update: {
            sessionUpdate: "tool_call_update",
            toolCallId: "toolu_01Abc9",
            status: "completed",
          },
        },
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
  const result = runSimulation(longRun(LONG ? 1_800 : 300), {
    rowsInTraceUpTo: 0,
  });
  expect(result.recordRows).toBeGreaterThan(LONG ? 10_000 : 1_500);
  expect(result.virtualMs).toBeGreaterThan((LONG ? 30 : 6) * 3_600_000);
  expect(broken(result, "b-")).toEqual([]);
}, 300_000);

// The library of reported chats and the freshness check (sim/README.md "Reported chats", "Keep it current").
describe("chat simulator library", () => {
  const record = (seq: number, kind = "tool_call", dir = "in") => ({
    seq,
    at: seq * 10,
    dir,
    kind,
    msg: {},
  });
  const session = () => {
    const root = mkdtempSync(join(tmpdir(), "chat-sim-lib-"));
    const events = join(root, "events");
    mkdirSync(events);
    const files = [
      [1, 2, 3],
      [4, 5, 6],
      [7, 8, 9],
    ];
    files.forEach((seqs, index) =>
      writeFileSync(
        join(events, `00000${index + 1}.ndjson`),
        seqs.map((seq) => JSON.stringify(record(seq))).join("\n") + "\n",
      ),
    );
    return root;
  };

  test("a range reads only the event files it touches, and the same records a full read keeps", () => {
    const root = session();
    const all = readSessionRecords(root);
    expect(all.records.map((r) => r.seq)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(all.filesRead).toBe(3);
    const tail = readSessionRecords(root, { from: 7 });
    expect(tail.records.map((r) => r.seq)).toEqual([7, 8, 9]);
    expect(tail.filesRead).toBe(1);
    const middle = readSessionRecords(root, { from: 5, to: 7 });
    expect(middle.records.map((r) => r.seq)).toEqual([5, 6, 7]);
    expect(middle.filesRead).toBe(2);
    const last = readSessionRecords(root, { last: 4 });
    expect(last.records.map((r) => r.seq)).toEqual([6, 7, 8, 9]);
    expect(last.filesRead).toBe(2);
  });

  test("rule counts are rows per rule, and changes name each rule that moved", () => {
    const counts = ruleCounts({
      violations: [
        { rule: "a-head-gap", rowId: "r1" },
        { rule: "a-head-gap", rowId: "r1" },
        { rule: "a-head-gap", rowId: "r2" },
        { rule: "c-rerender", rowId: "r3" },
      ] as SimResult["violations"],
    });
    expect(counts).toEqual({ "a-head-gap": 2, "c-rerender": 1 });
    expect(countChanges({ "a-head-gap": 2, "c-rerender": 1 }, counts)).toEqual([]);
    expect(countChanges({ "a-head-gap": 9 }, counts)).toEqual([
      { rule: "a-head-gap", before: 9, after: 2 },
      { rule: "c-rerender", before: 0, after: 1 },
    ]);
  });

  test("freshness names the kinds real chats write that nothing plays, not the ones the pane never reads", () => {
    const root = mkdtempSync(join(tmpdir(), "chat-sim-fresh-"));
    for (const [chat, kinds] of [
      ["one", ["tool_call", "queued", "claude.stream_event"]],
      ["two", ["queued", "inbox"]],
    ] as const) {
      mkdirSync(join(root, chat, "events"), { recursive: true });
      writeFileSync(
        join(root, chat, "events", "000001.ndjson"),
        kinds
          .map((kind, index) => JSON.stringify(record(index + 1, kind, kind === "tool_call" ? "in" : "mux")))
          .join("\n"),
      );
    }
    const played = playedKinds([SCENARIOS.basic!()], join(root, "no-fixtures"));
    expect(played.has("in tool_call")).toBe(true);
    const { missing } = freshness(played, seenKinds(root, 10).kinds);
    expect(missing.map(([key, entry]) => [key, entry.chats.size])).toEqual([
      ["mux queued", 2],
      ["mux inbox", 1],
    ]);
  });

  test("every committed fixture replays, and each sidecar says what it reproduces", () => {
    const all = fixtures(FIXTURES);
    expect(all.length).toBeGreaterThan(0);
    for (const fixture of all) {
      expect(fixture.sidecar?.about.length ?? 0).toBeGreaterThan(10);
      expect(Object.values(fixture.sidecar!.expect).every((rows) => Number.isInteger(rows))).toBe(true);
    }
  });
});
