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

/** The heavy-turn count whose log is at least `events` long; the smallest such count, at least 1. */
export function turnsForEvents(events: number): number {
  const sample = 40;
  const perTurn = eventsInTurns(sample) / sample;
  let turns = Math.max(1, Math.floor(events / perTurn));
  while (turns > 1 && eventsInTurns(turns - 1) >= events) turns -= 1;
  while (eventsInTurns(turns) < events) turns += 1;
  return turns;
}

/** Turns for the chat at `index` of the scene: its own profile entry, else the last one given (a profile that lists
 * fewer chats than the scene seeds), else `fallback` when the profile carries none. */
export function sceneTurns(transcriptEvents: readonly number[] | null, index: number, fallback: number): number {
  const events = transcriptEvents?.length ? (transcriptEvents[index] ?? transcriptEvents.at(-1)!) : null;
  return events === null ? fallback : turnsForEvents(events);
}
