// l10n-allow-file: sample library entries (names, asks, keys), not shipped UI.
// The customize library as `cmux --json customize library` answers it (cmux-customize library.rs),
// for the mock host, the gallery and tests. `relist` computes positions, conflicts and overridden
// keys the way the engine does: top first, an entry that is on wins over every entry below it.
import type { LibraryCode, LibraryConflict, LibraryEntry, LibraryListing, LibraryRun } from "./ops";

type Seed = {
  name: string;
  on: boolean;
  source: string;
  words?: string[];
  swatches?: string[];
  settings?: string[];
  files?: string[];
  code?: LibraryCode;
};

const entry = (seed: Seed, index: number): LibraryEntry => ({
  position: index + 1,
  name: seed.name,
  on: seed.on,
  source: seed.source,
  words: seed.words ?? [],
  description: "",
  thumbnail: {
    swatches: seed.swatches ?? [],
    keys: [...(seed.settings ?? []), ...(seed.files ?? [])],
  },
  settings: seed.settings ?? [],
  files: seed.files ?? [],
  added_ms: null,
  overridden: [],
  ...(seed.code ? { code: seed.code } : {}),
});

/** Positions, conflicts and each entry's overridden keys, from the entries' order and on/off. */
export function relist(entries: readonly LibraryEntry[]): LibraryListing {
  const setBy = new Map<string, { kind: string; names: string[] }>();
  for (const item of entries) {
    if (!item.on) continue;
    for (const key of item.settings) {
      const at = setBy.get(key) ?? { kind: "setting", names: [] };
      at.names.push(item.name);
      setBy.set(key, at);
    }
    for (const key of item.files) {
      const at = setBy.get(key) ?? { kind: key.startsWith("code:") ? "code" : "file", names: [] };
      at.names.push(item.name);
      setBy.set(key, at);
    }
  }
  const conflicts: LibraryConflict[] = [];
  for (const [key, { kind, names }] of setBy) {
    if (names.length > 1) conflicts.push({ kind, key, winner: names[0]!, losers: names.slice(1) });
  }
  return {
    entries: entries.map((item, index) => ({
      ...item,
      position: index + 1,
      overridden: item.on ? conflicts.filter((c) => c.losers.includes(item.name)).map((c) => c.key) : [],
    })),
    conflicts,
  };
}

const NIGHT: Seed = {
  name: "night",
  on: true,
  source: "ask",
  words: ["a darker theme at night, with a violet accent"],
  swatches: ["#1e1b2e", "#8b5cf6", "#e4e0f5"],
  settings: ["appearance.theme", "appearance.accent", "appearance.metrics.sidebarWidth"],
};
const ROOMY: Seed = {
  name: "roomy",
  on: true,
  source: "profile",
  words: ["profile roomy"],
  settings: ["appearance.density", "appearance.metrics.sidebarWidth"],
};
const PR_WIDGET: Seed = {
  name: "pr-widget",
  on: true,
  source: "ask",
  words: ["add a PR widget under History"],
  files: ["views/pr-widget.json"],
};
const PAPER: Seed = {
  name: "paper",
  on: false,
  source: "import",
  swatches: ["#f7f3ea", "#3b3a36", "#c2410c"],
  settings: ["appearance.theme", "appearance.accent"],
};
const KEYS: Seed = {
  name: "vim-keys",
  on: true,
  source: "try-on",
  words: ["vim keys for moving between panes"],
  settings: ["keybindings"],
};

/** A few entries: one that is off, and two that are on and set the same key (night wins over roomy). */
export function mockLibrary(): LibraryListing {
  return relist([NIGHT, ROOMY, PR_WIDGET, KEYS, PAPER].map(entry));
}

/** Nothing applied yet. */
export function mockEmptyLibrary(): LibraryListing {
  return { entries: [], conflicts: [] };
}

