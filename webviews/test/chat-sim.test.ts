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
import { runSimulation, type RowProbe, type SimResult, createSimulation } from "../src/agent-session/acpmux/sim/run";
import { parseRecords, sanitizeRecords, scrubText } from "../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, SIM_SESSION } from "../src/agent-session/acpmux/sim/script";
import { SCENARIOS, longRun, FORK_MID_STREAM, forkMidStream } from "../src/agent-session/acpmux/sim/scenarios";
import { TRANSCRIPT_BLOCK_GAP, TRANSCRIPT_LIVE_STEP_GAP } from "../src/agent-session/acpmux/transcriptGrid";

const FIXTURES = join(import.meta.dir, "fixtures", "chat-sim");
const broken = (result: SimResult, prefix: string) =>
  result.violations
    .filter((violation) => violation.rule.startsWith(prefix))
    .map((violation) => `${violation.label}: ${violation.detail}`);

// Rules (a) and (b) hold in every scenario: a turn's first rows keep their gaps, and nothing folds
// before its turn ends.
// Rule i (one message is one whole bubble) runs under the same describe, so the a and b tests keep their names.
describe("chat simulator: (a) a turn's first rows keep their gaps, (b) nothing folds before its turn ends", () => {
  for (const [name, make] of Object.entries(SCENARIOS)) {
    for (const rule of ["a-", "b-", "i-"]) {
      test(`${name}: rule ${rule.slice(0, 1)}`, () => {
        expect(broken(runSimulation(make()), rule)).toEqual([]);
      });
    }
  }
});

// Rule (d) holds in every scenario: another agent's line among tool rows sits on their pitch. (d) here is
// the received-gap rule; the burst rules d-blank, d-shift and the rest hold in the burst replay below.
describe("chat simulator: (d) received lines on the tool rows' pitch", () => {
  for (const [name, make] of Object.entries(SCENARIOS)) {
    test(`${name}: rule d`, () => {
      expect(broken(runSimulation(make()), "d-received")).toEqual([]);
    });
  }
});

/** Turn 2's rows at the first step its live line stands under the line that opened it (its calls fold into the live line). */
const openedTurn = (name: string) => {
  for (const step of runSimulation(SCENARIOS[name]!()).traces) {
    const rows = step.rows ?? [];
    const at = rows.findIndex((row) => row.turn === 2 && row.received && row.opens);
    if (at > 0 && rows[at + 1]?.kind === "thinking") return { rows, at };
  }
  throw new Error(`${name}: no step with turn 2's live line under its received line`);
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
    expect(rows[at + 1]!.gap).toBe(TRANSCRIPT_LIVE_STEP_GAP);
    expect(broken(runSimulation(SCENARIOS[name]!()), "d-")).toEqual([]);
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
  const isHead = (row: RowProbe) => (row.kind === "working" || row.kind === "worked") && row.head;
  const trace = result.traces.find((step) => step.rows?.some(isHead));
  const head = trace!.rows!.find(isHead)!;
  expect(head.gap).toBeGreaterThanOrEqual(24);
});

