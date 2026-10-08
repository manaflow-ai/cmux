// The per-PR gallery renders only the entries a change reaches (scripts/gallery/touched.ts).
import { expect, test } from "bun:test";
import path from "node:path";
import { closure, loadEntryRoots, touchedEntries, type EntryRoots } from "../scripts/gallery/touched";

const SRC = "/repo/webviews/src";
const files: Record<string, string> = {
  [`${SRC}/pane/Composer.tsx`]: `import "./composer.css";\nimport { send } from "./send";\nexport function Composer() {}`,
  [`${SRC}/pane/composer.css`]: `.composer{}`,
  [`${SRC}/pane/send.ts`]: `export const send = 1; const lazy = () => import("../shared/icons.js");`,
  [`${SRC}/shared/icons.ts`]: `import React from "react";`,
  [`${SRC}/pane/composer.gallery.ts`]: `import { agentPaneEntry } from "../gallery/format";`,
  [`${SRC}/pages/markdown.gallery.ts`]: `import { page } from "./markdown/Page";`,
  [`${SRC}/pages/markdown/Page.tsx`]: `export function Page() {}`,
  [`${SRC}/gallery/format.ts`]: ``,
  [`${SRC}/gallery/frame/agentPane.ts`]: `await import("../../pane/main");`,
  [`${SRC}/pane/main.tsx`]: `import "./app.css";\nimport { Composer } from "./Composer";`,
  [`${SRC}/pane/app.css`]: `.app{}`,
};
const read = (file: string) => files[file];
const entries: EntryRoots[] = [
  {
    id: "agent-pane.composer",
    host: "agent-pane",
    file: `${SRC}/pane/composer.gallery.ts`,
    covers: ["pane/Composer.tsx#Composer"],
  },
  {
    id: "pages.markdown",
    host: "markdown-page",
    file: `${SRC}/pages/markdown.gallery.ts`,
    covers: ["pages/markdown/Page.tsx"],
  },
];
const paneStylesheets = () => [`${SRC}/pane/shipped.css`];
const touched = (changed: string[]) =>
  touchedEntries(entries, changed, { src: SRC, repoRoot: "/repo", read, paneStylesheets });

test("imports are followed through stylesheets, helpers and dynamic imports", () => {
  expect([...closure([`${SRC}/pane/Composer.tsx`], read)].map((f) => path.relative(SRC, f)).sort()).toEqual([
    "pane/Composer.tsx",
    "pane/composer.css",
    "pane/send.ts",
    "shared/icons.ts",
  ]);
});

test("a stylesheet or helper a cover imports touches that entry only", () => {
  expect(touched(["webviews/src/pane/composer.css"])).toEqual({
    all: false,
    entries: ["agent-pane.composer"],
    reasons: { "agent-pane.composer": ["webviews/src/pane/composer.css"] },
  });
  expect(touched(["webviews/src/shared/icons.ts"]).entries).toEqual(["agent-pane.composer"]);
  expect(touched(["webviews/src/pages/markdown.gallery.ts"]).entries).toEqual(["pages.markdown"]);
});

test("a stylesheet the host loads touches every entry of that host, a script does not", () => {
  expect(touched(["webviews/src/pane/app.css"]).entries).toEqual(["agent-pane.composer"]);
  expect(touched(["webviews/src/pane/shipped.css"]).entries).toEqual(["agent-pane.composer"]);
  expect(touched(["webviews/src/pane/main.tsx"]).entries).toEqual([]);
});

test("unrelated files touch nothing; the gallery and build config touch everything", () => {
  expect(touched(["README.md", "webviews/src/other/Thing.tsx"]).entries).toEqual([]);
  const all = touched(["webviews/src/gallery/clock.ts"]);
  expect(all.all).toBe(true);
  expect(all.entries).toEqual(["agent-pane.composer", "pages.markdown"]);
  expect(touched(["webviews/vite.config.gallery.ts"]).all).toBe(true);
});

test("the real composer entry is touched by the agent pane stylesheet", async () => {
  const roots = await loadEntryRoots();
  const result = touchedEntries(roots, ["webviews/src/agent-session/acpmux/styles.css"]);
  expect(result.all).toBe(false);
  expect(result.entries).toContain("agent-pane.composer");
  expect(result.entries).not.toContain("pages.markdown");
});