/** `count` entries, every third one off, with the mock's own colors and keys. */
export function mockLongLibrary(count: number): LibraryListing {
  const palette = ["#0f766e", "#b45309", "#1d4ed8", "#be123c", "#4d7c0f", "#6d28d9"];
  const seeds: Seed[] = Array.from({ length: count }, (_, index) => ({
    name: `look-${String(index + 1).padStart(2, "0")}`,
    on: index % 3 !== 2,
    source: ["ask", "profile", "try-on", "import"][index % 4]!,
    words: index % 4 === 0 ? [`make it feel like look ${index + 1}`] : [],
    swatches: index % 2 === 0 ? [palette[index % palette.length]!, palette[(index + 2) % palette.length]!] : [],
    settings: [`appearance.surfaces.s${index}.color`],
  }));
  return relist(seeds.map(entry));
}

const HEAD = "716063c1d2b4e8f09a3c5d7e6f1a2b3c4d5e6f70";
const BASE = "9c1e2f3a4b5c6d7e8f9012a3b4c5d6e7f8091a2b";

/** `cmux customize use pr:43543`: a PR's web layer, on, with one part a running app cannot take. */
export const PR_ON: LibraryCode = {
  repo: "manaflow-ai/cmux",
  pr: 43543,
  title: "Customize: try an unmerged PR's web layer on your app",
  head: HEAD,
  base: BASE,
  web: "4f1c".padEnd(64, "a"),
  abi: 7,
  needs_build: ["Swift in CmuxNextSidebar (the sidebar footer)"],
};

/** A PR that merged and is in this build: the refresh turned it off and says so. */
export const PR_MERGED: LibraryCode = {
  repo: "manaflow-ai/cmux",
  pr: 43496,
  title: "Settings: Personalization opens at the theme you picked",
  head: "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5",
  base: BASE,
  web: "8e2d".padEnd(64, "b"),
  note: "merged: in your build",
};

/** A PR with no web part: nothing applies to a running app, so it stays off. */
export const PR_NATIVE: LibraryCode = {
  repo: "manaflow-ai/cmux",
  pr: 43410,
  title: "App icon: the NEXT mark at every size",
  head: "c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6",
  base: BASE,
  needs_build: ["the app icon"],
};

const pr = (code: LibraryCode, on: boolean): Seed => ({
  name: `pr-${code.pr}`,
  on,
  source: "pr",
  words: [`use pr:${code.pr}`],
  files: ["code:web"],
  code,
});

/** The few entries with PR entries on top: one on, one a refresh turned off, one with no web part. */
export function mockLibraryWithExperiments(on: LibraryCode[] = [PR_ON]): LibraryListing {
  const prs = [PR_ON, PR_MERGED, PR_NATIVE].map((code) => pr(code, on.includes(code)));
  return relist([...prs, NIGHT, ROOMY, PR_WIDGET, KEYS, PAPER].map(entry));
}

/** Runs one library verb on `listing` the way the engine does; null for a name it does not have. */
export function runLibrary(listing: LibraryListing, run: LibraryRun): LibraryListing | null {
  if (run.verb === "list") return listing;
  if (!("name" in run)) return null;
  const at = listing.entries.findIndex((item) => item.name === run.name);
  if (at === -1) return null;
  const entries = [...listing.entries];
  // The engine refuses to turn on a PR with no web part (the mock host answers that refusal).
  if (run.verb === "on" && entries[at]!.code && !entries[at]!.code!.web) return null;
  if (run.verb === "on" || run.verb === "off") entries[at] = { ...entries[at]!, on: run.verb === "on" };
  if (run.verb === "remove") entries.splice(at, 1);
  if (run.verb === "order") {
    const [moved] = entries.splice(at, 1);
    const to =
      run.position === "top" ? 0 : run.position === "bottom" ? entries.length : Math.max(0, Number(run.position) - 1);
    entries.splice(Math.min(to, entries.length), 0, moved!);
  }
  return relist(entries);
}
