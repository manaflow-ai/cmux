// The Markdown page's toolbar names its file only when the native omnibar does not: with the
// omnibar above the page (config `omnibar: true`, plans/cmux-next/markdown-omnibar-DESIGN.md
// section 2) the full path is already in the omnibar, so the page shows no file name; a followed
// link still says it is loading, and a page without the omnibar keeps the file name.
import { expect, test } from "bun:test";
import { toolbarFileLabel } from "../src/pages/markdown/toolbarFile";

const loading = "Loading…";

test("without the omnibar the toolbar names the file", () => {
  expect(toolbarFileLabel({ path: "/Users/me/notes/plan.md" }, { loading: false, navigating: null }, loading)).toBe(
    "plan.md",
  );
  expect(toolbarFileLabel(undefined, { loading: true, navigating: null }, loading)).toBe(loading);
  expect(toolbarFileLabel({ path: "/a/b.md" }, { loading: false, navigating: "/a/c.md" }, loading)).toBe("c.md");
});

test("with the omnibar the toolbar shows no file name", () => {
  expect(
    toolbarFileLabel({ path: "/Users/me/notes/plan.md", omnibar: true }, { loading: false, navigating: null }, loading),
  ).toBeNull();
  expect(toolbarFileLabel({ path: "/a/b.md", omnibar: true }, { loading: false, navigating: "/a/c.md" }, loading)).toBe(
    loading,
  );
});