// Fork-hammer's invariant, the pane's half (#50021, #50094, #50089): a fork made mid-stream draws exactly the
// turns its records hold (its prompts, and the cut-off reply), and is idle; the daemon's half checks those
// turns are the ones its agent holds (acpmux tests/hub_integration/fork_context.rs).
test("chat simulator: a fork made mid-stream draws the turns its records hold, the cut-off reply too, and is idle", () => {
  const result = runSimulation(forkMidStream());
  const last = result.traces.at(-1)!;
  expect(last.working).toBe(false);
  const rows = last.rows ?? [];
  expect(rows.filter((row) => row.live)).toEqual([]);
  const prompts = rows.filter((row) => row.opens).map((row) => row.text);
  expect(prompts).toEqual(FORK_MID_STREAM.prompts.map((p) => p.slice(0, 80)));
  expect(rows.some((row) => row.text?.startsWith(FORK_MID_STREAM.partial.slice(0, 40)))).toBe(true);
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

for (const terminal of ["turn_end", "turn_result"]) {
  test(`an assistant row folded at ${terminal} counts as a turn-end fold`, () => {
    const scenario = longRun(2);
    if (terminal === "turn_result") {
      const endSeqs = new Set(scenario.events.filter((event) => event.kind === "turn_end").map((event) => event.seq));
      scenario.events = scenario.events.filter((event) => !endSeqs.has(event.seq));
      scenario.steps = scenario.steps.filter((step) => step.type !== "event" || !endSeqs.has(step.seq));
    }
    const result = runSimulation(scenario);
    const folds = result.traces.filter((step) => step.label === terminal).flatMap((step) => step.folds);
    expect(
      folds.some((fold) => fold.kind === "assistant" && fold.verdict === "turn-end" && fold.beforeTurnEndMs === 0),
    ).toBe(true);
    expect(broken(result, "b-")).toEqual([]);
  });
}

test("a prepended date line preserves the reader's place while an opened fold still moves rows below it", () => {
  const scenario = longRun(4);
  const before = scenario.steps.length;
  const afterHour = scenario.steps[0]!.at + 3_600_001;
  scenario.steps.push(
    { type: "reader", at: afterHour, label: "first date appears", reader: { scroll: "top" } },
    { type: "reader", at: afterHour + 1, label: "open first turn", reader: { open: "worked-user-1" } },
  );
  const result = runSimulation(scenario);
  expect(result.traces[before - 1]!.rows?.some((row) => row.kind === "date")).toBe(false);
  expect(result.traces[before]!.rows?.[0]?.kind).toBe("date");
  const moved = result.violations.filter((violation) => violation.rule === "d-shift");
  expect(moved.some((violation) => violation.step === before)).toBe(false);
  expect(moved.some((violation) => violation.step === before + 1)).toBe(true);
});

// 300 turns by default (about 3 s); CHAT_SIM_LONG=1 runs 1,800 (10k+ rows, 40 h simulated, about 90 s).
const LONG = process.env.CHAT_SIM_LONG === "1";
test(`chat simulator: a ${LONG ? "monstrously " : ""}long run (${LONG ? "10k+" : "1.5k+"} rows, hours of virtual time) keeps folds and settled rows stable`, () => {
  const result = runSimulation(longRun(LONG ? 1_800 : 300), { rowsInTraceUpTo: 0 });
  expect(result.recordRows).toBeGreaterThan(LONG ? 10_000 : 1_500);
  expect(result.virtualMs).toBeGreaterThan((LONG ? 30 : 6) * 3_600_000);
  expect(broken(result, "b-")).toEqual([]);
  expect(broken(result, "d-shift")).toEqual([]);
}, 300_000);

// Leo, 2026-11-25: "the animation for compaction and a message sent/steered during compaction is weird. the worked for
// collapsing the compaction and then the next worked for + thinking is weird. layout shifts and awkward looking
// animations". A /compact turn the person steers while it compacts draws one "Worked for" at every step, under the
// steer, never over the compaction note: the note and the steer keep their places while the steer's work comes in.
test("chat simulator: compact-steer: one Worked for, under the steer, at every step", () => {
  const result = runSimulation(SCENARIOS["compact-steer"]!());
  let seen = false;
  for (const step of result.traces) {
    const own = (step.rows ?? []).filter((row) => row.turn >= 2);
    const headers = own.filter((row) => row.kind === "worked").length;
    expect({ step: step.step, headers: Math.min(headers, 2) }).toEqual({
      step: step.step,
      headers: Math.min(headers, 1),
    });
    const steer = own.findIndex((row) => row.kind === "user" && row.text?.startsWith("then add a test"));
    const header = own.findIndex((row) => row.kind === "worked");
    if (header >= 0) {
      seen = true;
      expect({ step: step.step, under: steer >= 0 && header > steer }).toEqual({ step: step.step, under: true });
    }
  }
  expect(seen).toBe(true);
  const last = result.traces
    .at(-1)!
    .rows!.filter((row) => row.turn >= 2)
    .map((row) => row.kind);
  expect(last.slice(0, 4)).toEqual(["user", "user", "compaction", "worked"]);
});

// Leo, 2026-11-25: "the animation for compaction and a message sent/steered during compaction is
// weird ... layout shifts and awkward looking animations". Once the steer and the compaction's note
// are drawn, nothing lands above either: the note ends where its live line stood, under the steer,
// and the steer's Working for goes under the note, live and once the turn ends.
test("chat simulator: compact-steer: the steer and the compaction's note never move once drawn", () => {
  const result = runSimulation(SCENARIOS["compact-steer"]!());
  const placed = new Map<string, number>();
  for (const step of result.traces) {
    const own = (step.rows ?? []).filter((row) => row.turn >= 2);
    for (const [name, at] of [
      ["steer", own.findIndex((row) => row.kind === "user" && row.text?.startsWith("then add a test"))],
      ["note", own.findIndex((row) => row.kind === "compaction")],
    ] as const) {
      if (at < 0) continue;
      const first = placed.get(name) ?? at;
      placed.set(name, first);
      expect({ step: step.step, name, at }).toEqual({ step: step.step, name, at: first });
    }
  }
  expect([...placed.keys()].sort()).toEqual(["note", "steer"]);
});

// Leo, 2026-11-25: "this is extremely strange": a turn a background task's end opened (a notice
// row), one thought and two sentences, no tools, drew "Worked for 2m 28s >" and nothing under it.
// Its answer draws below its Worked for, outside the fold, and the time is the turn's own.
test("chat simulator: notice-no-tool-turn: the answer draws below Worked for, timed from the turn's own start", () => {
  const scenario = SCENARIOS["notice-no-tool-turn"]!();
  const sim = createSimulation(scenario);
  let rows: NonNullable<ReturnType<typeof sim.advance>> = [];
  scenario.steps.forEach((_, index) => (rows = sim.advance(index) ?? rows));
  const opened = rows.findIndex((row) => row.kind === "backgroundTurn");
  expect(opened).toBeGreaterThanOrEqual(0);
  const own = rows.slice(opened);
  const worked = own.findIndex((row) => row.kind === "worked");
  const answer = own.findIndex(
    (row) => row.kind === "assistant" && row.text?.startsWith("The tests passed and the PR merged."),
  );
  expect({ worked: worked >= 0, answer: answer >= 0, below: answer > worked }).toEqual({
    worked: true,
    answer: true,
    below: true,
  });
  const header = own[worked]!;
  // The turn ran about two seconds after its notice; the task before it ran 140 s.
  expect(header.durationMs).toBeLessThan(10_000);
  expect(own.find((row) => row.kind === "turnSummary")?.durationMs).toBeLessThan(10_000);
});

// Leo, 2026-11-25: "there are situations in which i steer RIGHT before you finish a turn but your completed sent
// message goes above mine ... worked for above my message and then yours and then boom that's it", then "the final
// ultra fold simply... takes it all away". Running, the rows draw as they came; ended, the turn reads its prompt,
// Worked for, his steer, the answer once, and its footer, with no footer of its own over his steer.
for (const name of ["late-steer", "late-steer-mid-tool", "late-steer-compaction"]) {
  test(`chat simulator: ${name}: ended, Worked for, then the steer, then the answer`, () => {
    const scenario = SCENARIOS[name]!();
    const sim = createSimulation(scenario);
    let rows: NonNullable<ReturnType<typeof sim.advance>> = [];
    const live: string[] = [];
    scenario.steps.forEach((step, index) => {
      rows = sim.advance(index) ?? rows;
      if (!rows.some((row) => row.kind === "turnSummary")) live.push(order(rows));
    });
    expect(order(rows)).toBe("prompt worked steer answer summary");
    // Running, nothing moved: the answer drew where it came (above the steer when it came first).
    if (name === "late-steer") expect(live).toContain("prompt worked answer steer");
    expect(rows.some((row) => row.id.startsWith("superseded-"))).toBe(false);
  });
}

function order(rows: readonly { kind: string; text?: string; id: string }[]): string {
  return rows
    .flatMap((row) =>
      row.kind === "user"
        ? [row.text === "Fix the flaky test." ? "prompt" : "steer"]
        : row.kind === "worked"
          ? ["worked"]
          : row.kind === "assistant" && row.text?.startsWith("Fixed:")
            ? ["answer"]
            : row.kind === "turnSummary"
              ? ["summary"]
              : [],
    )
    .join(" ");
}
