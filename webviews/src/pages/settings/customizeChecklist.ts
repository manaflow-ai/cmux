// Settings > Customize (Leo, 2026-11-22, ask-931361017e: "it should just be as easy as a click
// toggle"): every customization in one checklist, one click each. This is the pure model the card
// (components/CustomizeChecklist.tsx), the App Store's Customize cmux… card and the gallery draw:
// which rows go in which group, each group's count, and the search over all of them.
//
// Rows come from the schema export the page already loads, never from a list kept here: a new
// `experiments.*` or `labs.*` toggle, and any other toggle the page shows, appears with no edit.
// The Customization Library's entries come from `cmux customize library` (the library card's own
// query), and the verified looks from the examples gallery index (examples/gallery/gallery.json,
// whose looks `cargo test -p cmux-customize --test gallery` installs and removes on every run).
import type { LibraryEntry, LibraryListing } from "./ops";
import type { SchemaRow } from "./schema";
import { text } from "./strings";

/** The checklist's groups, in the order they draw. */
export const CHECKLIST_GROUPS = ["experiments", "labs", "library", "looks", "all"] as const;
export type ChecklistGroupId = (typeof CHECKLIST_GROUPS)[number];

/** The Labs switch that is not under `labs.` (Settings > Experimental > Customize From the Window). */
export const LABS_EXTRA_KEYS: ReadonlySet<string> = new Set(["customize.fromTheApp"]);

/** One switch of the checklist. `id` is unique across groups: a setting key, `library:NAME` or
 * `look:ID`. */
export type ChecklistItem = {
  id: string;
  group: ChecklistGroupId;
  title: string;
  /** One line under the title (the row's summary, else the first sentence of its help). */
  help: string;
  /** Extra words the search matches (the setting key, a look's folder). */
  terms: string;
  on: boolean;
  /** Why the switch cannot change (a managed key, the page not connected yet), else null. */
  locked: string | null;
  /** A look that is not installed: the click asks cmux to install it instead of switching. */
  installs?: boolean;
};

export type ChecklistGroup = {
  id: ChecklistGroupId;
  items: ChecklistItem[];
  /** Switches on, of every switch in the group (before the search filters). */
  on: number;
  total: number;
};

/** Which of the schema's toggle rows each settings group holds. `shown` says whether the page
 * draws a row in this build (its home category; DEV-only categories only in DEV builds). */
export function toggleRowsByGroup(
  rows: readonly SchemaRow[],
  shown: (row: SchemaRow) => boolean,
): Record<"experiments" | "labs" | "all", SchemaRow[]> {
  const out = { experiments: [] as SchemaRow[], labs: [] as SchemaRow[], all: [] as SchemaRow[] };
  for (const row of rows) {
    if (row.kind !== "toggle" || !shown(row)) continue;
    out[settingGroup(row.key)].push(row);
  }
  return out;
}

/** The group a toggle row's key belongs to. */
export function settingGroup(key: string): "experiments" | "labs" | "all" {
  if (key.startsWith("experiments.")) return "experiments";
  if (key.startsWith("labs.") || LABS_EXTRA_KEYS.has(key)) return "labs";
  return "all";
}

/** The one line under a row's title: its summary, else its help's first sentence. */
export function helpLine(row: SchemaRow): string {
  const summary = text(row.summary);
  if (summary) return summary;
  return firstSentence(text(row.help));
}

export function firstSentence(words: string): string {
  const trimmed = words.trim();
  const end = trimmed.search(/[.!?。](\s|$)/);
  return end < 0 ? trimmed : trimmed.slice(0, end + 1);
}

/** A verified look, as the gallery index and its `cmux-setup.json` name it. */
export type VerifiedLook = {
  /** `manaflow-ai/ember-look`: the setup's id, which names its library entry. */
  id: string;
  name: string;
  tagline: string;
  /** What `cmux setup install` takes: `github.com/manaflow-ai/cmux/examples/looks/ember@feat-cmux-next`. */
  reference: string;
  folder: string;
};

/** The library entry `cmux setup install` makes for a setup id (cmux-customize setup.rs
 * `profile_name`): `setup-` and the id, lower case, every other character a dash, at most 64. */
export function setupEntryName(id: string): string {
  const name = `setup-${id}`
    .replace(/[^A-Za-z0-9]/g, "-")
    .toLowerCase()
    .slice(0, 64);
  return name.replace(/-+$/, "");
}

/** The settings, library and look items as the checklist draws them. */
export type ChecklistInput = {
  rows: Record<"experiments" | "labs" | "all", SchemaRow[]>;
  value: (key: string) => unknown;
  /** Why a setting cannot change now (SettingRow's rule: managed, not connected, not readable). */
  locked: (key: string) => string | null;
  library: LibraryListing | null;
  /** Why the library cannot change now (a change on its way), else null. */
  libraryLocked: string | null;
  looks: readonly VerifiedLook[];
};

