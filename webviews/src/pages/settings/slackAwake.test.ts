import { describe, expect, test } from "vitest";
import { awakeDuration, spentToday, type SlackAwake } from "./slackAwake";

const awake: SlackAwake = {
  allowance_seconds: 7200,
  default_seconds: 7200,
  max_seconds: 86400,
  days: 7,
  senders: [
    { slack_team: "T1", slack_user: "U1", sender_is_owner: true, day: "2026-11-26", seconds: 600, turns: 2 },
    { slack_team: "T1", slack_user: "U2", sender_is_owner: false, day: "2026-11-26", seconds: 9000, turns: 5 },
    { slack_team: "T1", slack_user: "U3", sender_is_owner: false, day: "2026-11-26", seconds: 1800, turns: 1 },
    { slack_team: "T1", slack_user: "U3", sender_is_owner: false, day: "2026-11-25", seconds: 7200, turns: 4 },
  ],
};

describe("spentToday", () => {
  test("reads only today, most time first, owner never capped", () => {
    const rows = spentToday(awake, "2026-11-26", { U2: "Austin" });
    expect(rows.map((r) => [r.name, r.seconds, r.used])).toEqual([
      ["Austin", 9000, 1],
      ["U3", 1800, 0.25],
      ["U1", 600, null],
    ]);
  });
  test("a zero allowance marks every non-owner out", () => {
    const rows = spentToday({ ...awake, allowance_seconds: 0 }, "2026-11-26");
    expect(rows.find((r) => r.user === "U3")?.used).toBe(1);
  });
  test("no rows on a quiet day", () => {
    expect(spentToday(awake, "2026-11-20")).toEqual([]);
  });
});

describe("awakeDuration", () => {
  test.each([
    [0, "0 min"],
    [30, "under 1 min"],
    [2700, "45 min"],
    [7200, "2 h"],
    [4800, "1 h 20 min"],
  ])("%i s -> %s", (s, text) => expect(awakeDuration(s)).toBe(text));
});
