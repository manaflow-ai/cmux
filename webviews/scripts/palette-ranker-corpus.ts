/**
 * Writes the palette ranker equality corpus: real palette requests (the eval fixture's root
 * entries and cases, keystroke prefixes, typos, ids, accents, CJK, gated pages, aliases, pins,
 * learned picks, hidden rows) with the TypeScript ranker's answers, exactly as the native
 * JavaScriptCore bridge returns them (`__cmuxPaletteInstall` + `__cmuxPaletteRank`).
 * cmux-tui/crates/cmux-palette-ranker/tests/corpus.rs replays it through the Rust C ABI.
 *
 *   bun scripts/palette-ranker-corpus.ts          # rewrite the corpus
 *   bun scripts/palette-ranker-corpus.ts --check  # exit 1 when the corpus is stale
 *   bun scripts/palette-ranker-corpus.ts --out F  # write (or check) F instead
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { evalNow, replayHistory, type EvalCase } from "../src/palette/eval";
import type { PaletteFrecency, PaletteRankEntry, PaletteRankRequest } from "../src/palette/ranker";
import "../src/palette/ranker-bridge";
import { loadEval } from "./palette-eval";

const here = dirname(fileURLToPath(import.meta.url));
const outIndex = process.argv.indexOf("--out");
const out =
  outIndex >= 0
    ? process.argv[outIndex + 1]
    : join(here, "..", "..", "cmux-tui", "crates", "cmux-palette-ranker", "tests", "corpus", "palette-corpus.json");
const bridge = globalThis as unknown as {
  __cmuxPaletteInstall(version: number, entriesJSON: string): void;
  __cmuxPaletteRank(requestJSON: string): string;
};

type Request = Omit<PaletteRankRequest, "entries" | "operation"> & { operation?: PaletteRankRequest["operation"] };
interface CorpusCase {
  name: string;
  set: string;
  request: Request;
  /** The request carries its entries (no version), the path a native caller takes without a snapshot version. */
  inline?: boolean;
}

const { fixture, cases } = loadEval();
const day = 24 * 60 * 60;
const base = { sectionOrders: fixture.sectionOrders, now: evalNow, showsRecent: fixture.showsRecent };

const e = (title: string, extra: Partial<PaletteRankEntry> = {}): PaletteRankEntry => ({
  title,
  keywords: [],
  rankBias: 0,
  isEnabled: true,
  isVisibleWhenQueryEmpty: true,
  hidesWhenTyping: false,
  sectionIndex: 0,
  entersScope: false,
  demoted: false,
  hasShortcut: false,
  ...extra,
});

