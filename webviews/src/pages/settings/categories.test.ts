// P2/P4: every setting the page shows has exactly one home, and every old section route still
// opens the category that holds its rows. Category and group titles are in the page catalog.
import { expect, test } from "bun:test";
import exported from "../../../../schemas/settings/settings-schema.json";
import "./testCatalog";
import { readFileSync } from "node:fs";
import {
  CATEGORY_CARDS,
  categories,
  categoryOf,
  defaultCategory,
  homes,
  shownCategories,
  shownSection,
} from "./categories";
import { hasIcon } from "./icons";
import strings from "./generated/strings.json";
import { parseLocation } from "./router";
import { schema, sections } from "./schema";

test("every page row has exactly one home", () => {
  const placed = categories.flatMap((category) => category.groups.flatMap((group) => group.rows.map((row) => row.key)));
  expect(placed.length).toBe(new Set(placed).size);
  expect([...new Set(placed)].sort()).toEqual(schema.rows.map((row) => row.key).sort());
  expect(homes.size).toBe(schema.rows.length);
});

// In sidebar-section order (user 2026-10-30, "sections"): General and Updates, then Look and Feel,
// Tools, AI, Interaction, Accounts and Devices, Data and System.
test("the categories are the approved ones, in order", () => {
  expect(categories.map((category) => category.id)).toEqual([
    "general",
    "updates",
    "theme",
    "appearance",
    "terminal",
    "editor",
    "browser",
    "agents",
    "chief",
    "notifications",
    "keyboard",
    // Settings > Menus: every right-click menu's arrangement (Customize Menu… opens it).
    "menus",
    "accounts",
    "mobile",
    "devices",
    "server",
    "import",
    "privacy",
    "advanced",
    "experimental",
    "development",
  ]);
});

test("a route to the Development category opens the default category outside DEV builds", () => {
  expect(shownSection("development", false)).toBe(defaultCategory);
  expect(shownSection("development", true)).toBe("development");
  expect(shownSection("advanced", false)).toBe("advanced");
  // The relay key's own focus link lands in Development, which a non-DEV build does not show.
  expect(shownSection(parseLocation("/settings/development?focus=macScreen.debug.relayOnly").section, false)).toBe(
    defaultCategory,
  );
});

test("the Development category shows only in DEV builds", () => {
  const ids = (devBuild: boolean) => shownCategories(devBuild).map((category) => category.id);
  expect(ids(false)).not.toContain("development");
  expect(ids(true)).toContain("development");
  expect(categories.filter((category) => category.devOnly).map((category) => category.id)).toEqual(["development"]);
});

test("Devices shows in every build: NIGHTLY and Release use the built-in device hub", () => {
  // Mac Screen's sharing switch, device permissions and relays live only in Settings > Devices.
  const ids = (devBuild: boolean) => shownCategories(devBuild).map((category) => category.id);
  expect(ids(false)).toContain("devices");
  expect(ids(true)).toContain("devices");
  expect(shownSection("devices", false)).toBe("devices");
  expect(shownSection(parseLocation("/settings/devices").section, false)).toBe("devices");
});

test("old section routes and focused keys open the category that holds the row", () => {
  for (const section of sections)
    expect(categories.some((category) => category.id === categoryOf(section.id))).toBe(true);
  expect(parseLocation("/settings/notifications").section).toBe("notifications");
  expect(parseLocation("/settings/general?focus=history.terminalCommands").section).toBe("privacy");
  expect(parseLocation("/settings/nope").section).toBe("general");
});

test.each(["/settings/%", "/settings/%ZZ", "/settings/%E0%A4%A"])(
  "a malformed deep-link section falls back to General without breaking Settings (%s)",
  (href) => {
    expect(parseLocation(href).section).toBe(defaultCategory);
    // A real focused key still resolves to its home even when the section slug is corrupt.
    expect(parseLocation(`${href}?focus=history.terminalCommands`).section).toBe("privacy");
  },
);

test("a valid percent-encoded Settings category still opens normally", () => {
  expect(parseLocation("/settings/%61ppearance").section).toBe("appearance");
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
      groups: category.groups.map((group) => ({
        key: group.key,
        title: group.title,
        rows: group.rows.map((row) => row.key),
      })),
    })),
  ).toEqual(
    // dev_only is the Category's devOnly (checked by the DEV-only test above).
    (page!.categories as Array<Record<string, unknown>>).map(
      ({ aliases: _aliases, dev_only: _devOnly, ...category }) => category,
    ) as never,
  );
});

// Live QA 7c: Mobile's `iphone` (and Import's `square.and.arrow.down`) had no icon, so the sidebar
// drew the General gear for them. Every symbol the layout names, in the exported schema and in the
// Swift source it is exported from, has its own icon.
test("every category and section symbol has its own icon", () => {
  const exportedSymbols = [
    ...categories.map((category) => category.symbol),
    ...sections.map((section) => section.symbol),
  ];
  const layout = readFileSync(
    new URL(
      "../../../../Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsPageLayout.swift",
      import.meta.url,
    ),
    "utf8",
  );
  const swiftSymbols = [...layout.matchAll(/\bsymbol: "([^"]+)"/g)].map((match) => match[1]);
  expect(swiftSymbols).toContain("iphone");
  const missing = [...new Set([...exportedSymbols, ...swiftSymbols])].filter((symbol) => !hasIcon(symbol));
  expect(missing).toEqual([]);
});
