import { expect, test } from "bun:test";
import { catalogTables, changedKeys } from "../scripts/gallery/catalogs";
import { bundledFiles, misses, routed } from "../scripts/gallery/route-check";
import { type EntryRoots, reachableFiles, touchedEntries } from "../scripts/gallery/touched";

// cmuxterm-hq#12794: a string catalog change rendered every gallery entry. It now renders the entries whose
// page tables take a changed key, and none when no rendered table does.
const catalog = (strings: Record<string, string>) =>
  JSON.stringify({
    strings: Object.fromEntries(
      Object.entries(strings).map(([key, value]) => [key, { localizations: { en: { stringUnit: { value } } } }]),
    ),
  });
const PAGES = {
  settings: {
    out: "webviews/src/pages/settings/generated/strings.json",
    catalogs: [
      {
        file: "Packages/Settings/Localizable.xcstrings",
        keys: (all: string[]) => all.filter((key) => key.startsWith("settingsPage.")),
      },
    ],
  },
  debug: {
    out: "webviews/src/pages/debug/generated/strings.json",
    catalogs: [
      {
        file: "Packages/Settings/Localizable.xcstrings",
        keys: (all: string[]) => all.filter((key) => key.startsWith("debugSettings.")),
      },
    ],
  },
  stash: {
    out: "webviews/src/pages/stash/generated/strings.json",
    catalogs: [{ file: "webviews/src/pages/stash/Localizable.xcstrings" }],
  },
};
const SETTINGS = "Packages/Settings/Localizable.xcstrings";
const STASH = "webviews/src/pages/stash/Localizable.xcstrings";

test("changed keys are the added, removed and edited ones", () => {
  const base = catalog({ a: "A", b: "B", c: "C" });
  const head = catalog({ a: "A", b: "B2", d: "D" });
  expect([...changedKeys(head, base)!].sort()).toEqual(["b", "c", "d"]);
  expect(changedKeys("{not json", base)).toBeUndefined();
  expect([...changedKeys(head, undefined)!].sort()).toEqual(["a", "b", "d"]);
});

test("a catalog reaches only the page tables whose keys changed", () => {
  const texts = {
    head: {
      [SETTINGS]: catalog({ "settingsPage.title": "Settings!", "debugSettings.reset": "Reset", "swift.only": "x" }),
    },
    base: {
      [SETTINGS]: catalog({ "settingsPage.title": "Settings", "debugSettings.reset": "Reset", "swift.only": "x" }),
    },
  };
  const route = catalogTables(
    [SETTINGS],
    (p) => texts.head[p],
    (p) => texts.base[p],
    PAGES,
  );
  expect(route).toEqual({
    tables: { "webviews/src/pages/settings/generated/strings.json": [SETTINGS] },
    inert: [],
    global: [],
  });
  // A Swift-only key reaches no page table: the catalog renders nothing.
  const swift = catalogTables(
    [SETTINGS],
    () => catalog({ "settingsPage.title": "Settings", "swift.only": "y" }),
    () => catalog({ "settingsPage.title": "Settings", "swift.only": "x" }),
    PAGES,
  );
  expect(swift).toEqual({ tables: {}, inert: [SETTINGS], global: [] });
});

test("a catalog no page lists, or one that is not JSON, stays global", () => {
  const unlisted = "Packages/Other/Localizable.xcstrings";
  expect(
    catalogTables(
      [unlisted],
      () => catalog({ a: "1" }),
      () => catalog({}),
      PAGES,
    ).global,
  ).toEqual([unlisted]);
  expect(
    catalogTables(
      [STASH],
      () => "<<<<<<< conflict",
      () => catalog({}),
      PAGES,
    ).global,
  ).toEqual([STASH]);
});

// A small tree: a settings entry importing its table, a stash page whose table no entry imports, and an
// agent-pane entry whose frame (not the entry) loads the pane's table and mounts the pane.
const ROOT = "/r";
const SRC = `${ROOT}/webviews/src`;
const files: Record<string, string> = {
  "pages/settings/Row.gallery.tsx": `import table from "./generated/strings.json";`,
  "pages/settings/generated/strings.json": "{}",
  "pages/stash/main.tsx": `import table from "./generated/strings.json";`,
  "pages/stash/generated/strings.json": "{}",
  "agent-session/acpmux/composer/composer.gallery.ts": `export default {};`,
  "agent-session/acpmux/mountModel.ts": `import { Pane } from "./Pane";`,
  "agent-session/acpmux/Pane.tsx": `export const Pane = 1;`,
  "agent-session/acpmux/generated/strings.json": "{}",
  "gallery/frame/agentPane.ts": `const s = await import("../../agent-session/acpmux/generated/strings.json");\nawait import("../../agent-session/acpmux/mountModel");`,
};
const read = (file: string) => (file.startsWith(`${SRC}/`) ? files[file.slice(SRC.length + 1)] : undefined);
const entries: EntryRoots[] = [
  { id: "settings.row", host: "component", file: `${SRC}/pages/settings/Row.gallery.tsx`, covers: [] },
  {
    id: "agent-pane.composer",
    host: "agent-pane",
    file: `${SRC}/agent-session/acpmux/composer/composer.gallery.ts`,
    covers: [],
  },
];
const options = { src: SRC, repoRoot: ROOT, read, paneStylesheets: () => [] };

