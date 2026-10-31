import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR, omnibarContext, type OmnibarContext } from "../omnibar";
import { type ActionStates, actionCandidates, actionRows, screenRows } from "./screenModel";

// The New Tab dropdown lists the Commands palette's actions (Lawrence 2026-10-29): the host sends its catalog
// (`omnibar.actions`, no availability), the rows show those the typed text names, and only those the host says
// run now (`newTab.actionStates`).
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

/// Every action enabled, with its catalog title: the host's answer when everything runs.
const allOn = (query: string): ActionStates =>
  Object.fromEntries(
    actionCandidates(query, omnibar).map((action) => [action.id, { enabled: true, title: action.title }]),
  );

test("an action the text names is a row, best match first", () => {
  expect(actionRows("side", omnibar, allOn("side"))).toEqual([
    { type: "action", id: "toggleSidebar", title: "Toggle Sidebar", detail: "View" },
  ]);
  expect(actionRows("new win", omnibar, allOn("new win"))[0]).toMatchObject({
    type: "action",
    id: "newWindow",
    keycaps: ["⇧", "⌘", "N"],
  });
  // The last of 300 is still found: no cap before the match.
  expect(actionRows("number 299", omnibar, allOn("number 299"))).toEqual([
    { type: "action", id: "action.299", title: "Action number 299" },
  ]);
  // Two letters match only a word start.
  expect(actionRows("de", omnibar, allOn("de"))).toEqual([]);
});

test("the dropdown shows the action rows under the matches", () => {
  const rows = screenRows("toggle sid", {
    omnibar,
    ask: { harness: "claude", agent: "Claude" },
    actionStates: allOn("toggle sid"),
  });
  expect(rows.map((row) => row.type)).toEqual(["ask", "action", "search"]);
});

test("no action row without the host's states, and none the host says cannot run", () => {
  // Before the states are in there is no action row (the screen holds the previous rows meanwhile).
  expect(actionRows("new win", omnibar, undefined)).toEqual([]);
  // A candidate the host says cannot run is no row; a candidate it left out (not listed here) is none either.
  expect(actionRows("new win", omnibar, { newWindow: { enabled: false, title: "New Window" } })).toEqual([]);
  expect(actionRows("side", omnibar, {})).toEqual([]);
});

test("a row shows the host's current title (a toggle reads as the change it makes)", () => {
  expect(actionRows("side", omnibar, { toggleSidebar: { enabled: true, title: "Hide Sidebar" } })).toEqual([
    { type: "action", id: "toggleSidebar", title: "Hide Sidebar", detail: "View" },
  ]);
});

test("a match that cannot run leaves room for the next one", () => {
  const states: ActionStates = Object.fromEntries(
    actionCandidates("number", omnibar).map((action, index) => [
      action.id,
      { enabled: index > 0, title: action.title },
    ]),
  );
  const rows = actionRows("number", omnibar, states);
  expect(rows.length).toBe(3);
  expect(rows.map((row) => (row.type === "action" ? row.id : ""))).not.toContain(
    actionCandidates("number", omnibar)[0]?.id,
  );
});
