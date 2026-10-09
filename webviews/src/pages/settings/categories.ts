// The page's navigation (SETTINGS-PAGE-FIRST-PRINCIPLES P2, P4): categories by user task, not by
// scope or by the schema's sections. The layout (categories, group cards, their order and titles) is
// defined once in Swift (`SettingsPageLayout`) and exported as the schema's `page`; this page and the
// GPUI client render it from there (layer-ownership.md L5). Routes still accept the schema's section
// ids (`app settings <section>`, `#/settings/rooms`): each category lists them as `aliases`.
import { rowsByKey, schema, type LocalizedText, type SchemaRow } from "./schema";

/** The non-schema parts this page knows how to draw (Swift `SettingsPageLayout.Card`). */
export const CATEGORY_CARDS = [
  "themeStudio",
  "terminalInfo",
  "ghosttyDiagnostics",
  "computerUse",
  "harnesses",
  "spaces",
  "browserProfiles",
  "machines",
  "accounts",
  "advancedInfo",
  "advancedActions",
  "backdrops",
] as const;

/** A non-schema part a category draws (host lists, the theme studio, file actions). */
export type CategoryCard = (typeof CATEGORY_CARDS)[number];

const isCard = (card: string): card is CategoryCard => (CATEGORY_CARDS as readonly string[]).includes(card);

export type CategoryGroup = { key: string; title: LocalizedText; rows: SchemaRow[] };

export type Category = {
  id: string;
  title: LocalizedText;
  symbol: string;
  groups: CategoryGroup[];
  lead: CategoryCard[];
  trail: CategoryCard[];
  actions: string[];
};

function build(): { categories: Category[]; homes: Map<string, { category: string; group: string }> } {
  const homes = new Map<string, { category: string; group: string }>();
  const categories = schema.page.categories.map((category): Category => {
    const groups = category.groups.flatMap((group): CategoryGroup[] => {
      const rows = group.rows.map((key) => rowsByKey.get(key)).filter((row) => row !== undefined);
      if (rows.length === 0) return [];
      for (const row of rows) homes.set(row.key, { category: category.id, group: group.key });
      return [{ key: group.key, title: group.title, rows }];
    });
    return {
      id: category.id,
      title: category.title,
      symbol: category.symbol,
      groups,
      lead: category.lead.filter(isCard),
      trail: category.trail.filter(isCard),
      actions: category.actions,
    };
  });
  return { categories, homes };
}

const built = build();

export const categories: readonly Category[] = built.categories;

/** Where each row lives: its category and group. */
export const homes: ReadonlyMap<string, { category: string; group: string }> = built.homes;

export const defaultCategory = schema.page.default_category;

const aliases: ReadonlyMap<string, string> = new Map(
  schema.page.categories.flatMap((category) => category.aliases.map((alias) => [alias, category.id] as const)),
);

export function isCategory(id: string | undefined): id is string {
  return id !== undefined && categories.some((category) => category.id === id);
}

/** The category a route names: a category id, a schema section id (old links), else General. */
export function categoryOf(id: string | undefined): string {
  if (isCategory(id)) return id;
  return (id && aliases.get(id)) || defaultCategory;
}

export function categoryById(id: string): Category {
  return categories.find((category) => category.id === id) ?? categories[0]!;
}

/** The rows of a category, in display order. */
export function categoryRows(id: string): SchemaRow[] {
  return categoryById(id).groups.flatMap((group) => group.rows);
}