const sets: Record<string, { version: number; entries: PaletteRankEntry[] }> = {
  root: { version: 1, entries: fixture.entries.map((row) => row.entry) },
  cjk: {
    version: 2,
    entries: [
      e("新しいタブ", {
        keywords: ["tab", "new"],
        actionID: "newTab",
        frecencyKey: "action:newTab",
        hasShortcut: true,
      }),
      e("新しいウィンドウ", { actionID: "newWindow", frecencyKey: "action:newWindow" }),
      e("設定…", { keywords: ["preferences", "設定"], actionID: "openSettings", frecencyKey: "action:openSettings" }),
      e("ワークスペースを閉じる", { actionID: "closeWorkspace", frecencyKey: "action:closeWorkspace" }),
      e("ブラウザで開く", { subtitle: "Chromium", actionID: "openBrowser" }),
      e("分割（右）", { keywords: ["split", "right"], actionID: "splitRight", hasShortcut: true }),
      e("检查更新", { keywords: ["update"], actionID: "checkUpdates", sectionIndex: 1 }),
      e("새 탭", { keywords: ["tab"], actionID: "newTabKo", sectionIndex: 1 }),
      e("설정", { actionID: "settingsKo", sectionIndex: 1, demoted: true }),
      e("Café Browser", { accessory: "⌘B", actionID: "cafeBrowser" }),
      e("Ｆｕｌｌｗｉｄｔｈ Ｔａｂ", { actionID: "fullwidthTab" }),
      e("naïve résumé", { subtitle: "Ångström", actionID: "naive" }),
      e("Straße öffnen", { actionID: "strasse" }),
      e("İstanbul Mode", { actionID: "istanbul" }),
      e("ΣΟΦΙΑ Panel", { actionID: "sofia" }),
      e("ﬁnd in ﬁle", { actionID: "findInFile" }),
      e("ﾀﾌﾞを閉じる", { actionID: "closeTabHalfwidth" }),
      e("Ünïcödé Toolbar", { keywords: ["ツールバー"], actionID: "unicodeToolbar" }),
    ],
  },
  gated: {
    version: 3,
    entries: [
      e("Run Command", { queryPrefix: ">", actionID: "runCommand", frecencyKey: "action:runCommand" }),
      e("Run Last Command", { queryPrefix: ">", actionID: "runLast" }),
      e("Go to Line", { queryPrefix: ":", actionID: "goToLine" }),
      e("Mention Agent", { queryPrefix: "@", actionID: "mention" }),
      e("Recent Files", { hidesWhenTyping: true, actionID: "recentFiles", frecencyKey: "action:recentFiles" }),
      e("New Tab", {
        actionID: "newTab",
        frecencyKey: "action:newTab",
        hasShortcut: true,
        suggestedRank: 1,
        suggestedSectionIndex: 2,
      }),
      e("New Tab…", {
        actionID: "newTabMenu",
        frecencyKey: "action:newTabMenu",
        suggestedRank: 2,
        suggestedSectionIndex: 2,
      }),
      e("Settings", {
        keywords: ["settings", "preferences"],
        entersScope: true,
        actionID: "settingsScope",
        sectionIndex: 1,
      }),
      e("Settings", { demoted: true, actionID: "settingsRow", frecencyKey: "setting:settings", sectionIndex: 1 }),
      e("Color", { demoted: true, actionID: "colorA", sectionIndex: 1 }),
      e("Color", { demoted: true, actionID: "colorB", sectionIndex: 1 }),
      e("Set Workspace Color…", { actionID: "workspaceColor", frecencyKey: "action:workspaceColor" }),
      e("Close Tab", { actionID: "closeTab", isEnabled: false, frecencyKey: "action:closeTab" }),
      e("Close Window", { actionID: "closeWindow", rankBias: 40, frecencyKey: "action:closeWindow" }),
      e("Hidden Row", { actionID: "hiddenRow", frecencyKey: "action:hiddenRow", isVisibleWhenQueryEmpty: false }),
      e("Toggle Split Zoom", {
        actionID: "toggleSplitZoom",
        accessory: "⇧⌘↩",
        subtitle: "Pane",
        typingSectionIndex: 3,
      }),
      e("Split Right", { actionID: "splitRight", hasShortcut: true, typingSectionIndex: 3 }),
      e("Split Up", { actionID: "splitUp", typingSectionIndex: 3 }),
    ],
  },
  astral: {
    version: 4,
    entries: [
      e("😀 Smile Mode", { actionID: "smile", frecencyKey: "action:😀", hasShortcut: true }),
      e("～ Wave Mode", { actionID: "wave", frecencyKey: "action:～" }),
      e("𝐁old Text", { actionID: "bold", frecencyKey: "action:𝐁" }),
      e("Rocket 🚀 Launch", { keywords: ["ship"], actionID: "rocket", frecencyKey: "action:🚀" }),
      e("Family 👨‍👩‍👧 Share", { actionID: "family", frecencyKey: "action:family" }),
      e("Plain Mode", { actionID: "plain", frecencyKey: "action:plain", sectionIndex: 7 }),
    ],
  },
};

const corpus: CorpusCase[] = [];
const add = (name: string, set: string, request: Request, inline = false) =>
  corpus.push({ name, set, request, ...(inline ? { inline } : {}) });

