import { expect, test } from "bun:test";
import { type EntryRoots, touchedEntries } from "../scripts/gallery/touched";

// A small source tree, read from memory: the summary card with its own gallery and stylesheet,
// a neighbour in the same folder, a gallery that names the card, a component two imports away
// from a helper, and an unrelated agent-pane entry that shares only the pane's stylesheets.
const ROOT = "/r";
const SRC = `${ROOT}/webviews/src`;
const files: Record<string, string> = {
  "summary/SummaryCard.tsx": `import "./summary.css";\nimport { edges } from "./scrollEdges";\nimport { GalleryDialog } from "./GalleryDialog";`,
  "summary/summary.css": ".card {}",
  "summary/scrollEdges.ts": "export const edges = 1;",
  "summary/GalleryDialog.tsx": "export const GalleryDialog = 1;",
  "summary/SummaryCard.gallery.ts": `import "../fixtures/acpmux";`,
  "summary/GalleryDialog.gallery.ts": `import "../fixtures/acpmux";`,
  "subagents/subagents.gallery.ts": `// the summary card at the pane's top right (summary/SummaryCard.tsx)\nimport "../fixtures/acpmux";`,
  "composer/Composer.tsx": `import { useEdge } from "./useEdge";`,
  "composer/useEdge.ts": `import { edges } from "../summary/scrollEdges";`,
  "composer/composer.gallery.ts": `import "../fixtures/acpmux";`,
  "context/ComposerContext.tsx": "export const ComposerContext = 1;",
  "context/context.gallery.ts": `import "../fixtures/acpmux";`,
  "fixtures/acpmux.ts": "export const chat = 1;",
  "app.css": "body {}",
};
const read = (file: string) => (file.startsWith(`${SRC}/`) ? files[file.slice(SRC.length + 1)] : undefined);
const entry = (id: string, file: string, covers: string[]): EntryRoots => ({
  id,
  host: "agent-pane",
  file: `${SRC}/${file}`,
  covers,
});
const entries: EntryRoots[] = [
  entry("agent-pane.composer", "composer/composer.gallery.ts", ["composer/Composer.tsx"]),
  entry("agent-pane.composer-context", "context/context.gallery.ts", ["context/ComposerContext.tsx"]),
  entry("agent-pane.gallery-dialog", "summary/GalleryDialog.gallery.ts", ["summary/GalleryDialog.tsx"]),
  entry("agent-pane.subagents", "subagents/subagents.gallery.ts", []),
  entry("agent-pane.summary-card", "summary/SummaryCard.gallery.ts", ["summary/SummaryCard.tsx"]),
];
const options = {
  src: SRC,
  repoRoot: ROOT,
  read,
  paneStylesheets: () => [`${SRC}/summary/summary.css`, `${SRC}/app.css`],
};
const ranked = (changed: string[]) => touchedEntries(entries, changed, options).ranked.map((r) => r.id);

test("a shared stylesheet ranks the component that owns it first, its neighbours next, the rest last", () => {
  // summary.css is a pane stylesheet, so every agent-pane entry is touched (the #21672 case:
  // the old sample filled its cap with composer-context states and none of the summary card).
  const result = touchedEntries(entries, ["webviews/src/summary/summary.css"], options);
  expect(result.entries).toHaveLength(5);
  expect(result.ranked.map((r) => r.id)).toEqual([
    "agent-pane.summary-card",
    "agent-pane.gallery-dialog",
    "agent-pane.composer",
    "agent-pane.composer-context",
    "agent-pane.subagents",
  ]);
  expect(result.ranked[0]).toMatchObject({ tier: 0, why: "own", file: "webviews/src/summary/summary.css" });
  expect(result.ranked[1]).toMatchObject({ why: "same-folder" });
  expect(result.ranked[4]).toMatchObject({ why: "host-stylesheet" });
});

test("a single-component change ranks own source, then a gallery that names it, then importers by distance", () => {
  const result = touchedEntries(
    entries,
    ["webviews/src/summary/SummaryCard.tsx", "webviews/src/summary/scrollEdges.ts"],
    options,
  );
  expect(result.ranked.map((r) => [r.id, r.why, r.distance])).toEqual([
    ["agent-pane.summary-card", "own", 0],
    ["agent-pane.subagents", "names", 0],
    ["agent-pane.composer", "imports", 2],
    ["agent-pane.gallery-dialog", "same-folder", 0],
  ]);
  // An entry that shares nothing with the change is not touched at all.
  expect(result.entries).not.toContain("agent-pane.composer-context");
});

test("a change that re-renders everything still ranks the specific change first", () => {
  const result = touchedEntries(entries, ["bun.lock", "webviews/src/summary/SummaryCard.tsx"], options);
  expect(result.all).toBe(true);
  expect(ranked(["bun.lock", "webviews/src/summary/SummaryCard.tsx"]).slice(0, 2)).toEqual([
    "agent-pane.summary-card",
    "agent-pane.subagents",
  ]);
  expect(result.ranked.at(-1)).toMatchObject({ why: "everything", file: "bun.lock" });
});
