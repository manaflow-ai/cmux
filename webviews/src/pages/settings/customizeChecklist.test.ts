// The Customize checklist's model (Leo, 2026-11-22, ask-931361017e: "it should just be as easy as a
// click toggle"): rows come from the schema by key, never a kept list; each group counts its own
// switches; one search filters every group; the verified looks are every examples/looks and
// examples/recipes folder with a setup, so a new look shows with no edit.
import { expect, test } from "bun:test";
import {
  CHECKLIST_GROUPS,
  checklistGroups,
  filterGroups,
  settingGroup,
  setupEntryName,
  shortLine,
  sidebarLookOf,
  stripJsonComments,
  toggleRowsByGroup,
  totals,
  verifiedLooks,
  type ChecklistInput,
} from "./customizeChecklist";
import type { LibraryEntry } from "./ops";
import type { SchemaRow } from "./schema";

const row = (key: string, kind: SchemaRow["kind"] = "toggle", summary: string | null = null): SchemaRow =>
  ({
    key,
    path: key.split("."),
    section: key.split(".")[0]!,
    group: { text: "Group" },
    title: { text: `Title ${key}` },
    help: { text: `Long help for ${key}.` },
    summary: summary === null ? null : { text: summary },
    kind,
    default: false,
    default_label: null,
    keywords: [],
    agent_settable: true,
    kept_on_reset_all: false,
    consumers: [],
  }) as unknown as SchemaRow;

const entry = (name: string, on: boolean, words: string[] = []): LibraryEntry => ({
  position: 1,
  name,
  on,
  source: "ask",
  words,
  description: "",
  thumbnail: { swatches: [], keys: [] },
  settings: ["appearance.theme"],
  files: [],
  added_ms: null,
  overridden: [],
});

const index = {
  repository: "github.com/manaflow-ai/cmux",
  ref: "feat-cmux-next",
  root: "examples",
  entries: [
    { kind: "look", path: "looks/ember" },
    { kind: "look", path: "looks/waiting", needs: "cmux#1" },
  ],
};

const setup = (id: string, name: string, tagline = "") =>
  `// a comment\n{\n  "id": "${id}", /* inline */\n  "name": "${name}",\n  "tagline": "${tagline}",\n}\n`;

test("each toggle goes to its group by key; other kinds and hidden rows stay out", () => {
  expect(settingGroup("experiments.agentBadges")).toBe("experiments");
  expect(settingGroup("labs.liveTree")).toBe("labs");
  expect(settingGroup("customize.fromTheApp")).toBe("labs");
  expect(settingGroup("appearance.compact")).toBe("all");
  const rows = [
    row("experiments.a"),
    row("experiments.slider", "number"),
    row("labs.b"),
    row("customize.fromTheApp"),
    row("browser.c"),
    row("hidden.d"),
  ];
  const grouped = toggleRowsByGroup(rows, (each) => !each.key.startsWith("hidden."));
  expect(grouped.experiments.map((each) => each.key)).toEqual(["experiments.a"]);
  expect(grouped.labs.map((each) => each.key)).toEqual(["labs.b", "customize.fromTheApp"]);
  expect(grouped.all.map((each) => each.key)).toEqual(["browser.c"]);
});

function input(overrides: Partial<ChecklistInput> = {}): ChecklistInput {
  const looks = verifiedLooks(
    index,
    new Map([
      ["looks/ember", setup("manaflow-ai/ember-look", "Ember", "Warm.")],
      ["recipes/focus", setup("manaflow-ai/focus", "Focus")],
    ]),
  );
  return {
    rows: toggleRowsByGroup(
      [row("experiments.a", "toggle", "A short line"), row("labs.b"), row("browser.c")],
      () => true,
    ),
    value: (key) => key === "experiments.a",
    locked: (key) => (key === "browser.c" ? "Set by your team" : null),
    library: {
      entries: [entry("night", true, ["a darker theme at night"]), entry("setup-manaflow-ai-ember-look", true)],
      conflicts: [],
    },
    libraryLocked: null,
    looks,
    ...overrides,
  };
}

