import { expect, test } from "bun:test";
import { derivedTables, type EntryRoots, touchedEntries } from "../scripts/gallery/touched";

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

test("an asset a component loads with new URL(..., import.meta.url) touches the entries that reach it", () => {
  // ChiefDock.tsx loads its mascots this way; the import scan used to miss them, so a changed
  // mascot rendered no entry (review of #36741).
  const dockFiles: Record<string, string> = {
    "dock/ChiefDock.tsx": `const fox = new URL("./mascots/Fox.png", import.meta.url).href;`,
    "dock/mascots/Fox.png": "png",
    "dock/dock.gallery.ts": `import "../fixtures/acpmux";`,
    "fixtures/acpmux.ts": "export const chat = 1;",
  };
  const dockRead = (file: string) => (file.startsWith(`${SRC}/`) ? dockFiles[file.slice(SRC.length + 1)] : undefined);
  const result = touchedEntries(
    [entry("agent-pane.dock", "dock/dock.gallery.ts", ["dock/ChiefDock.tsx"])],
    ["webviews/src/dock/mascots/Fox.png"],
    { ...options, read: dockRead, paneStylesheets: () => [] },
  );
  expect(result.entries).toEqual(["agent-pane.dock"]);
  expect(result.ranked[0]).toMatchObject({ why: "imports", distance: 1 });
});

test("an asset beside an entry but loaded by nothing it reaches places no entry", () => {
  // Folder and name guesses would hide it from unplaced.py's full render (review of #36776).
  const result = touchedEntries(entries, ["webviews/src/summary/SummaryCard.png"], options);
  expect(result.entries).toEqual([]);
});

test("a string catalog under webviews/src that gen-strings.mjs does not list renders every entry", () => {
  const result = touchedEntries(entries, ["webviews/src/summary/Localizable.xcstrings"], options);
  expect(result.all).toBe(true);
  expect(result.entries).toHaveLength(5);
});

// A page's strings table is build output (gen-strings.mjs), absent from a fresh checkout: the routing must
// not need it written. The settings components import it; the component stage loads the pane's table.
const tableFiles: Record<string, string> = {
  "settings/Row.tsx": `import table from "./generated/strings.json";`,
  "settings/row.gallery.tsx": `import "./Row";`,
  "settings/other.gallery.tsx": `import "../fixtures/acpmux";`,
  "fixtures/acpmux.ts": "export const chat = 1;",
  "gallery/frame/component.tsx": `import { installPaneStrings } from "./paneStrings";`,
  "gallery/frame/paneStrings.ts": `const s = (await import("../../pane/generated/strings.json")).default;`,
};
const tableRead = (file: string) => (file.startsWith(`${SRC}/`) ? tableFiles[file.slice(SRC.length + 1)] : undefined);
const tableEntries: EntryRoots[] = [
  { id: "settings.row", host: "component", file: `${SRC}/settings/row.gallery.tsx`, covers: [] },
  { id: "settings.other", host: "component", file: `${SRC}/settings/other.gallery.tsx`, covers: [] },
  { id: "agent-pane.other", host: "agent-pane", file: `${SRC}/settings/other.gallery.tsx`, covers: [] },
];
const SETTINGS = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings";
const pages = {
  settings: { out: "webviews/src/settings/generated/strings.json", catalogs: [{ file: SETTINGS }] },
  pane: {
    out: "webviews/src/pane/generated/strings.json",
    catalogs: [{ file: "webviews/src/pane/Localizable.xcstrings" }],
  },
};
const tableOptions = (changed: string[]) => ({
  ...options,
  read: tableRead,
  paneStylesheets: () => [],
  tables: derivedTables(changed, pages),
});

test("a catalog gen-strings.mjs lists touches only the entries that import its page's table (cmux#49853)", () => {
  // ActionCatalog/Settings catalog pushes rendered all ~13,000 cases for a handful of settings states.
  const result = touchedEntries(tableEntries, [SETTINGS], tableOptions([SETTINGS]));
  expect(result.all).toBe(false);
  expect(result.entries).toEqual(["settings.row"]);
  // unplaced.py reads the reasons: the catalog itself is placed, so it does not fall back to everything.
  expect(result.reasons["settings.row"]).toEqual([SETTINGS]);
  expect(result.ranked[0]).toMatchObject({ why: "imports", distance: 2, file: SETTINGS });
});

test("a table a host's stage loads for every entry touches every entry of that host", () => {
  const changed = ["webviews/src/pane/Localizable.xcstrings"];
  const result = touchedEntries(tableEntries, changed, tableOptions(changed));
  expect(result.all).toBe(false);
  expect(result.entries).toEqual(["settings.other", "settings.row"]);
  expect(result.ranked.map((r) => r.why)).toEqual(["host-table", "host-table"]);
});

test("derivedTables maps catalogs to every page that lists them and highlights to the feature tips", () => {
  const shared = { out: "webviews/src/b/generated/strings.json", catalogs: [{ file: SETTINGS }] };
  expect(derivedTables([SETTINGS, "webviews/src/x.ts"], { ...pages, shared })).toEqual(
    new Map([[SETTINGS, ["webviews/src/b/generated/strings.json", "webviews/src/settings/generated/strings.json"]]]),
  );
  expect(
    derivedTables(["release-notes/next/highlights/prompt-rail-shows.md", "release-notes/next/WRITING.md"]),
  ).toEqual(
    new Map([
      ["release-notes/next/highlights/prompt-rail-shows.md", ["webviews/src/ui/featureTips/tips.generated.json"]],
    ]),
  );
  // The real table lists the Settings catalog for the settings page.
  expect(derivedTables([SETTINGS]).get(SETTINGS)).toContain("webviews/src/pages/settings/generated/strings.json");
});

test("a catalog only an ungalleried page reads touches no entry and is reported as derived", () => {
  const changed = ["Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Resources/Localizable.xcstrings"];
  const sidebar = {
    sidebar: { out: "webviews/src/sidebar/generated/strings.json", catalogs: [{ file: changed[0]! }] },
  };
  const result = touchedEntries(tableEntries, changed, {
    ...tableOptions(changed),
    tables: derivedTables(changed, sidebar),
  });
  expect(result).toMatchObject({ all: false, entries: [], derived: changed });
});
