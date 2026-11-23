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
import { runSimulation, type RowProbe, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { parseRecords, sanitizeRecords, scrubText } from "../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, SIM_SESSION } from "../src/agent-session/acpmux/sim/script";
import { SCENARIOS, longRun } from "../src/agent-session/acpmux/sim/scenarios";
import { TRANSCRIPT_BLOCK_GAP } from "../src/agent-session/acpmux/transcriptGrid";

const FIXTURES = join(import.meta.dir, "fixtures", "chat-sim");
const broken = (result: SimResult, prefix: string) =>
  result.violations
    .filter((violation) => violation.rule.startsWith(prefix))
    .map((violation) => `${violation.label}: ${violation.detail}`);

// Rules (a), (b) and (d) hold in every scenario: a turn's first rows keep their gaps, nothing folds
// before its turn ends, and another agent's line among tool rows sits on their pitch.
describe("chat simulator: (a) a turn's first rows keep their gaps, (b) nothing folds before its turn ends, (d) received lines on the tool rows' pitch", () => {
  for (const [name, make] of Object.entries(SCENARIOS)) {
    for (const rule of ["a-", "b-", "d-"]) {
      test(`${name}: rule ${rule.slice(0, 1)}`, () => {
        expect(broken(runSimulation(make()), rule)).toEqual([]);
      });
    }
  }
});

/** Turn 2's rows at the first step its live line and a call stand under the line that opened it. */
const openedTurn = (name: string) => {
  for (const step of runSimulation(SCENARIOS[name]!()).traces) {
    const rows = step.rows ?? [];
    const at = rows.findIndex((row) => row.turn === 2 && row.received && row.opens);
    if (at > 0 && rows.slice(at).some((row) => row.kind === "activity")) return { rows, at };
  }
  throw new Error(`${name}: no step with turn 2's call drawn`);
};

// Leo, 2026-11-22: "sometimes you get these way-too-big gaps. i think it's the message recieving not
// properly getting treated like the tool call ish thing it should be and instead as if it were a
// message?" The turn another agent's line opened is headed by its own line (#50242), a block gap under
// the turn before; the received line sits flush under it, as the turn's first step on the tool rows'
// pitch, and "Thinking" a step's gap under the last of them. It stood 16 under its header and 16 over
// "Thinking", as a prompt's room. Rule (d) holds it in every scenario.
for (const name of ["incoming-notice-turn", "incoming-message-turn"])
  test(`chat simulator: ${name}: another agent's line sits on the tool rows' pitch under its turn's line`, () => {
    const { rows, at } = openedTurn(name);
    const head = rows[at - 1]!;
    expect(head.id).toBe(`worked-${rows[at]!.id}`);
    expect(head.gap).toBe(TRANSCRIPT_BLOCK_GAP);
    expect(rows[at]!.gap).toBe(0);
    expect(rows[at + 1]!.gap).toBe(0);
    expect(broken(runSimulation(SCENARIOS[name]!()), "d-")).toEqual([]);
  });

test("chat simulator: a person's prompt keeps the block gap over Working for", () => {
  const result = runSimulation(SCENARIOS.basic!());
  const isHead = (row: RowProbe) => (row.kind === "working" || row.kind === "worked") && row.head;
  const trace = result.traces.find((step) => step.rows?.some(isHead));
  const head = trace!.rows!.find(isHead)!;
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
