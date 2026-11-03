import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR, omnibarContext, type OmnibarContext } from "../omnibar";
import { actionRows, screenRows } from "./screenModel";

// The New Tab dropdown lists the Commands palette's actions (Lawrence 2026-10-29): the host sends
// every one (`omnibar.actions`), and the rows show those the typed text names.
const many = Array.from({ length: 300 }, (_, index) => ({
  id: `action.${index}`,
  title: `Action number ${index}`,
  keywords: [],
}));

const omnibar: OmnibarContext = omnibarContext({
  ...EMPTY_OMNIBAR,
  actions: [
    { id: "newWindow", title: "New Window", detail: "Windows", keywords: ["window"], keycaps: ["⇧", "⌘", "N"] },
    { id: "toggleSidebar", title: "Toggle Sidebar", detail: "View", keywords: [] },
    { id: "", title: "No id" },
    ...many,
  ],
})!;

test("the host's whole palette list is kept, past the 40-entry cap of the other sources", () => {
  expect(omnibar.actions?.length).toBe(302);
  expect(omnibar.actions?.[0]).toEqual({
    id: "newWindow",
    title: "New Window",
    detail: "Windows",
    keywords: ["window"],
    keycaps: ["⇧", "⌘", "N"],
  });
});

test("an action the text names is a row, best match first", () => {
  expect(actionRows("side", omnibar)).toEqual([
    { type: "action", id: "toggleSidebar", title: "Toggle Sidebar", detail: "View" },
  ]);
  expect(actionRows("new win", omnibar)[0]).toMatchObject({
    type: "action",
    id: "newWindow",
    keycaps: ["⇧", "⌘", "N"],
  });
  // The last of 300 is still found: no cap before the match.
  expect(actionRows("number 299", omnibar)).toEqual([{ type: "action", id: "action.299", title: "Action number 299" }]);
  // Two letters match only a word start.
  expect(actionRows("de", omnibar)).toEqual([]);
});

test("the dropdown shows the action rows under the matches", () => {
  const rows = screenRows("toggle sid", { omnibar, ask: { harness: "claude", agent: "Claude" } });
  expect(rows.map((row) => row.type)).toEqual(["ask", "action", "search"]);
});