function frecencyFor(evalCase: EvalCase): PaletteFrecency {
  const profile = evalCase.profile ? cases.profiles?.[evalCase.profile] : undefined;
  const start: PaletteFrecency = {
    entries: Object.fromEntries(
      Object.entries(profile ?? {}).map(([key, score]) => [key, { score, lastUsed: evalNow }]),
    ),
  };
  return evalCase.replay ? replayHistory(evalCase.replay, start) : start;
}

// 1. Every eval case, as the native searcher sends it (rankEmpty for an empty query).
cases.cases.forEach((evalCase, index) => {
  add(`eval ${index} ${evalCase.group} ${JSON.stringify(evalCase.query)}`, "root", {
    ...base,
    operation: evalCase.query.trim() === "" ? "rankEmpty" : "rank",
    query: evalCase.query,
    frecency: frecencyFor(evalCase),
    aliases: evalCase.aliases,
    pins: evalCase.pins,
    pinnedSectionIndex: evalCase.pins ? 0 : null,
  });
});

const lawrence: PaletteFrecency = {
  entries: Object.fromEntries(
    Object.entries(cases.profiles?.lawrence ?? {}).map(([key, score], i) => [
      key,
      { score, lastUsed: evalNow - (i % 5) * day },
    ]),
  ),
  halfLife: 3 * day,
};

// 2. Every keystroke of common commands, with and without usage.
for (const phrase of [
  "split right",
  "new workspace",
  "toggle sidebar",
  "settings",
  "close tab",
  "rename tab",
  "new agent chat",
]) {
  for (let length = 1; length <= phrase.length; length++) {
    const query = phrase.slice(0, length);
    add(`keystroke ${JSON.stringify(query)}`, "root", { ...base, operation: "rank", query, frecency: { entries: {} } });
  }
  add(`keystroke usage ${JSON.stringify(phrase)}`, "root", {
    ...base,
    operation: "rank",
    query: phrase,
    frecency: lawrence,
  });
}

// 3. Typos, ids, accents and width, odd input.
const queries = [
  "nwe tab",
  "sttings",
  "settigns",
  "toggel sidebar",
  "clsoe tab",
  "rnamee tab",
  "workspcae",
  "brwoser",
  "reloda",
  "sidbar",
  "termnial",
  "colmun",
  "zom",
  "fnd",
  "qiut",
  "spilt rihgt",
  "nwe wrokspace",
  "bookmakr",
  "histroy",
  "openSettings",
  "palette.new",
  "newSur",
  "splitRight",
  "closeTab",
  "palette.workspaceColor",
  "newsurface",
  "open",
  "SETTINGS",
  "Séttings",
  "ＳＥＴＴＩＮＧＳ",
  "ﬁnd",
  "  split   right  ",
  "split…",
  "settings...",
  "Split-Right",
  "zzz",
  "qx",
  "1",
  "2",
  "3d",
  "@",
  "#",
  ">",
  "…",
  "-",
  "设置",
  "設定",
  "タブ",
  "tab tab tab",
  "a b c d e",
  "new tab new window",
  "x".repeat(40),
  "srt",
  "nbt",
  "tsb",
  "ws",
  "nw",
  "sr",
  "cmd",
  "dark",
  "light",
  "font size",
];
for (const query of queries)
  add(`query ${JSON.stringify(query)}`, "root", { ...base, operation: "rank", query, frecency: lawrence });

// 4. Request options: prefix-first (tab search), kept section order, row and highlight limits.
for (const query of ["new", "split", "set", "tab", "close"]) {
  add(`prefixFirst ${query}`, "root", {
    ...base,
    operation: "rank",
    query,
    ranksPrefixFirst: true,
    frecency: lawrence,
  });
  add(`keepsSectionOrder ${query}`, "root", {
    ...base,
    operation: "rank",
    query,
    keepsSectionOrder: true,
    frecency: { entries: {} },
  });
  add(`limits ${query}`, "root", {
    ...base,
    operation: "rank",
    query,
    rowLimit: 7,
    highlightLimit: 3,
    frecency: lawrence,
  });
}

