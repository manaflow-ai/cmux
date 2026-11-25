// A chat hidden with `quietHidden` hears no `session/update` while hidden, but its turn ends and
// status still move the page's cursor past the chunks it never got. The show's `_acpmux/lagged`
// names where the first one left out was (`afterSeq`); the lag read starts at the older of the two,
// so every chunk comes back (cmux#44453 review: a read from the cursor lost the hidden turn's text).
import { expect, test } from "bun:test";
import { lagCursor } from "./direct";

test("a hidden lag reads from the notice's afterSeq when the cursor moved past it", () => {
  expect(lagCursor({ reason: "hidden", sessionIds: ["s"], dropped: 50, afterSeq: 12 }, 70)).toBe(12);
});

test("a lag notice with no afterSeq, or a newer one, reads from the page's cursor", () => {
  expect(lagCursor({ dropped: 4, sessionIds: ["s"] }, 70)).toBe(70);
  expect(lagCursor({ reason: "hidden", afterSeq: 90 }, 70)).toBe(70);
  expect(lagCursor({ afterSeq: "12" }, 70)).toBe(70);
  expect(lagCursor({ afterSeq: -1 }, 70)).toBe(70);
  expect(lagCursor(undefined, 70)).toBe(70);
});

test("afterSeq 0 reads the chat from its start", () => {
  expect(lagCursor({ reason: "hidden", afterSeq: 0 }, 70)).toBe(0);
});
