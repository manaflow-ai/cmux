// Chief Usage keeps the window and grouping the person picked and its scroll across a discard:
// the hide saves them, and the restored document's store reads them first.
import { describe, expect, test } from "bun:test";
import { DOCUMENT_SCROLL_KEY, restoredPageInputs } from "../shared/pageState";
import { pageRoundTrip, scrollOf } from "../shared/pageStateTesting";
import { CHIEF_USAGE_PAGE, ChiefUsageStore, restoredChiefUsageInputs } from "./store";

describe("Chief Usage page state", () => {
  test("a hide, a discard and a restore give the next document the same choices and scroll", async () => {
    const store = new ChiefUsageStore(null);
    const trip = pageRoundTrip(CHIEF_USAGE_PAGE, {
      scroll: { [DOCUMENT_SCROLL_KEY]: 450 },
      inputs: () => store.pageInputs(),
    });
    await store.setWindow("90d");
    await store.setBy("model");

    const { client, after } = trip.restore();
    const restored = new ChiefUsageStore(
      client,
      restoredChiefUsageInputs(restoredPageInputs(client, CHIEF_USAGE_PAGE)),
    );
    expect(restored.getSnapshot()).toMatchObject({ window: "90d", by: "model" });
    expect(scrollOf(after, DOCUMENT_SCROLL_KEY)).toBe(450);
  });

  test("only known choices are taken", () => {
    expect(restoredChiefUsageInputs({ window: "30d", by: "kind" })).toEqual({ window: "30d", by: "kind" });
    expect(restoredChiefUsageInputs({ window: "2d", by: "team" })).toEqual({});
    expect(restoredChiefUsageInputs("7d")).toEqual({});
  });
});
