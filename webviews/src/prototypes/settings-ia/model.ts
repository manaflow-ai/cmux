// l10n-allow-file: gallery prototype (page names under test), not shipped UI.
// The data of the settings navigation prototype (Beyer 2026-11-20: Settings felt "overwhelming";
// Leo 2026-11-22: "push harder"). Everything here is read from the real settings registry
// (pages/settings/categories.ts, which renders the Swift `SettingsPageLayout` export): the
// categories, their groups, rows and order, and the real search. The only new data is the
// six-page grouping below, which names category ids and nothing else.
import { categoryById, shownCategories, shownSidebarSections, type Category } from "../../pages/settings/categories";
import { rowsByKey, type SchemaRow } from "../../pages/settings/schema";
import { filterRows, type SearchGroup } from "../../pages/settings/search";
import { text } from "../../pages/settings/strings";

/** One page of the six-page navigation: the categories it shows open (`essentials`) and the ones
 * it folds behind a disclosure row (`folded`). */
export type SixPage = { id: string; title: string; symbol: string; essentials: string[]; folded: string[] };

/** The six pages (findings G6, 2026-11-22). Terminal, Code Editor, Browser and Models are not
 * top-level: the first three live under Advanced, Models under Chat and Agents (it is an agent
 * setting a person changes from the composer's model menu anyway). */
export const SIX_PAGES: readonly SixPage[] = [
  {
    id: "general",
    title: "General",
    symbol: "gearshape",
    essentials: ["general", "notifications"],
    folded: ["updates", "newTab", "menus"],
  },
  {
    id: "appearance",
    title: "Appearance",
    symbol: "paintbrush",
    essentials: ["appearance"],
    folded: ["sidebar", "tabs"],
  },
  {
    id: "agents",
    title: "Chat and Agents",
    symbol: "sparkles",
    essentials: ["chat", "agents"],
    folded: ["chief", "models", "computerUse", "mcpServers"],
  },
  {
    id: "accounts",
    title: "Accounts and Devices",
    symbol: "person.crop.circle",
    essentials: ["accounts", "mobile"],
    folded: ["devices", "cloud", "keys", "import", "privacy"],
  },
  { id: "keyboard", title: "Keyboard", symbol: "keyboard", essentials: ["keyboard"], folded: [] },
  {
    id: "advanced",
    title: "Advanced",
    symbol: "curlybraces",
    essentials: [],
    folded: ["terminal", "editor", "browser", "advanced", "experimental", "development"],
  },
];

/** The categories a release build shows (no DEV-only Development). */
export const shown = (): readonly Category[] => shownCategories(false);

/** Every shown category placed on no page or on two: the grouping must cover the registry exactly,
 * so a category added to the Swift layout shows up here as a gap, not as a silently lost page. */
export function unplaced(): { missing: string[]; twice: string[] } {
  const placed = SIX_PAGES.flatMap((page) => [...page.essentials, ...page.folded]);
  const missing = shown()
    .map((category) => category.id)
    .filter((id) => !placed.includes(id));
  const twice = placed.filter((id, index) => placed.indexOf(id) !== index);
  return { missing, twice };
}

/** The categories of a page that this build shows. */
export function pageCategories(page: SixPage, which: "essentials" | "folded"): Category[] {
  const ids = new Set(shown().map((category) => category.id));
  return page[which].filter((id) => ids.has(id)).map(categoryById);
}

/** The settings a category holds: its rows plus its non-schema cards (accounts, models, ...). */
export const itemCount = (category: Category): number =>
  category.groups.reduce((sum, group) => sum + group.rows.length, 0) + category.lead.length + category.trail.length;

export const totalRows = (): number =>
  shown().reduce((sum, category) => sum + category.groups.reduce((n, group) => n + group.rows.length, 0), 0);

/** The current sidebar, as shipped: its headed sections and the collapsed More. */
export const currentSidebar = () => shownSidebarSections(false);

/** The real settings search, on default values (the prototype has no daemon). */
export function search(query: string): SearchGroup[] {
  return filterRows({ query, valueOf: (key) => rowsByKey.get(key)?.default });
}

/** The six page a category lands on. */
export function pageOf(categoryId: string): SixPage {
  return (
    SIX_PAGES.find((page) => page.essentials.includes(categoryId) || page.folded.includes(categoryId)) ?? SIX_PAGES[0]!
  );
}

/** A row's control, drawn from its kind and default value only. */
export type ControlPreview =
  | { kind: "switch"; on: boolean }
  | { kind: "popup"; label: string }
  | { kind: "button"; label: string };

export function controlOf(row: SchemaRow): ControlPreview {
  if (row.kind === "toggle") return { kind: "switch", on: row.default === true };
  const choice = row.choices?.find((item) => item.value === row.default);
  if (choice) return { kind: "popup", label: text(choice.title) };
  if (row.default_label) return { kind: "popup", label: text(row.default_label) };
  if (typeof row.default === "number") return { kind: "popup", label: String(row.default) };
  if (typeof row.default === "string" && row.default.length > 0 && row.default.length < 24)
    return { kind: "popup", label: row.default };
  return { kind: "button", label: "Edit…" };
}

/** The rows of a category, in display order, skipping the ones the page never lists. */
export const rowsOf = (category: Category): SchemaRow[] =>
  category.groups.flatMap((group) => group.rows).filter((row) => row.key !== "appearance.themeEdits");