test("a routed catalog renders the entries that import its table, and an unrendered table renders nothing", () => {
  const settings = touchedEntries(entries, [SETTINGS], {
    ...options,
    catalogs: { tables: { "webviews/src/pages/settings/generated/strings.json": [SETTINGS] }, inert: [], global: [] },
  });
  expect(settings).toMatchObject({ all: false, entries: ["settings.row"], inert: [] });
  expect(settings.reasons["settings.row"]).toEqual([SETTINGS]);
  const stash = touchedEntries(entries, [STASH], {
    ...options,
    catalogs: { tables: { "webviews/src/pages/stash/generated/strings.json": [STASH] }, inert: [], global: [] },
  });
  expect(stash).toMatchObject({ all: false, entries: [], inert: [STASH] });
  // Without a route (no --base) a catalog renders everything, as before.
  expect(touchedEntries(entries, [STASH], options).all).toBe(true);
  expect(
    touchedEntries(entries, [SETTINGS], { ...options, catalogs: { tables: {}, inert: [], global: [SETTINGS] } }).all,
  ).toBe(true);
});

test("a module the host frame loads touches every entry of that host", () => {
  // Before, a change to the pane's own code reached only entries that import it, though every agent-pane
  // entry mounts it through gallery/frame/agentPane.ts.
  const result = touchedEntries(entries, ["webviews/src/agent-session/acpmux/Pane.tsx"], options);
  expect(result.entries).toEqual(["agent-pane.composer"]);
  expect(result.ranked[0]).toMatchObject({ why: "host-frame" });
});

test("a stage module many hosts share touches them through its static imports only", () => {
  // pages.ts mounts every *-page host: its static imports load for each, a host's own page comes through a
  // dynamic import() in that host's mount function.
  const pageFiles: Record<string, string> = {
    "gallery/frame/pages.ts": `import { MockApps } from "../../pages/apps/mockProvider";\nexport async function mountSettingsPage() { await import("../../pages/settings/main"); }`,
    "pages/apps/mockProvider.ts": "export const MockApps = 1;",
    "pages/settings/main.tsx": "export const main = 1;",
    "pages/settings/Card.gallery.tsx": "export default {};",
  };
  const pageRead = (file: string) => (file.startsWith(`${SRC}/`) ? pageFiles[file.slice(SRC.length + 1)] : undefined);
  const settings: EntryRoots[] = [
    { id: "settings.card", host: "settings-page", file: `${SRC}/pages/settings/Card.gallery.tsx`, covers: [] },
  ];
  const opts = { src: SRC, repoRoot: ROOT, read: pageRead, paneStylesheets: () => [] };
  expect(touchedEntries(settings, ["webviews/src/pages/apps/mockProvider.ts"], opts).ranked[0]).toMatchObject({
    id: "settings.card",
    why: "host-frame",
  });
  // The settings page itself is the same folder here, not the shared stage.
  expect(touchedEntries(settings, ["webviews/src/pages/settings/main.tsx"], opts).ranked[0]?.why).toBe("same-folder");
});

test("the route check names a bundled file the paths or touched.ts miss", () => {
  const meta = {
    outputs: {
      "chunks/a.js": {
        inputs: {
          [`${SRC}/agent-session/acpmux/Pane.tsx`]: {},
          [`${SRC}/pages/stash/main.tsx`]: {},
          [`${ROOT}/schemas/new/thing.json`]: {},
          [`${ROOT}/webviews/node_modules/react/index.js`]: {},
          "\0vite/preload-helper": {},
        },
      },
    },
  };
  const bundled = bundledFiles(meta, ROOT);
  expect(bundled).toEqual([
    "schemas/new/thing.json",
    "webviews/src/agent-session/acpmux/Pane.tsx",
    "webviews/src/pages/stash/main.tsx",
  ]);
  const { reachable, broad } = reachableFiles(entries, options);
  const found = misses(bundled, ["webviews/src/**", "!webviews/src/**/*.test.ts"], reachable, broad, ROOT);
  expect(found.map((miss) => miss.file)).toEqual(["schemas/new/thing.json", "webviews/src/pages/stash/main.tsx"]);
  expect(found[0]!.why).toContain("paths");
  expect(found[1]!.why).toContain("touched.ts places it on no entry");
});

test("routed follows GitHub's last-match rule", () => {
  const patterns = ["webviews/src/**", "!webviews/src/**/*.test.ts", "webviews/src/keep.test.ts"];
  expect(routed("webviews/src/a/b.tsx", patterns)).toBe(true);
  expect(routed("webviews/src/a/b.test.ts", patterns)).toBe(false);
  expect(routed("webviews/src/keep.test.ts", patterns)).toBe(true);
  expect(routed("web/x.ts", patterns)).toBe(false);
});