// 5. Empty queries: usage, hidden rows, pins, no Recent, a rank op with only white space.
const hidden: PaletteFrecency = {
  ...lawrence,
  hidden: ["action:newColumn", "action:splitRight", "action:newTab.default"],
};
add("empty usage", "root", { ...base, operation: "rankEmpty", frecency: lawrence });
add("empty hidden", "root", { ...base, operation: "rankEmpty", frecency: hidden });
add("empty pins", "root", {
  ...base,
  operation: "rankEmpty",
  frecency: lawrence,
  pins: ["splitDown", "missing", "splitDown", "newColumn"],
  pinnedSectionIndex: 3,
});
add("empty no recent", "root", {
  ...base,
  operation: "rankEmpty",
  showsRecent: false,
  frecency: lawrence,
  pins: ["splitDown"],
});
add("empty recentLimit 0", "root", { ...base, operation: "rankEmpty", recentLimit: 0, frecency: lawrence });
add("empty recentLimit 2", "root", { ...base, operation: "rankEmpty", recentLimit: 2, frecency: lawrence });
add("rank white space", "root", { ...base, operation: "rank", query: "   ", frecency: lawrence });
add("rank empty string", "root", { ...base, operation: "rank", query: "", frecency: lawrence, pins: ["closeTab"] });
add("hidden typed", "root", { ...base, operation: "rank", query: "split", frecency: hidden });
add("hidden whole title", "root", { ...base, operation: "rank", query: "new column", frecency: hidden });

// 6. Aliases.
const aliases = { splitRight: ["vs", "Right Split"], closeWindow: ["close", "cw"], newColumn: ["nc"], missing: ["zz"] };
for (const query of ["vs", "VS", " right   split ", "close", "clo", "cw", "nc", "zz", "split"]) {
  add(`alias ${JSON.stringify(query)}`, "root", { ...base, operation: "rank", query, frecency: lawrence, aliases });
}

// 7. CJK, accents, compatibility forms.
for (const query of [
  "新しい",
  "タブ",
  "新",
  "設定",
  "閉じる",
  "ﾀﾌﾞ",
  "タフ",
  "새",
  "설정",
  "检查",
  "更新",
  "cafe",
  "café",
  "naive",
  "resume",
  "angstrom",
  "strasse",
  "straße",
  "istanbul",
  "i̇stanbul",
  "σοφια",
  "ΣΟΦΙΑ",
  "sofia",
  "fullwidth",
  "ｆｕｌｌ",
  "find",
  "fin fi",
  "unicode",
  "ツール",
  "右",
  "split",
  "tab",
  "update",
  "",
]) {
  add(`cjk ${JSON.stringify(query)}`, "cjk", {
    sectionOrders: [1, 0],
    now: evalNow,
    showsRecent: true,
    operation: query === "" ? "rankEmpty" : "rank",
    query,
    frecency: { entries: { "action:newTab": { score: 3, lastUsed: evalNow - day } } },
  });
}

// 8. Gated pages: query prefixes, rows hidden while typing, scopes, demoted settings, disabled rows, picks.
const gatedUsage: PaletteFrecency = {
  entries: {
    "action:closeWindow": { score: 9, lastUsed: evalNow },
    "action:recentFiles": { score: 4, lastUsed: evalNow },
  },
  picks: [
    { prefix: "c", key: "action:closeTab", score: 5, lastUsed: evalNow, last: true },
    { prefix: "c", key: "action:workspaceColor", score: 3, lastUsed: evalNow - day, last: false },
    { prefix: "co", key: "action:workspaceColor", score: 1, lastUsed: evalNow, last: true },
    { prefix: "new", key: "action:newTabMenu", score: 2.5, lastUsed: evalNow, last: false },
    { prefix: "new", key: "action:newTab", score: 2.5, lastUsed: evalNow, last: true },
  ],
  pickHalfLife: 7 * day,
  hidden: ["setting:settings"],
};
for (const query of [
  ">",
  ">run",
  "> last",
  ":",
  ":12",
  "@",
  "@ag",
  "run",
  "recent",
  "new",
  "new tab",
  "settings",
  "Settings",
  "color",
  "colour",
  "co",
  "c",
  "close",
  "split",
  "zoom",
  "pane",
  "⌘",
  "",
]) {
  add(`gated ${JSON.stringify(query)}`, "gated", {
    sectionOrders: [0, 1, 2, 3],
    now: evalNow,
    showsRecent: true,
    operation: query === "" ? "rankEmpty" : "rank",
    query,
    frecency: gatedUsage,
    aliases: { runCommand: ["rc"], closeTab: ["close"] },
    pins: query === "" ? ["closeTab", "runCommand"] : undefined,
    pinnedSectionIndex: query === "" ? 0 : undefined,
  });
}

