import { sameJson } from "../sameJson";

/// `memo`'s compare for a row that draws one Needs you item (NeedsYou.tsx, HomeInbox.tsx): the item
/// by value, every other prop by identity. The items are rebuilt from each snapshot (needsYouItems),
/// so an ask that did not change is a new object with the same fields, and its row draws nothing.
export function sameItemRowProps<P extends { item: unknown }>(before: P, after: P): boolean {
  for (const key in after) if (key !== "item" && !Object.is(before[key], after[key])) return false;
  for (const key in before) if (!(key in after)) return false;
  return sameJson(before.item, after.item);
}