test("groups draw in order, each with its own count; a look's library entry is the look, not a library row", () => {
  const groups = checklistGroups(input());
  expect(groups.map((group) => group.id)).toEqual([...CHECKLIST_GROUPS]);
  const by = Object.fromEntries(groups.map((group) => [group.id, group]));
  expect(by.experiments!.items.map((item) => [item.id, item.on, item.help])).toEqual([
    ["experiments.a", true, "A short line"],
  ]);
  expect([by.experiments!.on, by.experiments!.total]).toEqual([1, 1]);
  expect([by.labs!.on, by.labs!.total]).toEqual([0, 1]);
  expect(by.library!.items.map((item) => item.id)).toEqual(["library:night"]);
  expect(by.library!.items[0]!.help).toBe("a darker theme at night");
  expect(by.looks!.items.map((item) => [item.id, item.on, item.installs])).toEqual([
    ["look:manaflow-ai/ember-look", true, false],
    ["look:manaflow-ai/focus", false, true],
  ]);
  expect(by.all!.items[0]!.locked).toBe("Set by your team");
  // A row with no summary shows its help when that fits one line; the whole help is the detail.
  expect(by.labs!.items[0]!.help).toBe("Long help for labs.b.");
  expect(by.labs!.items[0]!.detail).toBe("Long help for labs.b.");
  expect(totals(groups)).toEqual({ on: 3, total: 6 });
});

test("a change on its way locks the library and the installed looks, never a look still to install", () => {
  const groups = checklistGroups(input({ libraryLocked: "Changing…" }));
  const looks = groups.find((group) => group.id === "looks")!.items;
  expect(groups.find((group) => group.id === "library")!.items[0]!.locked).toBe("Changing…");
  expect(looks.map((item) => item.locked)).toEqual(["Changing…", null]);
});

test("one search filters every group by title, line, detail or key; counts stay the group's own", () => {
  const groups = checklistGroups(input());
  expect(filterGroups(groups, "").map((group) => group.id)).toEqual([...CHECKLIST_GROUPS]);
  const byKey = filterGroups(groups, "BROWSER.c");
  expect(byKey.map((group) => [group.id, group.items.length, group.total])).toEqual([["all", 1, 1]]);
  expect(filterGroups(groups, "long help").flatMap((group) => group.items.map((item) => item.id))).toEqual([
    "experiments.a",
    "labs.b",
    "browser.c",
  ]);
  expect(filterGroups(groups, "ember warm").map((group) => group.id)).toEqual(["looks"]);
  expect(filterGroups(groups, "recipes/focus").map((group) => group.id)).toEqual(["looks"]);
  expect(filterGroups(groups, "nothing like this")).toEqual([]);
});

test("each sidebar look but the default is one switch in Looks; only the one picked is on", () => {
  const look = {
    ...row("sidebar.look", "choice"),
    title: { text: "Sidebar Look" },
    help: { text: "Rows, headers and status marks like another app's sidebar. Your own settings still win." },
    default: "cmux",
    keywords: ["minimal"],
    choices: [
      { value: "cmux", title: { text: "cmux" } },
      { value: "claude", title: { text: "Claude" } },
      { value: "rex", title: { text: "Rex" } },
    ],
  } as SchemaRow;
  const picked = (value: unknown) =>
    checklistGroups(input({ sidebarLook: look, value: (key) => (key === "sidebar.look" ? value : false) }))
      .find((group) => group.id === "looks")!
      .items.filter((item) => sidebarLookOf(item) !== null);
  // The default look (today's sidebar) has no switch and leaves every switch off.
  expect(picked("cmux").map((item) => [item.id, item.title, item.on])).toEqual([
    ["sidebar.look=claude", "Sidebar Look: Claude", false],
    ["sidebar.look=rex", "Sidebar Look: Rex", false],
  ]);
  expect(picked(undefined).some((item) => item.on)).toBe(false);
  expect(picked("rex").map((item) => item.on)).toEqual([false, true]);
  expect(picked("rex")[1]!.help).toBe("Rows, headers and status marks like another app's sidebar.");
  expect(sidebarLookOf({ id: "sidebar.look=rex" })).toBe("rex");
  expect(sidebarLookOf({ id: "look:manaflow-ai/ember-look" })).toBeNull();
  // Search finds it by its key, its value or the row's keywords; a managed key locks every one.
  const groups = checklistGroups(
    input({ sidebarLook: look, locked: (key) => (key === "sidebar.look" ? "Managed" : null) }),
  );
  expect(filterGroups(groups, "minimal rex").flatMap((group) => group.items.map((item) => item.id))).toEqual([
    "sidebar.look=rex",
  ]);
  expect(
    groups
      .find((group) => group.id === "looks")!
      .items.filter((item) => sidebarLookOf(item) !== null)
      .map((item) => item.locked),
  ).toEqual(["Managed", "Managed"]);
  // No row (a build whose page hides it) adds nothing.
  expect(checklistGroups(input()).find((group) => group.id === "looks")!.items).toHaveLength(2);
});

