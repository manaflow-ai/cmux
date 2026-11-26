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

// In sidebar-section order: six pages (one settings area, findings G6; David Beyer 2026-11-20:
// Settings felt overwhelming; Leo 2026-11-22: "ay, fuck it we ball"), each opening on its first.
test("the categories are the approved ones, in order", () => {
  expect(categories.map((category) => category.id)).toEqual([
    // General: the app itself, every customization one click away (Leo 2026-11-22), what it tells
    // you, its updates, the New Tab page and menus.
    "general",
    "customize",
    "notifications",
    "updates",
    "newTab",
    // Settings > Menus: every right-click menu's arrangement (Customize Menu… opens it).
    "menus",
    // Appearance holds the theme, the background and density; old Theme and Personalization links
    // open it (next tests). Settings overhaul (2026-11-07): the sidebar and tabs have pages.
    "appearance",
    "sidebar",
    "tabs",
    // AI: the chat, agents, Chief, models, automations, computer use and MCP servers.
    "chat",
    "agents",
    "chief",
    // Settings > Models: which subscription or key each Cloud thread runs on (model-connections.md).
    "models",
    // Settings > Automations: cloud automations, what sets an agent off and what it does (Leo
    // 2026-11-24: "having people be able to set up their own conditions for when autocloud will go off").
    "automations",
    "computerUse",
    // Settings > MCP Servers: the services agents use for the person (user 2026-11-18).
    "mcpServers",
    // Accounts and Devices. Mobile stays its own page (Lucas 2026-11-11).
    "accounts",
    "mobile",
    // Devices holds what Server showed, and its old id opens it (next test).
    "devices",
    // Settings > Cloud: what Cloud chats run on, Cloud Environments and Cloud Workspaces.
    "cloud",
    // Keys: the keys agents keep and ask the person for (design/settings-keys.md).
    "keys",
    // Integrations: the integrations hub, linked accounts agents act through (Leo 2026-11-23: "an
    // aggregator of integrations. linking up things like e.g. stripe so that your agents can refund for you").
    "integrations",
    "import",
    "privacy",
    "keyboard",
    // Advanced: the app's internals, the terminal, editor and browser engines, and extensions.
    "advanced",
    "terminal",
    "editor",
    "browser",
    // Settings > Extensions: each installed extension's own declared settings.
    "extensions",
    "experimental",
    "development",
  ]);
});

test("old Theme and Personalization links open Appearance", () => {
  expect(categoryOf("theme")).toBe("appearance");
  expect(categoryOf("personalization")).toBe("appearance");
});

test("Mobile opens its own page, and old Server links open Devices", () => {
  expect(categoryOf("mobile")).toBe("mobile");
  expect(categoryOf("server")).toBe("devices");
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
// layout source it is exported from, has its own icon.
test("every category and section symbol has its own icon", () => {
  const exportedSymbols = [
    ...categories.map((category) => category.symbol),
    ...sections.map((section) => section.symbol),
  ];
  const layout = JSON.parse(
    readFileSync(new URL("../../../../schemas/settings/source/page-layout.json", import.meta.url), "utf8"),
  ) as { sidebar_sections: Array<{ categories: Array<{ symbol: string }> }> };
  const layoutSymbols = layout.sidebar_sections.flatMap((run) => run.categories.map((category) => category.symbol));
  expect(layoutSymbols).toContain("sidebar.left");
  const missing = [...new Set([...exportedSymbols, ...layoutSymbols])].filter((symbol) => !hasIcon(symbol));
  expect(missing).toEqual([]);
});
