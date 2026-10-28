// The changelog keeps the build the person reads and the scroll of its rail and reader across a
// discard. An update's span is the route's, which the page state puts back itself.
import { describe, expect, test } from "bun:test";
import { pageRoundTrip, scrollOf, withRestore } from "../shared/pageStateTesting";
import { MockChangelogProvider, sampleNotes } from "./mockProvider";
import { CHANGELOG_PAGE, ChangelogStore, restoredChangelogInputs } from "./store";

const older = sampleNotes[1]!.build;

describe("Changelog page state", () => {
  test("a hide, a discard and a restore give the next document the same build and scroll", async () => {
    const store = new ChangelogStore(new MockChangelogProvider());
    const trip = pageRoundTrip(CHANGELOG_PAGE, {
      route: "#/",
      scroll: { rail: 120, reader: 900 },
      inputs: () => store.pageInputs(),
    });
    await store.start();
    await store.select(older);

    const { client, after } = trip.restore();
    const restored = new ChangelogStore(withRestore(new MockChangelogProvider(), client));
    await restored.start();
    expect(restored.getSnapshot().selected).toBe(older);
    expect(scrollOf(after, "rail")).toBe(120);
    expect(scrollOf(after, "reader")).toBe(900);
  });

  test("a saved build the list no longer has falls back to the running build", async () => {
    const trip = pageRoundTrip(CHANGELOG_PAGE, { route: "#/", inputs: () => ({ selected: "gone" }) });
    const { client } = trip.restore();
    const restored = new ChangelogStore(withRestore(new MockChangelogProvider(), client));
    await restored.start();
    expect(restored.getSnapshot().selected).toBe(sampleNotes[0]!.build);
  });

  test("only a build id is taken", () => {
    expect(restoredChangelogInputs({ selected: "1" })).toEqual({ selected: "1" });
    expect(restoredChangelogInputs({ selected: 1 })).toEqual({});
    expect(restoredChangelogInputs({ selected: "" })).toEqual({});
  });
});
