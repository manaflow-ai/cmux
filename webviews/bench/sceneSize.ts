// The fidelity scene's per-chat transcript size, from the profile. A profile whose `transcript_events` lists the shown
// chats' log lengths (leo-workspace tools/perf_sensor.py, from `cmux app chat perf`'s `transcript.events`) sizes each
// seeded chat to that many events; a profile without it keeps the ladder's ROWS / 2 turns. Its own module so a test
// imports it without running the bench.
import { loadTurn } from "../src/agent-session/acpmux/loadFixture";

/** Events (log records) in the first `turns` heavy load turns. */
export function eventsInTurns(turns: number): number {
  let total = 0;
  for (let turn = 0; turn < turns; turn += 1) total += loadTurn(turn).length;
  return total;
}

/** The heavy-turn count whose log is at least `events` long; the smallest such count, at least 1. One pass over the
 * turns: the estimate-then-step search it replaces recounted every turn from 0 at each step, and at Leo's 1.64M-event
 * chat (251,762 turns, 4.7 s a count) the bench sat in it for the whole 40 min part bound before opening a page. */
export function turnsForEvents(events: number): number {
  let turns = 0;
  let total = 0;
  while (turns < 1 || total < events) {
    total += loadTurn(turns).length;
    turns += 1;
  }
  return turns;
}

/** Turns for the chat at `index` of the scene: its own profile entry, else the last one given (a profile that lists
 * fewer chats than the scene seeds), else `fallback` when the profile carries none. */
export function sceneTurns(transcriptEvents: readonly number[] | null, index: number, fallback: number): number {
  const events = transcriptEvents?.length ? (transcriptEvents[index] ?? transcriptEvents.at(-1)!) : null;
  return events === null ? fallback : turnsForEvents(events);
}
