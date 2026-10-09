// P2/P4: every setting the page shows has exactly one home, and every old section route still
// opens the category that holds its rows. Category and group titles are in the page catalog.
import { expect, test } from "bun:test";
import exported from "../../../../schemas/settings/settings-schema.json";
import "./testCatalog";
import { CATEGORY_CARDS, categories, categoryOf, homes } from "./categories";
import strings from "./generated/strings.json";
import { parseLocation } from "./router";
import { schema, sections } from "./schema";

test("every page row has exactly one home", () => {
  const placed = categories.flatMap((category) => category.groups.flatMap((group) => group.rows.map((row) => row.key)));
  expect(placed.length).toBe(new Set(placed).size);
  expect([...new Set(placed)].sort()).toEqual(schema.rows.map((row) => row.key).sort());
  expect(homes.size).toBe(schema.rows.length);
});

test("the categories are the approved ones, in order", () => {
  expect(categories.map((category) => category.id)).toEqual([
    "general",
    "theme",
    "appearance",
    "terminal",
    "agents",
    "notifications",
    "browser",
    "keyboard",
    "privacy",
    "accounts",
    "advanced",
    "experimental",
  ]);
});

test("old section routes and focused keys open the category that holds the row", () => {
  for (const section of sections)
    expect(categories.some((category) => category.id === categoryOf(section.id))).toBe(true);
  expect(parseLocation("/settings/notifications").section).toBe("notifications");
  expect(parseLocation("/settings/general?focus=history.terminalCommands").section).toBe("privacy");
  expect(parseLocation("/settings/nope").section).toBe("general");
});

test("every category and group title is in all locales", () => {
  const catalog = strings as Record<string, Record<string, string>>;
  const keys = categories.flatMap((category) => [
    category.title.key!,
    ...category.groups.map((group) => group.title.key!),
  ]);
  const missing = Object.entries(catalog).flatMap(([locale, table]) =>
    keys.filter((key) => !table[key]).map((key) => `${locale}:${key}`),
  );
  expect(missing).toEqual([]);
});

// Every non-schema card the export names has a renderer here; none is dropped silently.
test("every exported card is one the page draws", () => {
  const page = (exported as { page?: { categories: Array<{ lead: string[]; trail: string[] }> } }).page;
  const cards = (page?.categories ?? []).flatMap((category) => [...category.lead, ...category.trail]);
  expect(cards.length).toBeGreaterThan(0);
  expect(cards.filter((card) => !(CATEGORY_CARDS as readonly string[]).includes(card))).toEqual([]);
});

// Parity: the page draws the layout the Swift schema exports (`page`), nothing it copied by hand.
test("the page renders the exported layout", () => {
  const page = (exported as { page?: { categories: unknown[]; default_category: string } }).page;
  expect(page).toBeDefined();
  expect(
    categories.map((category) => ({
      id: category.id,
      title: category.title,
      symbol: category.symbol,
      lead: category.lead,
      trail: category.trail,
      actions: category.actions,
      groups: category.groups.map((group) => ({ key: group.key, title: group.title, rows: group.rows.map((row) => row.key) })),
    })),
  ).toEqual(
    (page!.categories as Array<Record<string, unknown>>).map(({ aliases: _aliases, ...category }) => category) as never,
  );
});
