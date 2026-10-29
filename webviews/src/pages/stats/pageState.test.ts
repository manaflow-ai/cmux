// Stats keeps the range the person picked and its scroll across a discard: the hide
// saves them, and the restored document's store reads that range first.
import { describe, expect, test } from "bun:test";
import { DOCUMENT_SCROLL_KEY } from "../shared/pageState";
import { pageRoundTrip, scrollOf } from "../shared/pageStateTesting";
import { STATS_PAGE, StatsStore, restoredStatsInputs } from "./store";

describe("Stats page state", () => {
  test("a hide, a discard and a restore give the next document the same range and scroll", async () => {
    const store = new StatsStore(null);
    const trip = pageRoundTrip(STATS_PAGE, {
      scroll: { [DOCUMENT_SCROLL_KEY]: 610 },
      inputs: () => store.pageInputs(),
    });
    await store.setRange(7);

    const { client, after } = trip.restore();
    expect(new StatsStore(client).getSnapshot().range).toBe(7);
    expect(scrollOf(after, DOCUMENT_SCROLL_KEY)).toBe(610);
  });

  test("only a known range is taken", () => {
    expect(restoredStatsInputs({ range: 30 })).toEqual({ range: 30 });
    expect(restoredStatsInputs({ range: 5 })).toEqual({});
    expect(restoredStatsInputs({ range: "7" })).toEqual({});
    expect(restoredStatsInputs(null)).toEqual({});
  });
});
