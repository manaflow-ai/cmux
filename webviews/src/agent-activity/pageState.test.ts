// Agent Activity keeps its filter, its layout and the scroll of its lists across a discard.
// The host owns the selection and sends it back in its first snapshot.
import { describe, expect, test } from "bun:test";
import { restoredPageInputs } from "../pages/shared/pageState";
import { pageRoundTrip, scrollOf } from "../pages/shared/pageStateTesting";
import {
  AGENT_ACTIVITY_PAGE,
  activityInputs,
  initialActivityState,
  reduceActivity,
  restoredActivityInputs,
} from "./model";

describe("Agent Activity page state", () => {
  test("a hide, a discard and a restore give the next document the same filter, layout and scroll", () => {
    let state = initialActivityState();
    const trip = pageRoundTrip(AGENT_ACTIVITY_PAGE, {
      scroll: { sessions: 240, events: 800 },
      inputs: () => activityInputs(state),
    });
    state = reduceActivity(state, { type: "filter", value: "claude" });
    state = reduceActivity(state, { type: "layout", value: "timeline" });

    const { client, after } = trip.restore();
    const restored = restoredActivityInputs(restoredPageInputs(client, AGENT_ACTIVITY_PAGE));
    const next = { ...initialActivityState(), ...restored };
    expect(next).toMatchObject({ filter: "claude", layout: "timeline" });
    // The host's first snapshot keeps the page's own filter and layout.
    expect(reduceActivity(next, { type: "snapshot", state: { filter: "", layout: "split" } })).toMatchObject({
      filter: "claude",
      layout: "timeline",
    });
    expect(scrollOf(after, "sessions")).toBe(240);
    expect(scrollOf(after, "events")).toBe(800);
  });

  test("only valid saved fields are taken", () => {
    expect(restoredActivityInputs({ filter: "a", layout: "grid" })).toEqual({ filter: "a", layout: "grid" });
    expect(restoredActivityInputs({ filter: 3, layout: "cards" })).toEqual({});
    expect(restoredActivityInputs(null)).toEqual({});
  });
});
