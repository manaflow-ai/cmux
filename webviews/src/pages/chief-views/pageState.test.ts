// The Chief view gallery keeps whether the gallery is open and its scroll across a discard.
// Its layout (views on, the pane and the side) lives in localStorage already.
import { describe, expect, test } from "bun:test";
import { DOCUMENT_SCROLL_KEY, restoredPageInputs } from "../shared/pageState";
import { pageRoundTrip, scrollOf } from "../shared/pageStateTesting";
import { CHIEF_VIEWS_PAGE, ChiefViewsStore, restoredChiefViewsInputs } from "./store";

const views = [
  { id: "agents", defaultOn: true },
  { id: "fleet", defaultOn: false },
];

describe("Chief view gallery page state", () => {
  test("a hide, a discard and a restore give the next document the open gallery and scroll", () => {
    const store = new ChiefViewsStore(null, views, { persist: false });
    const trip = pageRoundTrip(CHIEF_VIEWS_PAGE, {
      scroll: { [DOCUMENT_SCROLL_KEY]: 300 },
      inputs: () => store.pageInputs(),
    });
    expect(store.getSnapshot().catalog).toBe(false);
    store.setCatalog(true);

    const { client, after } = trip.restore();
    const restored = new ChiefViewsStore(client, views, {
      persist: false,
      ...restoredChiefViewsInputs(restoredPageInputs(client, CHIEF_VIEWS_PAGE)),
    });
    expect(restored.getSnapshot().catalog).toBe(true);
    expect(scrollOf(after, DOCUMENT_SCROLL_KEY)).toBe(300);
  });

  test("only a boolean is taken", () => {
    expect(restoredChiefViewsInputs({ catalog: false })).toEqual({ catalog: false });
    expect(restoredChiefViewsInputs({ catalog: "yes" })).toEqual({});
    expect(restoredChiefViewsInputs(undefined)).toEqual({});
  });
});
