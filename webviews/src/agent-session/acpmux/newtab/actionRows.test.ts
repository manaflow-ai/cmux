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

// The palette's pick history (`omnibar.uses`, its FrecencyStore by usage key) orders matches of one
// kind, as the palette does (cmuxterm-hq lenses slack-firefox-frecency.md): the best text match still
// wins, and among equal matches what the person picks often and lately comes first.
test("pick history orders actions of one match tier, never above a better match", () => {
  const bar = omnibarContext({
    ...EMPTY_OMNIBAR,
    actions: [
      { id: "newWindow", title: "New Window", keywords: [] },
      { id: "newTab", title: "New Tab", keywords: [] },
      { id: "renameTab", title: "Rename New", keywords: [] },
    ],
    uses: { "action:newTab": 4, "action:renameTab": 9, bogus: "x", "action:gone": -1 },
  })!;
  expect(bar.uses).toEqual({ "action:renameTab": 9, "action:newTab": 4 });
  expect(actionRows("new", bar).map((row) => (row as { id: string }).id)).toEqual(["newTab", "newWindow", "renameTab"]);
});

test("pick history orders open tabs and workspaces inside their kind", () => {
  const context = (uses?: Record<string, number>) => ({
    omnibar: omnibarContext({
      ...EMPTY_OMNIBAR,
      tabs: [
        { id: "a", kind: "terminal", title: "api server" },
        { id: "b", kind: "terminal", title: "api client" },
      ],
      workspaces: [
        { id: "w1", name: "api one" },
        { id: "w2", name: "api two" },
      ],
      ...(uses ? { uses } : {}),
    })!,
  });
  const ids = (uses?: Record<string, number>) =>
    screenRows("api", context(uses))
      .filter((row) => row.type === "tab" || row.type === "workspace")
      .map((row) => (row as { id: string }).id);
  expect(ids()).toEqual(["a", "b", "w1", "w2"]);
  expect(ids({ "tab:b": 3, "workspace:w2": 1 })).toEqual(["b", "a", "w2", "w1"]);
});
