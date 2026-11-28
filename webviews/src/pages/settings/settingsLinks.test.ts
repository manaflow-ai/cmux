// Every registered settings deep link lands exactly on its target (ask-6bed134465). The ids come from
// the schema and the page layout, so a new row, card, category or connection gets a link the day it
// lands, and this walks every one: a link that resolves anywhere else, or a card or connection with
// no route, fails here.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { CATEGORY_CARDS, categories, defaultCategory, homes } from "./categories";
import { routeSection } from "./sectionQueries";
import {
  SETTINGS_CONNECTIONS,
  cardHome,
  resolveSettingsLink,
  settingsLinkIds,
  splitSettingsPath,
} from "./settingsLinks";

const here = import.meta.dir;

function source(dir: string): string {
  return readdirSync(dir)
    .map((name) => {
      const file = path.join(dir, name);
      if (statSync(file).isDirectory()) return name === "generated" ? "" : source(file);
      return /\.tsx?$/.test(name) && !/\.test\./.test(name) ? readFileSync(file, "utf8") : "";
    })
    .join("\n");
}

const ids = settingsLinkIds();

test("every registered id resolves to its exact category and target", () => {
  const wrong = ids.flatMap(({ id, section, target }) => {
    const { section: pathSection, focus } = splitSettingsPath(id);
    const link = resolveSettingsLink(pathSection, focus);
    const ok = link.section === section && link.missing === null && (target === null || link.target === target);
    // The loader reads the same section the page draws.
    const loads = routeSection(pathSection, focus) === section;
    return ok && loads ? [] : [`${id} -> ${JSON.stringify(link)} (want ${section} ${target})`];
  });
  expect(wrong).toEqual([]);
});

test("every row, card, category and connection has an id", () => {
  const registered = new Set(ids.map((entry) => entry.id));
  const missing = [
    ...categories.map((c) => c.id),
    ...homes.keys(),
    ...CATEGORY_CARDS.filter((card) => cardHome(card) !== null).map((card) => `${cardHome(card)}/${card}`),
    ...Object.keys(SETTINGS_CONNECTIONS).map((name) => `connections/${name}`),
  ].filter((id) => !registered.has(id));
  expect(missing).toEqual([]);
  expect(ids.length).toBeGreaterThan(500);
});

test("every card the page can draw is placed in a category, so it has a route", () => {
  const unplaced = CATEGORY_CARDS.filter((card) => cardHome(card) === null);
  expect(unplaced).toEqual([]);
});

test("every connection target is an element the page draws", () => {
  const code = source(here);
  const absent = Object.entries(SETTINGS_CONNECTIONS).filter(([, { target }]) => {
    const [, attr, value] = /^\[([a-z-]+)="([^"]+)"\]$/.exec(target) ?? [];
    if (!attr || !value) return true;
    return !code.includes(`${attr}="${value}"`) && !code.includes(`${attr}={`);
  });
  expect(absent).toEqual([]);
});

test("Leo's links land on GitHub and the connections hub, not a search", () => {
  for (const id of ["connections/github", "github", "accounts/github"]) {
    const { section, focus } = splitSettingsPath(id);
    expect(resolveSettingsLink(section, focus)).toMatchObject({
      section: "accounts",
      target: '[data-card="github-connection"]',
      targetRequired: true,
      missing: null,
    });
  }
  expect(resolveSettingsLink("connections", undefined)).toMatchObject({ section: "integrations", missing: null });
  expect(resolveSettingsLink("accounts", undefined)).toMatchObject({ section: "accounts", missing: null });
  // A hosted connection by catalog id lands on its hub row, and says so if the hub has none.
  expect(resolveSettingsLink("connections", "linear")).toMatchObject({
    section: "integrations",
    target: '[data-hub-connection="linear"]',
    targetRequired: true,
  });
});

test("an unknown id is named, never a silent General", () => {
  expect(resolveSettingsLink("nonsense", undefined)).toMatchObject({ section: defaultCategory, missing: "nonsense" });
  expect(resolveSettingsLink("accounts", "nonsense")).toMatchObject({ section: "accounts", missing: "nonsense" });
  expect(resolveSettingsLink("accounts", "card.nonsense")).toMatchObject({
    section: "accounts",
    focus: "card.nonsense",
  });
});

test("existing links keep landing where they did", () => {
  expect(resolveSettingsLink("cloud", "cloud.claude")).toMatchObject({
    section: "cloud",
    focus: "cloudModels.add.claude",
  });
  expect(resolveSettingsLink("machines", undefined)).toMatchObject({ section: "accounts", card: "machines" });
  expect(resolveSettingsLink("models", "models.add")).toMatchObject({
    section: "models",
    focus: "models.add",
    missing: null,
  });
  expect(resolveSettingsLink("personalization", undefined)).toMatchObject({ section: "appearance" });
  expect(resolveSettingsLink(undefined, undefined)).toMatchObject({ section: defaultCategory, missing: null });
});

test("duress: every id resolves, 20 passes, in bounded time", () => {
  const started = performance.now();
  let resolved = 0;
  for (let pass = 0; pass < 20; pass++) {
    for (const { id } of ids) {
      const { section, focus } = splitSettingsPath(id);
      resolveSettingsLink(section, focus);
      resolved++;
    }
  }
  const ms = performance.now() - started;
  console.log(`Duress: ${resolved} links resolved in ${ms.toFixed(1)} ms (${ids.length} ids)`);
  expect(ms).toBeLessThan(5_000);
});
