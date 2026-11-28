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
import type { LibraryEntry, LibraryListing, Standup, StandupLine } from "./ops";
import type { SchemaRow } from "./schema";
import { text } from "./strings";
import { intl } from "../../ui/intl";

/** The checklist's groups, in the order they draw. `code` is the unmerged code in this build (Leo,
 * 2026-11-23: "additional yolo mode "merges""): each PR, branch, commit, folder or fork the library
 * holds, one switch each, worded by `cmux customize library standup`. */
export const CHECKLIST_GROUPS = ["code", "experiments", "labs", "library", "looks", "all"] as const;
export type ChecklistGroupId = (typeof CHECKLIST_GROUPS)[number];

/** The Labs switch that is not under `labs.` (Settings > Experimental > Customize From the Window). */
export const LABS_EXTRA_KEYS: ReadonlySet<string> = new Set(["customize.fromTheApp"]);

/** The choice setting whose non-default choices the Looks group lists as switches: a sidebar look
 * (Leo, ask-b9d8846cc2: "having people be able to easily toggle my customieer or whatever would be
 * god"). Switching one on picks it; switching it off puts the setting back to its default. */
export const SIDEBAR_LOOK_KEY = "sidebar.look";

/** The id of a sidebar look's switch: `sidebar.look=rex`. */
export function sidebarLookItemId(value: string): string {
  return `${SIDEBAR_LOOK_KEY}=${value}`;
}

/** The choice a sidebar look switch picks, or null for any other item. */
export function sidebarLookOf(item: Pick<ChecklistItem, "id">): string | null {
  const prefix = `${SIDEBAR_LOOK_KEY}=`;
  return item.id.startsWith(prefix) ? item.id.slice(prefix.length) : null;
}

/** One switch of the checklist. `id` is unique across groups: a setting key, `library:NAME`,
 * `look:ID` or a sidebar look (`sidebar.look=rex`). */
