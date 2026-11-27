// The one open-state store (disclosureStore.ts; docs/design/transcript-motion-model.md, step 5 "One
// disclosure"): the message, card and thought stores keep their values in it, one listener set hears
// every change, and each change is credited to the row it shows in (`rowRevision`).
import { afterEach, expect, test } from "bun:test";
import { cardOpen, setCardOpen } from "../turnChanges/openStore";
import {
  disclosureRevision,
  notifyDisclosure,
  resetPageSpaces,
  rowRevision,
  subscribeDisclosure,
} from "./disclosureStore";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import { forgetThoughtChoices, thoughtChoices } from "./thoughtChoices";

afterEach(() => resetPageSpaces());

test("every store's change reaches the one listener set, and an unchanged write none", () => {
  let heard = 0;
  const stop = subscribeDisclosure(() => (heard += 1));
  setMessageOpened("chat", "m1", true);
  setCardOpen("card-row", true);
  thoughtChoices.set("row1:thought:0", true);
  expect(heard).toBe(3);
  setCardOpen("card-row", true);
  thoughtChoices.set("row1:thought:0", true);
  expect(heard).toBe(3);
  stop();
  setCardOpen("card-row", false);
  expect(heard).toBe(3);
  expect(messageOpened("chat", "m1")).toBe(true);
  expect(cardOpen("card-row")).toBe(false);
});

test("a change is credited to its row: the list's state signature for that row moves, no other's", () => {
  const before = rowRevision("chat", "row1");
  const other = rowRevision("chat", "row2");
  thoughtChoices.set("thinking:row1:thought:2", true);
  const afterThought = rowRevision("chat", "row1");
  expect(afterThought).toBeGreaterThan(before);
  // A thought's choice is kept in no chat: it counts for its row in every chat and view.
  expect(rowRevision("chat#verbose", "row1")).toBe(afterThought);
  expect(rowRevision("chat", "row2")).toBe(other);
  setCardOpen("row2", true);
  expect(rowRevision("chat", "row2")).toBeGreaterThan(other);
  // A message's key names its row before the NUL.
  setMessageOpened("chat", "row3\u0000thread", true);
  expect(rowRevision("chat", "row3")).toBe(disclosureRevision());
  expect(rowRevision("other-chat", "row3")).toBe(0);
});

test("a view's own change counts for its chat; forgetting thoughts notifies once and credits their rows", () => {
  notifyDisclosure("chat#thinking", ["row9"]);
  expect(rowRevision("chat", "row9")).toBe(disclosureRevision());
  thoughtChoices.set("rowA:thought:0", true);
  thoughtChoices.set("rowB:thought:1", true);
  thoughtChoices.set("rowC:thought:0", false);
  let heard = 0;
  const stop = subscribeDisclosure(() => (heard += 1));
  forgetThoughtChoices((id) => id.startsWith("rowA") || id.startsWith("rowB"));
  stop();
  expect(heard).toBe(1);
  expect(thoughtChoices.has("rowA:thought:0")).toBe(false);
  expect(thoughtChoices.get("rowC:thought:0")).toBe(false);
  expect(rowRevision("chat", "rowA")).toBe(disclosureRevision());
  expect(rowRevision("chat", "rowB")).toBe(disclosureRevision());
});
