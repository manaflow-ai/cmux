// The new chat strip's kept slot (locationRow.ts `stripSlot`, Composer.tsx). It held 46px under the
// hat for the whole chat: the plan's hat stood that far over the composer card (Lucas, 2026-11-12:
// "its completely detached").
import { expect, test } from "bun:test";
import { stripSlot, type StripSlot } from "./locationRow";

const CHAT = "chat-1";

function sent(stackAbove = false) {
  const shown = stripSlot({}, { visible: true, session: CHAT, queued: false, stackAbove: false }).slot;
  return stripSlot(shown, { visible: false, session: CHAT, queued: false, stackAbove });
}

test("the first send keeps the strip's slot while nothing stands over the composer", () => {
  expect(sent().keep).toBe(true);
});

test("a part over the composer ends the slot, and it does not come back when the part goes", () => {
  const under = sent(true);
  expect(under.keep).toBe(false);
  const after = stripSlot(under.slot, { visible: false, session: CHAT, queued: false, stackAbove: false });
  expect(after.keep).toBe(false);
});

test("another chat never takes the slot; a queue hides it without ending it", () => {
  const held: StripSlot = sent().slot;
  expect(stripSlot(held, { visible: false, session: "chat-2", queued: false, stackAbove: false }).keep).toBe(false);
  const queued = stripSlot(held, { visible: false, session: CHAT, queued: true, stackAbove: false });
  expect(queued.keep).toBe(false);
  expect(stripSlot(queued.slot, { visible: false, session: CHAT, queued: false, stackAbove: false }).keep).toBe(true);
});
