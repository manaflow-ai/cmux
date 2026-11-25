/**
 * Production's CMUX_VM_TEAM_KEYS parses as the Worker parses it: a row the parser refuses disables every team key, so a
 * typo here would refuse our lanes' headless creates after the deploy instead of at review.
 */
import { expect, it } from "vitest";
import wranglerText from "../../wrangler.jsonc?raw";
import { parseTeamKeys } from "../../src/auth/team-keys.ts";

it("production's team keys parse, each held to its team, its labels and its caps", () => {
  const start = wranglerText.indexOf(`"production": {`);
  expect(start).toBeGreaterThan(-1);
  const line = /"CMUX_VM_TEAM_KEYS": ("(?:[^"\\]|\\.)*")/u.exec(wranglerText.slice(start));
  expect(line).not.toBeNull();
  const raw: unknown = JSON.parse(line?.[1] ?? "null");
  if (typeof raw !== "string") throw new Error("CMUX_VM_TEAM_KEYS is not a string");
  const parsed = parseTeamKeys(raw);
  expect(parsed.ok).toBe(true);
  const lanes = parsed.keys.find((key) => key.id === "tk-lanes");
  expect(lanes?.labels).toEqual({ "cmux.team-key": "lanes" });
  expect(lanes?.budget).toMatchObject({ maxVms: 20, maxUsdPerHour: 10 });
});
