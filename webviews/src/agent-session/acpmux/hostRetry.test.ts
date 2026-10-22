// After a refusal that offers Restart acpmux (another binary's acpmux holds this app's socket),
// asking the host again cannot connect by itself: the pane asks a few times, then stops and waits
// for the person, instead of the endless Retry loop of 2026-10-22.
import { expect, test } from "bun:test";
import { REFUSED_AUTO_RETRIES, afterHostFailure } from "./hostRetry";

test("the pane stops asking on its own after a few refusals that offer Restart acpmux, never after others", () => {
  const refused = { code: "host_unavailable", details: { restartAcpmux: true } };
  let count = 0;
  const stops: boolean[] = [];
  for (let attempt = 0; attempt <= REFUSED_AUTO_RETRIES; attempt += 1) {
    const next = afterHostFailure(count, refused);
    expect(next.offersRestart).toBe(true);
    count = next.refusedInRow;
    stops.push(next.stopped);
  }
  expect(stops).toEqual([...Array<boolean>(REFUSED_AUTO_RETRIES).fill(false), true]);
  // A daemon that is not running yet, or a timeout, keeps the automatic retries.
  expect(afterHostFailure(count, { code: "host_unavailable" })).toEqual({
    refusedInRow: 0,
    offersRestart: false,
    stopped: false,
  });
});
