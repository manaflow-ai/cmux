import { describe, expect, test } from "bun:test";
import { eventsInTurns, sceneTurns, turnsForEvents } from "../bench/sceneSize";

describe("fidelity scene transcript size", () => {
  test("turns for an event count is the smallest log that reaches it", () => {
    for (const events of [1, 50, 700, 5200]) {
      const turns = turnsForEvents(events);
      expect(eventsInTurns(turns)).toBeGreaterThanOrEqual(events);
      if (turns > 1) expect(eventsInTurns(turns - 1)).toBeLessThan(events);
    }
  });

  test("a profile with no transcript_events keeps the fallback turns; one with them sizes each chat", () => {
    expect(sceneTurns(null, 0, 60)).toBe(60);
    expect(sceneTurns([], 2, 60)).toBe(60);
    expect(sceneTurns([5200, 700], 0, 60)).toBe(turnsForEvents(5200));
    expect(sceneTurns([5200, 700], 1, 60)).toBe(turnsForEvents(700));
    // more chats than the profile lists: the last listed size
    expect(sceneTurns([5200, 700], 3, 60)).toBe(turnsForEvents(700));
  });
});
