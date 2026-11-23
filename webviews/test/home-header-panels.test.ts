// The Home transcript header's toggles (`HeaderPanelBar.tsx`). Share Screen with Chief is gone
// (Lawrence 2026-11-20: "remove share screen with chief"): a Chief's header has no screen share
// toggle, and the Debug switch that hides the cluster now hides every toggle.
import { expect, test } from "bun:test";
import { HEADER_PANELS, headerPanelItems } from "../src/pages/home-messages/cards/header/HeaderPanelBar";
import { cardStrings } from "../src/pages/home-messages/cards/strings";

const strings = cardStrings(["en"]);

test("a Chief's header has no Share Screen with Chief toggle", () => {
  expect(HEADER_PANELS.map((panel) => panel.id)).not.toContain("screenShare");
  const ids = headerPanelItems({ isChief: true }, [], strings, true).map((item) => item.id);
  expect(ids).toEqual(["memory", "rightSidebar"]);
});

test("the Debug switch hides every toggle", () => {
  expect(headerPanelItems({ isChief: true }, [{ id: "screenShare", isOn: true }], strings, false)).toEqual([]);
});