export function checklistGroups(input: ChecklistInput): ChecklistGroup[] {
  const setting = (group: ChecklistGroupId, row: SchemaRow): ChecklistItem => ({
    id: row.key,
    group,
    title: text(row.title),
    help: helpLine(row),
    terms: row.key,
    on: input.value(row.key) === true,
    locked: input.locked(row.key),
  });
  const entries = input.library?.entries ?? [];
  const byName = new Map(entries.map((entry) => [entry.name, entry] as const));
  const lookEntries = new Set(input.looks.map((look) => setupEntryName(look.id)));
  const library = entries
    .filter((entry) => !lookEntries.has(entry.name))
    .map((entry): ChecklistItem => libraryItem(entry, input.libraryLocked));
  const looks = input.looks.map((look): ChecklistItem => {
    const entry = byName.get(setupEntryName(look.id));
    return {
      id: `look:${look.id}`,
      group: "looks",
      title: look.name,
      help: look.tagline,
      terms: `${look.folder} ${look.id}`,
      on: entry?.on === true,
      locked: entry ? input.libraryLocked : null,
      installs: entry === undefined,
    };
  });
  const items: Record<ChecklistGroupId, ChecklistItem[]> = {
    experiments: input.rows.experiments.map((row) => setting("experiments", row)),
    labs: input.rows.labs.map((row) => setting("labs", row)),
    library,
    looks,
    all: input.rows.all.map((row) => setting("all", row)),
  };
  return CHECKLIST_GROUPS.map((id) => counted(id, items[id]));
}

function libraryItem(entry: LibraryEntry, locked: string | null): ChecklistItem {
  return {
    id: `library:${entry.name}`,
    group: "library",
    title: entry.name,
    help: entry.words[0] || entry.description || "",
    terms: [...entry.settings, ...entry.files].join(" "),
    on: entry.on,
    locked,
  };
}

function counted(id: ChecklistGroupId, items: ChecklistItem[]): ChecklistGroup {
  return { id, items, on: items.filter((item) => item.on).length, total: items.length };
}

/** The search: every word must be in the title, the help line or the terms (any case). */
export function matches(item: ChecklistItem, query: string): boolean {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return true;
  const haystack = `${item.title} ${item.help} ${item.terms}`.toLowerCase();
  return words.every((word) => haystack.includes(word));
}

/** Each group with only the items the search matches; a group left empty by a search is dropped,
 * and with no search an empty group stays (its header says 0 of 0). Counts stay the group's own. */
export function filterGroups(groups: readonly ChecklistGroup[], query: string): ChecklistGroup[] {
  if (!query.trim()) return [...groups];
  return groups.flatMap((group) => {
    const items = group.items.filter((item) => matches(item, query));
    return items.length === 0 ? [] : [{ ...group, items }];
  });
}

/** Every group's switches on and in all, for the App Store card's line ("3 on · 41 available"). */
export function totals(groups: readonly ChecklistGroup[]): { on: number; total: number } {
  return groups.reduce((sum, group) => ({ on: sum.on + group.on, total: sum.total + group.total }), {
    on: 0,
    total: 0,
  });
}

// The verified looks: the gallery index's `look` entries under looks/ that need no unmerged change,
// each named by its own cmux-setup.json (JSONC). Read at build time; no request.
type GalleryIndex = {
  repository: string;
  ref: string;
  root: string;
  entries: Array<{ kind: string; path: string; needs?: string }>;
};

/** Strips line and block comments outside strings, and trailing commas (cmux-setup.json is JSONC). */
export function stripJsonComments(source: string): string {
  let out = "";
  let inString = false;
  for (let index = 0; index < source.length; index++) {
    const char = source[index]!;
    const next = source[index + 1];
    if (inString) {
      out += char;
      if (char === "\\") out += source[++index] ?? "";
      else if (char === '"') inString = false;
    } else if (char === '"') {
      inString = true;
      out += char;
    } else if (char === "/" && next === "/") {
      while (index < source.length && source[index] !== "\n") index++;
      out += "\n";
    } else if (char === "/" && next === "*") {
      index += 2;
      while (index < source.length && !(source[index] === "*" && source[index + 1] === "/")) index++;
      index++;
    } else out += char;
  }
  return out.replace(/,(\s*[}\]])/g, "$1");
}

/** The verified looks from the index and each look folder's cmux-setup.json text (by folder path
 * under the index root, `looks/ember`). A look whose setup does not parse is left out. */
export function verifiedLooks(index: GalleryIndex, setups: ReadonlyMap<string, string>): VerifiedLook[] {
  return index.entries.flatMap((entry) => {
    if (entry.kind !== "look" || entry.needs || !entry.path.startsWith("looks/")) return [];
    const source = setups.get(entry.path);
    if (!source) return [];
    try {
      const setup = JSON.parse(stripJsonComments(source)) as { id?: string; name?: string; tagline?: string };
      if (!setup.id || !setup.name) return [];
      return [
        {
          id: setup.id,
          name: setup.name,
          tagline: setup.tagline ?? "",
          reference: `${index.repository}/${index.root}/${entry.path}@${index.ref}`,
          folder: entry.path,
        },
      ];
    } catch {
      return [];
    }
  });
}