// 9. Astral-plane titles and keys: equal usage and equal picks tie-break in UTF-16 order.
const tied: PaletteFrecency = {
  entries: Object.fromEntries(
    ["action:😀", "action:～", "action:𝐁", "action:🚀", "action:plain"].map((key) => [
      key,
      { score: 2, lastUsed: evalNow },
    ]),
  ),
  picks: ["action:😀", "action:～", "action:𝐁"].map((key) => ({
    prefix: "mo",
    key,
    score: 3,
    lastUsed: evalNow,
    last: false,
  })),
};
for (const query of ["", "mo", "mode", "😀", "🚀", "smile", "bold", "𝐁", "family", "👨‍👩‍👧", "ship", "～"]) {
  add(`astral ${JSON.stringify(query)}`, "astral", {
    sectionOrders: [0],
    now: evalNow,
    showsRecent: true,
    operation: query === "" ? "rankEmpty" : "rank",
    query,
    frecency: tied,
    keepsSectionOrder: query === "mode",
  });
}

// 10. Edges: prefix-first with aliases, rowLimit 0, a section outside sectionOrders, inline entries.
add("prefixFirst alias", "gated", {
  sectionOrders: [0, 1],
  now: evalNow,
  showsRecent: true,
  operation: "rank",
  query: "close",
  ranksPrefixFirst: true,
  aliases: { splitUp: ["close"] },
  frecency: gatedUsage,
});
add("rowLimit 0", "root", { ...base, operation: "rank", query: "new", rowLimit: 0, frecency: lawrence });
add("section outside orders", "astral", {
  sectionOrders: [0],
  now: evalNow,
  showsRecent: true,
  operation: "rank",
  query: "mode",
  keepsSectionOrder: true,
  frecency: { entries: {} },
});
for (const query of ["", "split", "set", "nwe tab", "close"]) {
  add(
    `inline ${JSON.stringify(query)}`,
    "gated",
    {
      sectionOrders: [0, 1, 2, 3],
      now: evalNow,
      showsRecent: true,
      operation: query === "" ? "rankEmpty" : "rank",
      query,
      frecency: gatedUsage,
    },
    true,
  );
}

// The native bridge path: install a set's entries once per version, then rank requests without entries.
let installed: number | undefined;
const results = corpus.map((item) => {
  const set = sets[item.set];
  if (item.inline) {
    const request = { ...item.request, entries: set.entries };
    return { ...item, request, expected: JSON.parse(bridge.__cmuxPaletteRank(JSON.stringify(request))) };
  }
  if (installed !== set.version) {
    bridge.__cmuxPaletteInstall(set.version, JSON.stringify(set.entries));
    installed = set.version;
  }
  const request = { ...item.request, version: set.version, entries: null };
  return { ...item, request, expected: JSON.parse(bridge.__cmuxPaletteRank(JSON.stringify(request))) };
});

const text = `${JSON.stringify({ generator: "webviews/scripts/palette-ranker-corpus.ts", sets, cases: results })}\n`;
if (process.argv.includes("--check")) {
  if (readFileSync(out, "utf8") !== text) {
    console.error(`palette ranker corpus is stale: run bun scripts/palette-ranker-corpus.ts (${out})`);
    process.exit(1);
  }
  console.log(`palette ranker corpus is current (${results.length} cases)`);
} else {
  writeFileSync(out, text);
  console.log(`wrote ${results.length} cases to ${out}`);
}
