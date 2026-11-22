import { expect, test } from "bun:test";
import { WAITING_STEER_IDS, WAITING_STEERS_SNAPSHOT, waitingSteersRows } from "./waitingSteersFixture";

test("the waiting-steers fixture is a running turn then three waiting steers, the newest carrying Send now", () => {
  const rows = waitingSteersRows(0);
  const steers = rows.filter((row) => row.steer === "waiting");
  expect(steers.map((row) => row.id)).toEqual([...WAITING_STEER_IDS]);
  // Oldest first, each with its own promptId, so Send now and the X have a prompt to act on.
  expect(steers.every((row, index) => index === 0 || row.at > steers[index - 1]!.at)).toBe(true);
  expect(new Set(steers.map((row) => row.steerPromptId)).size).toBe(3);
  expect(rows.find((row) => row.kind === "assistant")?.streaming).toBe(true);
  expect(WAITING_STEERS_SNAPSHOT.newestOwnSteer).toBe(steers.at(-1)!.id);
  expect(WAITING_STEERS_SNAPSHOT.waitingSteers).toEqual(steers.map((row) => row.id));
  expect(WAITING_STEERS_SNAPSHOT.summary.backgroundsWork).toBe(true);
});
