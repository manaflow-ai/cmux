// The chat header's slot model (headerSlots.ts): accessories take only the room the trailing tools leave, each by its
// own overflow rule, lowest priority first. Leo, 2026-11-22: "the icons on the top right have gotten displaced due to
// putting things on a line. this is not how we should do ui."
import { expect, test } from "bun:test";
import { accessoryRoom, fitAccessories, HEADER_ITEMS, TAB_ROW_GAP, type HeaderItemId } from "./headerSlots";

const item = (id: HeaderItemId, natural: number, gap = 2) => ({ id, natural, gap });

test("every item names a slot and an overflow rule, and every accessory a priority", () => {
  for (const [id, spec] of Object.entries(HEADER_ITEMS)) {
    expect(["leading", "title", "accessory", "trailing"]).toContain(spec.slot);
    expect(["truncate", "collapse", "hide"]).toContain(spec.overflow);
    if (spec.slot === "accessory") expect(typeof (spec as { priority?: number }).priority).toBe("number");
    // Only the quick actions fold into "...".
    if (spec.overflow === "collapse") expect(id).toBe("quickActions");
  }
});

test("with room for all, every accessory keeps its own width", () => {
  const fit = fitAccessories(1000, [item("presence", 40), item("pullRequest", 60), item("inlineSummary", 300)]);
  expect([...fit.values()]).toEqual([undefined, undefined, undefined]);
});

test("short of room, the summary narrows first, down to its least, then hides; a chip hides whole", () => {
  const items = [item("presence", 40), item("pullRequest", 60), item("inlineSummary", 300)];
  // 406 in all with their gaps: 52 short, so the summary narrows by 52.
  expect(fitAccessories(354, items).get("inlineSummary")).toBe(248);
  // Past its least (160) it hides whole; the others keep theirs.
  const tight = fitAccessories(200, items);
  expect(tight.get("inlineSummary")).toBe(0);
  expect(tight.get("presence")).toBeUndefined();
  expect(tight.get("pullRequest")).toBeUndefined();
  // Shorter still: the live tree, then presence, then the pull request chip give way, lowest priority first.
  const tighter = fitAccessories(70, [...items, item("liveTree", 50)]);
  expect(tighter.get("liveTree")).toBe(0);
  expect(tighter.get("presence")).toBe(0);
  expect(tighter.get("pullRequest")).toBeUndefined();
  expect([...fitAccessories(0, items).values()]).toEqual([0, 0, 0]);
});

test("the Needs You count gives way last: every other accessory hides before it", () => {
  const fit = fitAccessories(40, [item("presence", 40), item("pullRequest", 60), item("needsYouCount", 36, 0)]);
  expect(fit.get("needsYouCount")).toBeUndefined();
  expect(fit.get("presence")).toBe(0);
  expect(fit.get("pullRequest")).toBe(0);
  expect(fitAccessories(20, [item("needsYouCount", 36, 0)]).get("needsYouCount")).toBe(0);
});

test("the tab row gives the accessories the half the tabs give up, less the tools", () => {
  expect(accessoryRoom("tab-row", 1000, 120, 0)).toBe(500 - 120 - TAB_ROW_GAP);
  expect(accessoryRoom("tab-row", 200, 120, 0)).toBe(0);
  // Its own row keeps the title's reserve (120) and the row's gap.
  expect(accessoryRoom("own-row", 1000, 120, 8)).toBe(1000 - 8 - 120 - 120);
});
