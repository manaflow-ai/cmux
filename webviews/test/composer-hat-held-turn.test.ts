// l10n-allow-file: simulated chat fixtures, not shipped UI.
// The composer hat holds still when turns end and start again quickly. Leo, 2026-11-24: "composer hat
// seems to be getting a lot of flickers recently. it needs to stay tight like the composer".
//
// The hat reads the turn through the composer's Stop hysteresis (App.tsx `hatWorking`,
// composer/turnPresence.ts): its running lines (trayItems) follow that held state, not the raw one.
// Each burst runs through the chat simulator; the raw running state is checked to flicker, and the
// hat drawn from the held state never shows or hides, nor moves its plan, for under HOLD_MS.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { HOLD_MS, TurnPresence } from "../src/agent-session/acpmux/composer/turnPresence";
import type { BackgroundCommand } from "../src/agent-session/acpmux/session-info/processes";
import { runSimulation } from "../src/agent-session/acpmux/sim/run";
import { parseRecords } from "../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, sim, type SimScenario } from "../src/agent-session/acpmux/sim/script";
import { trayItems } from "../src/agent-session/acpmux/subagents/runningTray";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";

const FIXTURES = join(import.meta.dir, "fixtures", "chat-sim");

type Change = { at: number; on: boolean };

function runningChanges(scenario: SimScenario): Change[] {
  const changes: Change[] = [];
  let last: boolean | undefined;
  for (const step of runSimulation(scenario, { rowsInTraceUpTo: 0 }).traces) {
    if (step.working === last) continue;
    last = step.working;
    changes.push({ at: step.t, on: step.working });
  }
  return changes;
}

/** The held turn state the hat reads, at every time it changes. */
function held(running: Change[]): Change[] {
  const start = running[0];
  const model = new TurnPresence(start?.on ?? false, start?.at ?? 0);
  const changes: Change[] = [{ at: start?.at ?? 0, on: model.shown }];
  let index = 1;
  for (;;) {
    const wake = model.nextWake();
    const input = running[index];
    if (input === undefined && wake === undefined) break;
    const at = Math.min(input?.at ?? Infinity, wake ?? Infinity);
    if (input && input.at === at) {
      model.set(input.on, at);
      index += 1;
    } else model.advance(at);
    if (model.shown !== changes.at(-1)!.on) changes.push({ at, on: model.shown });
  }
  return changes;
}

// What the hat holds through the burst: a foreground subagent and a transcript command (both drawn
// only while the turn runs).
const AGENT: Subagent = { id: "a1", parent: null, name: "Explore", state: "running", startedAt: 0 };
const COMMAND: BackgroundCommand = { id: "c1", command: "bun test", state: "running", startedAt: 0 };

/** What the hat draws for `working`: its line count. */
const hatFace = (working: boolean): string => `${trayItems([AGENT], [COMMAND], [], working).length}`;

/** Each face that stood less than HOLD_MS between two changes (the first is the chat's own). */
function short(changes: Change[]): string[] {
  const faces = changes
    .map((change) => ({ at: change.at, face: hatFace(change.on) }))
    .filter((face, index, all) => index === 0 || face.face !== all[index - 1]!.face);
  const out: string[] = [];
  for (let index = 1; index < faces.length - 1; index += 1) {
    const span = faces[index + 1]!.at - faces[index]!.at;
    if (span < HOLD_MS) out.push(`${faces[index]!.face} at ${faces[index]!.at} ms for ${span} ms`);
  }
  return out;
}

function burst(name: string, gaps: readonly number[], runs: readonly number[]): SimScenario {
  const b = sim(name, "Turns that end and start again within milliseconds.");
  b.prompt("Land the stack.");
  b.say("On it.", { chunks: 1, after: 50 }).turnEnd("completed", runs[0] ?? 400);
  gaps.forEach((gap, index) => {
    const kinds = ["notice", "agent_message", "session_message"] as const;
    b.incoming(`subagent ${index} finished`, { kind: kinds[index % kinds.length]! }, gap);
    b.say("Noted.", { chunks: 1, after: 10 }).turnEnd("completed", runs[(index + 1) % runs.length] ?? 300);
  });
  return b.build();
}

const BURSTS: Record<string, () => SimScenario> = {
  "turns ending and starting within 5-60 ms": () => burst("hat-burst-fast", [5, 12, 30, 8, 60, 3, 40], [250, 90, 400]),
  "turns shorter than the dwell, back to back": () => burst("hat-burst-short", [20, 15, 25, 10], [40, 60, 30]),
  "a mix of quick restarts and pauses": () =>
    burst("hat-burst-mixed", [200, 5, 900, 30, 350, 2_000, 15], [500, 120, 800]),
};

test("the hat's face follows the turn: lines while it runs, none between", () => {
  expect(hatFace(true)).toBe("2");
  expect(hatFace(false)).toBe("0");
});

for (const [about, make] of Object.entries(BURSTS))
  test(`chat simulator: the composer hat never changes for under ${HOLD_MS} ms: ${about}`, () => {
    const running = runningChanges(make());
    // On the raw state the hat would flicker.
    expect(short(running).length).toBeGreaterThan(0);
    expect(short(held(running))).toEqual([]);
  });

test("chat simulator: a burst of quick restarts keeps the hat up through it", () => {
  const faces = held(runningChanges(BURSTS["turns ending and starting within 5-60 ms"]!())).map((c) => hatFace(c.on));
  // Up from the first turn through the burst, gone once after the last.
  expect(faces.filter((face) => face === "0").length).toBeLessThanOrEqual(2);
});

for (const file of readdirSync(FIXTURES).filter((name) => name.endsWith(".ndjson")))
  test(`chat simulator: the composer hat never changes for under ${HOLD_MS} ms in the replay ${file}`, () => {
    const records = parseRecords(readFileSync(join(FIXTURES, file), "utf8"));
    expect(short(held(runningChanges(replayScenario(file, records))))).toEqual([]);
  });
