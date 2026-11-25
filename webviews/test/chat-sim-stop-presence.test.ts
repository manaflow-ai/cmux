// l10n-allow-file: simulated chat fixtures, not shipped UI.
// The composer's Stop never flickers when turns start and stop quickly (composer/turnPresence.ts,
// the Rust model's copy). Leo, 2026-11-22: "we ought to have a better fade in/fade out and maybe a
// pulse when you for some reason start stop quick. so that the composer isn't flickering with the
// stop button."
//
// Each chat runs through the chat simulator (src/agent-session/acpmux/sim/README.md): the pane's
// reducer folds the records on virtual time and says at each step whether a turn runs. That running
// state drives the Stop presence model, stepped to every time it or the model changes, and the
// test reads what the slot draws: between two changes, Stop shown or Stop gone stands at least
// HOLD_MS. The bursts' raw running state does flicker (each burst is checked to), so the model is
// what holds. Every sanitized replay in test/fixtures/chat-sim runs too.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { HOLD_MS, TurnPresence } from "../src/agent-session/acpmux/composer/turnPresence";
import { runSimulation } from "../src/agent-session/acpmux/sim/run";
import { parseRecords } from "../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, sim, type SimScenario } from "../src/agent-session/acpmux/sim/script";

const FIXTURES = join(import.meta.dir, "fixtures", "chat-sim");

type Change = { at: number; on: boolean };

/** The running state at each step of `scenario`, as the pane's reducer says it, only where it changes. */
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

/** What the slot draws for `running`: each time Stop shows or goes, and how many pulses it drew. */
function drawn(running: Change[]): { changes: Change[]; pulses: number } {
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
  return { changes, pulses: model.pulses };
}

/** Each span between two changes that stood less than HOLD_MS (the first state is the chat's own). */
function short(changes: Change[]): string[] {
  const out: string[] = [];
  for (let index = 1; index < changes.length - 1; index += 1) {
    const span = changes[index + 1]!.at - changes[index]!.at;
    if (span < HOLD_MS) out.push(`${changes[index]!.on ? "shown" : "gone"} at ${changes[index]!.at} ms for ${span} ms`);
  }
  return out;
}

/** A turn that ends and the next that starts `gaps[i]` ms later, as a queued prompt, a steer, a
 *  subagent's notice or another agent's message does, each turn `runs` ms long. */
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
  "turns ending and starting within 5-60 ms": () => burst("stop-burst-fast", [5, 12, 30, 8, 60, 3, 40], [250, 90, 400]),
  "turns shorter than the dwell, back to back": () => burst("stop-burst-short", [20, 15, 25, 10], [40, 60, 30]),
  "a mix of quick restarts and pauses": () =>
    burst("stop-burst-mixed", [200, 5, 900, 30, 350, 2_000, 15], [500, 120, 800]),
};

for (const [about, make] of Object.entries(BURSTS))
  test(`chat simulator: Stop never shows or hides for under ${HOLD_MS} ms: ${about}`, () => {
    const running = runningChanges(make());
    // The raw state flickers: without the model, Stop would.
    expect(running.length).toBeGreaterThan(4);
    expect(short(running).length).toBeGreaterThan(0);
    const { changes } = drawn(running);
    expect(short(changes)).toEqual([]);
  });

test("chat simulator: a turn that starts right after one ends keeps Stop and pulses it", () => {
  const { changes, pulses } = drawn(runningChanges(BURSTS["turns ending and starting within 5-60 ms"]!()));
  expect(pulses).toBeGreaterThan(0);
  // One Stop from the first turn through the burst's restarts, gone once after the last.
  expect(changes.filter((change) => !change.on).length).toBeLessThanOrEqual(2);
});

const fixtures = readdirSync(FIXTURES).filter((file) => file.endsWith(".ndjson"));
test("chat simulator: there is a recorded chat to replay", () => {
  expect(fixtures.length).toBeGreaterThan(0);
});
for (const file of fixtures)
  test(`chat simulator: Stop never shows or hides for under ${HOLD_MS} ms in the replay ${file}`, () => {
    const records = parseRecords(readFileSync(join(FIXTURES, file), "utf8"));
    const { changes } = drawn(runningChanges(replayScenario(file, records)));
    expect(short(changes)).toEqual([]);
  });