export type ChecklistItem = {
  id: string;
  group: ChecklistGroupId;
  title: string;
  /** The one short line under the title (a row's summary; a look's or entry's words when they fit
   * SHORT_LINE), else empty: a setting row says what it is in one short line, or nothing (Leo,
   * 2026-10-11, rowSummary.test.tsx). */
  help: string;
  /** The longer words (a row's help, a look's tagline), shown on hover and matched by the search. */
  detail: string;
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

/** The longest line drawn under a title, in characters as a reader counts them (rowSummary.test.tsx). */
export const SHORT_LINE = 60;

const graphemes = intl.Segmenter(undefined, { granularity: "grapheme" });

/** `words` when they fit one short line, else their first sentence when that fits, else the part
 * before its first colon, semicolon or dash when that fits ("A quiet, near-black agent-editor look"
 * of a look's tagline), else empty. The whole words show on hover. */
export function shortLine(words: string): string {
  const trimmed = words.trim();
  if (fits(trimmed)) return trimmed;
  const sentence = firstSentence(trimmed);
  if (fits(sentence)) return sentence;
  const clause = /^(.+?)\s*(?:[:;]|\s[—–-]\s)/u.exec(sentence)?.[1]?.trim() ?? "";
  return clause && fits(clause) ? clause : "";
}

function fits(words: string): boolean {
  return [...graphemes.segment(words)].length <= SHORT_LINE;
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
  /** The `sidebar.look` row when the page shows it: each choice but its default is one switch. */
  sidebarLook?: SchemaRow | null;
  /** The CLI's standup lines, which word the code group's rows; null draws them from the entry. */
  standup?: Standup | null;
};

export function checklistGroups(input: ChecklistInput): ChecklistGroup[] {
  const setting = (group: ChecklistGroupId, row: SchemaRow): ChecklistItem => ({
    id: row.key,
    group,
    title: text(row.title),
    // The row's summary, else its help's first sentence (one line, cut with an ellipsis; all of it on hover).
    help: shortLine(text(row.summary) || text(row.help)),
    detail: text(row.help),
    terms: row.key,
    on: input.value(row.key) === true,
    locked: input.locked(row.key),
  });
  const entries = input.library?.entries ?? [];
  const byName = new Map(entries.map((entry) => [entry.name, entry] as const));
  const lookEntries = new Set(input.looks.map((look) => setupEntryName(look.id)));
  const said = new Map((input.standup?.lines ?? []).map((line) => [line.name, line] as const));
  const kept = entries.filter((entry) => !lookEntries.has(entry.name));
  const code = kept
    .filter((entry) => entry.code)
    .map((entry): ChecklistItem => codeItem(entry, said.get(entry.name), input.libraryLocked));
  const library = kept
    .filter((entry) => !entry.code)
    .map((entry): ChecklistItem => libraryItem(entry, input.libraryLocked));
  const looks = input.looks.map((look): ChecklistItem => {
    const entry = byName.get(setupEntryName(look.id));
    return {
      id: `look:${look.id}`,
      group: "looks",
      title: look.name,
      help: shortLine(look.tagline),
      detail: look.tagline,
      terms: `${look.folder} ${look.id}`,
      on: entry?.on === true,
      locked: entry ? input.libraryLocked : null,
      installs: entry === undefined,
    };
  });
  const items: Record<ChecklistGroupId, ChecklistItem[]> = {
    code,
    experiments: input.rows.experiments.map((row) => setting("experiments", row)),
    labs: input.rows.labs.map((row) => setting("labs", row)),
    library,
    looks: [...sidebarLookItems(input), ...looks],
    all: input.rows.all.map((row) => setting("all", row)),
  };
  return CHECKLIST_GROUPS.map((id) => counted(id, items[id]));
}

/** The sidebar looks as switches ("Sidebar Look: Rex"), in the schema's choice order. The default
 * (`cmux`) has none: it is what every switch off goes back to. */
function sidebarLookItems(input: ChecklistInput): ChecklistItem[] {
  const row = input.sidebarLook;
  if (!row?.choices) return [];
  const current = input.value(row.key) ?? row.default;
  const locked = input.locked(row.key);
  return row.choices
    .filter((choice) => choice.value !== row.default)
    .map((choice) => ({
      id: sidebarLookItemId(choice.value),
      group: "looks",
      title: `${text(row.title)}: ${text(choice.title)}`,
      help: shortLine(text(row.summary) || text(row.help)),
      detail: text(row.help),
      terms: `${row.key} ${choice.value} ${row.keywords.join(" ")}`,
      on: current === choice.value,
      locked,
    }));
}

function libraryItem(entry: LibraryEntry, locked: string | null): ChecklistItem {
  const words = entry.words[0] || entry.description || "";
  return {
    id: `library:${entry.name}`,
    group: "library",
    title: entry.name,
    help: shortLine(words),
    detail: words,
    terms: [...entry.settings, ...entry.files].join(" "),
    on: entry.on,
    locked,
  };
}

/** A code entry: the standup line's title and state (`#43496 Cat icon`, `on · in your build`),
 * else the entry's own name and note; the link is the detail, so hover and search show it. */
function codeItem(entry: LibraryEntry, line: StandupLine | undefined, locked: string | null): ChecklistItem {
  const code = entry.code!;
  const title = line?.title ?? (code.pr ? `#${code.pr} ${code.title ?? ""}`.trim() : entry.name);
  const status = line?.status ?? code.note ?? "";
  return {
    id: `library:${entry.name}`,
    group: "code",
    title,
    help: shortLine(status),
    detail: [status, line?.link].filter(Boolean).join(" "),
    terms: [entry.name, line?.link ?? "", code.repo].join(" "),
    on: entry.on,
    locked,
  };
}

function counted(id: ChecklistGroupId, items: ChecklistItem[]): ChecklistGroup {
  return { id, items, on: items.filter((item) => item.on).length, total: items.length };
}

/** The search: every word must be in the title, the line, the detail or the terms (any case). */
export function matches(item: ChecklistItem, query: string): boolean {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return true;
  const haystack = `${item.title} ${item.help} ${item.detail} ${item.terms}`.toLowerCase();
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

// The verified looks: every examples/looks/NAME and examples/recipes/NAME folder that has a
// cmux-setup.json, each named by that file (JSONC), so a look or recipe added there shows with no
// edit. The gallery index gives the repository and ref `cmux setup install` takes, and a look it
// marks `needs` (an unmerged change) is left out. Read at build time; no request.
type GalleryIndex = {
  repository: string;
  ref: string;
  root: string;
  entries: Array<{ kind: string; path: string; needs?: string }>;
};

/** The folders the looks group reads, under the examples root. */
export const LOOK_FOLDERS = ["looks/", "recipes/"] as const;

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

/** The verified looks from each setup's text (by folder under the examples root, `looks/ember`),
 * in folder order. A setup that does not parse, or that the index marks `needs`, is left out. */
export function verifiedLooks(index: GalleryIndex, setups: ReadonlyMap<string, string>): VerifiedLook[] {
  const waiting = new Set(index.entries.filter((entry) => entry.needs).map((entry) => entry.path));
  const folders = [...setups.keys()]
    .filter((folder) => LOOK_FOLDERS.some((root) => folder.startsWith(root)) && !waiting.has(folder))
    .sort();
  return folders.flatMap((folder) => {
    try {
      const setup = JSON.parse(stripJsonComments(setups.get(folder)!)) as {
        id?: string;
        name?: string;
        tagline?: string;
      };
      if (!setup.id || !setup.name) return [];
      return [
        {
          id: setup.id,
          name: setup.name,
          tagline: setup.tagline ?? "",
          reference: `${index.repository}/${index.root}/${folder}@${index.ref}`,
          folder,
        },
      ];
    } catch {
      return [];
    }
  });
}