test("verified looks are every looks/ and recipes/ setup, sorted, but not one the index holds back", () => {
  const looks = verifiedLooks(
    index,
    new Map([
      ["recipes/zed", setup("a/zed", "Zed")],
      ["looks/waiting", setup("a/waiting", "Waiting")],
      ["looks/new-one", setup("a/new", "New One", "Added with no edit")],
      ["looks/broken", "{ not json"],
      ["looks/no-name", '{"id": "a/x"}'],
      ["gallery/other", setup("a/other", "Other")],
    ]),
  );
  expect(looks.map((look) => look.folder)).toEqual(["looks/new-one", "recipes/zed"]);
  expect(looks[0]).toEqual({
    id: "a/new",
    name: "New One",
    tagline: "Added with no edit",
    reference: "github.com/manaflow-ai/cmux/examples/looks/new-one@feat-cmux-next",
    folder: "looks/new-one",
  });
});

test("stripJsonComments keeps strings whole and drops comments and trailing commas", () => {
  const source = '{"url": "https://x//y", /* c */ "a": "b\\"//", // end\n "list": [1, 2,],}';
  expect(JSON.parse(stripJsonComments(source))).toEqual({ url: "https://x//y", a: 'b"//', list: [1, 2] });
});

test("setupEntryName is the library entry `cmux setup install` makes", () => {
  expect(setupEntryName("manaflow-ai/ember-look")).toBe("setup-manaflow-ai-ember-look");
  expect(setupEntryName("A.B")).toBe("setup-a-b");
  expect(setupEntryName("x".repeat(80)).length).toBe(64);
});

test("a line under a title fits 60 characters: the words, else their first sentence, else nothing", () => {
  expect(shortLine("  Warm.  ")).toBe("Warm.");
  const long = `A first sentence that fits. ${"then much more ".repeat(6)}`;
  expect(shortLine(long)).toBe("A first sentence that fits.");
  expect(shortLine("word ".repeat(20))).toBe("");
  expect(
    shortLine(
      "A quiet, near-black agent-editor look: a cool sidebar of repositories, a bordered prompt, steel-blue Run.",
    ),
  ).toBe("A quiet, near-black agent-editor look");
  expect(shortLine(`Dense and calm — ${"a long list of things ".repeat(5)}`)).toBe("Dense and calm");
  expect(shortLine("é".repeat(60))).toBe("é".repeat(60));
});

test("unmerged code in the build is its own group, one switch each, worded by the standup line", () => {
  const pr: LibraryEntry = {
    ...entry("pr-43496", true),
    code: {
      pr: 43496,
      repo: "manaflow-ai/cmux",
      title: "Cat icon",
      head: "9c1e2f0",
      base: "36316c1",
      note: "in your build",
    },
  };
  const branch: LibraryEntry = {
    ...entry("branch-lane-cat", false),
    code: {
      kind: "branch",
      repo: "manaflow-ai/cmux",
      source: "lane/cat",
      pr: 0,
      title: "",
      head: "4b7d0aa",
      base: "36316c1",
    },
  };
  const groups = checklistGroups(
    input({
      library: { entries: [entry("night", true), pr, branch], conflicts: [] },
      standup: {
        on: 2,
        text: "",
        lines: [
          {
            name: "pr-43496",
            kind: "pr",
            on: true,
            title: "#43496 Cat icon",
            status: "on · in your build",
            link: "https://github.com/manaflow-ai/cmux/pull/43496",
          },
        ],
      },
    }),
  );
  const by = Object.fromEntries(groups.map((group) => [group.id, group]));
  expect(groups[0]!.id).toBe("code");
  expect(by.code!.items.map((item) => [item.id, item.title, item.help, item.on])).toEqual([
    ["library:pr-43496", "#43496 Cat icon", "on · in your build", true],
    // No standup line yet (still loading): the entry's own words.
    ["library:branch-lane-cat", "branch-lane-cat", "", false],
  ]);
  expect(by.code!.items[0]!.detail).toContain("/pull/43496");
  expect(by.library!.items.map((item) => item.id)).toEqual(["library:night"]);
  expect(filterGroups(groups, "43496").map((group) => group.id)).toContain("code");
});
