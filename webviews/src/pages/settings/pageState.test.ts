// Settings keeps its route (section, search, Changed filter, focus) and the scroll of its section
// list and content across a discard. Every input is the route's; a form with typed
// values keeps its tab from being discarded (useUnsavedForm), so no other input is saved.
import { describe, expect, test } from "bun:test";
import { restoredPageInputs } from "../shared/pageState";
import { pageRoundTrip, scrollOf } from "../shared/pageStateTesting";
import { SETTINGS_PAGE } from "./mount";
import { parseSettingsSearch } from "./router";

describe("Settings page state", () => {
  test("a hide, a discard and a restore give the next document the same route and scroll", () => {
    const trip = pageRoundTrip(SETTINGS_PAGE, {
      route: "#/settings/appearance",
      scroll: { sections: 90, content: 1400 },
    });
    trip.before.hash = "#/settings/terminal?q=font&changed=1";

    const { client, after } = trip.restore();
    expect(after.hash).toBe("#/settings/terminal?q=font&changed=1");
    expect(parseSettingsSearch(after.hash.split("?")[1] ?? "")).toEqual({ q: "font", changed: "1" });
    expect(restoredPageInputs(client, SETTINGS_PAGE)).toBeUndefined();
    expect(scrollOf(after, "sections")).toBe(90);
    expect(scrollOf(after, "content")).toBe(1400);
  });
});
