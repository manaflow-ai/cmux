// The takeaway rule's source is the daemon (acpmux-book translate/fold.rs `Reply::takeaway`,
// translate/narration.rs; transcript motion model step 9, "The daemon owns shape"). The page's
// `isTakeaway` reads the same cases the daemon's test does, so the two cannot drift again.
import { expect, test } from "bun:test";
import cases from "../../../../../cmux-tui/crates/acpmux-book/src/translate/fixtures/takeaway-cases.json";
import { isTakeaway } from "./turns";

test("the page's takeaway rule agrees with the daemon's on every shared case", () => {
  expect(cases.length).toBeGreaterThan(20);
  const differ = cases.filter(
    (entry) => isTakeaway({ id: "r", version: 1, at: 0, kind: "assistant", text: entry.text }) !== entry.takeaway,
  );
  expect(differ).toEqual([]);
});
