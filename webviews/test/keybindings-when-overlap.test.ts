// The recorder's "Also used by" warning follows the app's `WhenClause.canOverlap`: two
// conditions that can hold at once share a key; a key and its negation, or two values of one
// key, do not.
import { expect, test } from "bun:test";
import { whenCanOverlap } from "../src/pages/keybindings/model";

test("when conditions overlap unless a term excludes another", () => {
  expect(whenCanOverlap(null, "surface.kind == 'terminal'")).toBe(true);
  expect(whenCanOverlap("!dialog.open", "surface.kind == 'terminal'")).toBe(true);
  expect(whenCanOverlap("dialog.open", "!dialog.open")).toBe(false);
  expect(whenCanOverlap("surface.kind == 'terminal'", "surface.kind == 'browser'")).toBe(false);
  expect(whenCanOverlap("surface.kind == 'terminal' && !dialog.open", "surface.kind != 'terminal'")).toBe(false);
  expect(whenCanOverlap("a || b", "!a")).toBe(true);
});
