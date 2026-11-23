// chat_open.god.compact.attach_to_latest read 89.1, 142.4 and 174.1 ms on three perf cron tips whose pane did the same
// work: the runner's speed, not the code (bench/runnerCalibration.ts). These hold the two computations that make the
// row comparable across runners: the order a round's loads run in, and the per-round quotient by the calibration.
import { describe, expect, test } from "bun:test";
import { median, perCalibration, roundOrder } from "../bench/runnerCalibration";

describe("roundOrder", () => {
  test("three arms take every place once over three rounds", () => {
    const arms = ["small", "god", "calibration"];
    const rounds = [0, 1, 2].map((round) => roundOrder(arms, round));
    for (const arm of arms) expect(new Set(rounds.map((order) => order.indexOf(arm)))).toEqual(new Set([0, 1, 2]));
    expect(rounds[0]).toEqual(["small", "god", "calibration"]);
    expect(rounds[1]).toEqual(["god", "calibration", "small"]);
    expect(roundOrder(arms, 3)).toEqual(rounds[0]!);
  });

  test("two arms alternate, as chat-open's ARMS did; one arm and none stay as they are", () => {
    expect(roundOrder(["off", "compact"], 0)).toEqual(["off", "compact"]);
    expect(roundOrder(["off", "compact"], 1)).toEqual(["compact", "off"]);
    expect(roundOrder(["compact"], 5)).toEqual(["compact"]);
    expect(roundOrder([], 2)).toEqual([]);
  });
});

describe("perCalibration", () => {
  test("the three tips' god rows, each over its own runner's speed, read the same where the raw ms did not", () => {
    // attach_to_latest and dom_content_loaded medians of the three tips (83b6f50f, f5f36064, 824d2970).
    const tips = [
      [89.1, 17.8],
      [142.4, 30.6],
      [174.1, 31.6],
    ].map(([ms, speed]) => perCalibration([ms!], [speed!]));
    expect(tips).toEqual([5.0056, 4.6536, 5.5095]);
    expect(Math.max(...tips) / Math.min(...tips)).toBeLessThan(1.2);
  });

  test("rounds pair by index, so a runner slowing mid-job moves the value and its calibration together", () => {
    // The second half of the job runs at half speed: the raw values double, the quotient does not move.
    expect(perCalibration([100, 100, 100, 200, 200, 200, 200], [20, 20, 20, 40, 40, 40, 40])).toBe(5);
    // Dividing the medians instead would read 200 / 40 = 5 here but 100 / 40 = 2.5 with the halves swapped in count.
    expect(perCalibration([100, 100, 100, 100, 200, 200, 200], [20, 20, 20, 20, 40, 40, 40])).toBe(5);
  });

  test("a real regression still shows: the page doing twice the work on the same runner doubles the quotient", () => {
    const calibration = [20, 21, 19, 20, 22, 20, 20];
    const before = perCalibration([100, 104, 96, 101, 109, 99, 100], calibration);
    const after = perCalibration([200, 208, 192, 202, 218, 198, 200], calibration);
    expect(after / before).toBeCloseTo(2, 5);
  });

  test("a round without a positive calibration or a finite value is left out; none at all is NaN", () => {
    expect(perCalibration([100, 50, 90], [20, 0, Number.NaN])).toBe(5);
    expect(perCalibration([Number.NaN, 60], [10, 20])).toBe(3);
    expect(perCalibration([], [])).toBeNaN();
    expect(perCalibration([1], [0])).toBeNaN();
  });
});

describe("median", () => {
  test("odd, even and empty", () => {
    expect(median([3, 1, 2])).toBe(2);
    expect(median([4, 1, 3, 2])).toBe(2.5);
    expect(median([])).toBeNaN();
  });
});
