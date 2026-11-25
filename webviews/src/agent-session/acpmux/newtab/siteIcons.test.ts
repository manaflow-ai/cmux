// Leo 2026-11-21: "i want to have favicons appear in the search suggestion website results in the new
// tab page... without slowing things down". An address row (a typed address, a top site) and a
// visited page the host sent no icon with draw the site's favicon from what the host already sent:
// its open tabs, history and bookmarks. Nothing is fetched.
import { expect, test } from "bun:test";
import { omnibarContext, siteIcon } from "../omnibar";
import { screenRows } from "./screenModel";

const GITHUB = "data:image/png;base64,Z2l0aHVi";
const REDDIT = "data:image/png;base64,cmVkZGl0";
const ask = { harness: "claude", agent: "Claude Code" };

const omnibar = omnibarContext({
  tabs: [{ id: "t1", kind: "browser", title: "Pull requests", detail: "https://github.com/pulls", icon: GITHUB }],
  history: [
    { url: "https://www.github.com/manaflow-ai/cmux", title: "cmux" },
    { url: "https://example.com/a", title: "Example" },
  ],
  bookmarks: [{ url: "https://www.reddit.com/r/rust", title: "r/rust", icon: REDDIT }],
})!;

test("a typed address draws its site's favicon from an open tab", () => {
  const open = screenRows("github.com/new", { omnibar, ask }).find((row) => row.type === "open");
  expect(open).toMatchObject({ type: "open", icon: GITHUB });
});

test("a top site completion draws a bookmarked site's favicon", () => {
  const open = screenRows("reddit", { omnibar, ask }).find((row) => row.type === "open");
  expect(open).toMatchObject({ type: "open", url: "https://reddit.com", icon: REDDIT });
});

test("a visited page with no icon of its own takes its site's", () => {
  const page = screenRows("github", { omnibar, ask }).find((row) => row.type === "history");
  expect(page).toMatchObject({ type: "history", icon: GITHUB });
});

test("a site the host has no icon for keeps its glyph", () => {
  const rows = screenRows("example.com", { omnibar, ask });
  expect(rows.filter((row) => (row.type === "open" || row.type === "history") && "icon" in row)).toEqual([]);
});

test("bookmarks are read for their icons only, and the host lookup ignores www and paths", () => {
  expect(omnibar.bookmarks).toEqual([{ url: "https://www.reddit.com/r/rust", title: "r/rust", icon: REDDIT }]);
  expect(siteIcon(omnibar, "https://reddit.com/")).toBe(REDDIT);
  expect(siteIcon(omnibar, "about:blank")).toBeUndefined();
  expect(siteIcon(omnibar, "file:///tmp/x")).toBeUndefined();
});
