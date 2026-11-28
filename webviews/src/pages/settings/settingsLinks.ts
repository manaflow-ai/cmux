// Settings deep links: one registry of every place a link can land, and the resolver every route
// goes through (ask-6bed134465: "Every setting and connection must have a stable deep link that lands
// exactly on it, tested"). `cmux://settings/<a>/<b>` reaches the page as `#/settings/<a>?focus=<b>`
// (Swift DeepLink.settingsRoute); this module turns that into the category to open, the focus to
// hand its rows and cards, and the element to scroll to and highlight. A name it does not know comes
// back as `missing`, and the page says so: it never quietly opens General (the old
// `cmux-nightly://settings/connections` opened a page with no GitHub row on it).
//
// Ids, all stable and generated from the schema, so a new row, card or category has a link the day
// it lands (settingsLinks.test.ts walks every one):
//   <category> and every category alias          `appearance`, `theme`
//   <card> and <category>/<card>                 `machines`, `accounts/machines`
//   <row key> and <category>/<row key>           `terminal.fontSize`, `terminal/terminal.fontSize`
//   connections, connections/<connection>, <connection>, <category>/<connection>
//                                                `connections/github`, `github`, `accounts/github`
import { categories, categoryById, defaultCategory, homes, isCard, isCategory, type CategoryCard } from "./categories";
import { legacyPart } from "./legacyLinks";
import { schema } from "./schema";

/** A named connection: the category that draws it, the focus its card reads, the element it lands on. */
export type SettingsConnection = { section: string; focus: string; target: string };

/** Every connection with a fixed home. A hosted MCP connection (Integrations) is reached by its
 * catalog id, `connections/<id>`, and lands on its hub row once the hub draws it. */
export const SETTINGS_CONNECTIONS: Readonly<Record<string, SettingsConnection>> = {
  github: { section: "accounts", focus: "connection.github", target: '[data-card="github-connection"]' },
  claude: { section: "cloud", focus: "cloudModels.add.claude", target: '[data-card="cloudModels"]' },
  chatgpt: { section: "cloud", focus: "cloudModels.add.chatgpt", target: '[data-card="cloudModels"]' },
  apiKey: { section: "cloud", focus: "cloudModels.add", target: '[data-card="cloudModels"]' },
};

/** Other spellings of a connection (`api-key` from the URL scheme's kebab case). */
const CONNECTION_ALIASES: Readonly<Record<string, string>> = { "api-key": "apiKey", apikey: "apiKey", gh: "github" };

/** Section names that are neither a category nor a schema alias: `connections` is the Integrations
 * hub (every hosted connection); `integrations` stays its own category id. */
const SECTION_ALIASES: Readonly<Record<string, string>> = { connections: "integrations" };

/** Where a link lands. `target` is a CSS selector for the element to scroll to and highlight;
 * `missing` names the part of the link nothing matched (the page shows it instead of guessing);
 * `targetRequired` marks a target whose absence after the page draws is itself a miss (a hosted
 * connection id, the GitHub card on a host that sends none). */
export type SettingsLink = {
  section: string;
  focus: string | null;
  card: CategoryCard | null;
  target: string | null;
  targetRequired: boolean;
  missing: string | null;
};

const schemaAliases: ReadonlyMap<string, string> = new Map(
  schema.page.categories.flatMap((category) => category.aliases.map((alias) => [alias, category.id] as const)),
);

function connectionNamed(name: string): SettingsConnection | null {
  return SETTINGS_CONNECTIONS[CONNECTION_ALIASES[name] ?? name] ?? null;
}

/** The category a placed card is drawn in, preferring `category` when it draws it too. */
export function cardHome(card: string, category?: string | null): string | null {
  if (!isCard(card)) return null;
  const draws = (id: string) => {
    const { lead, trail } = categoryById(id);
    return lead.includes(card) || trail.includes(card);
  };
  if (category && isCategory(category) && draws(category)) return category;
  return categories.find((c) => draws(c.id))?.id ?? null;
}

function categoryNamed(name: string): string | null {
  if (isCategory(name)) return name;
  return schemaAliases.get(name) ?? SECTION_ALIASES[name] ?? null;
}

function rowTarget(key: string): string {
  return `[data-row-key="${CSS_ESCAPE(key)}"]`;
}

function cardTarget(card: string): string {
  return `[data-card-slot="${card}"]`;
}

// `CSS.escape` is not in every test runtime; row keys are `[A-Za-z0-9._-]`, so quotes are all that
// could break the selector.
const CSS_ESCAPE = (value: string) => value.replace(/["\\]/g, "\\$&");

/** A focus resolved against the category the path named: the category it really lives in. */
type FocusHit = { section: string; focus: string | null; card: CategoryCard | null; target: string; required: boolean };

function resolveFocus(focus: string, category: string | null, pathSection: string | undefined): FocusHit | null {
  const home = homes.get(focus);
  if (home) return { section: home.category, focus, card: null, target: rowTarget(focus), required: false };
  if (focus.startsWith("card.")) {
    const card = focus.slice("card.".length);
    const where = cardHome(card, category);
    return where
      ? { section: where, focus, card: card as CategoryCard, target: cardTarget(card), required: false }
      : null;
  }
  if (focus.startsWith("connection.")) {
    const name = focus.slice("connection.".length);
    const named = connectionNamed(name);
    if (named) return { section: named.section, focus: named.focus, card: null, target: named.target, required: true };
    // A hosted connection by catalog id: the Integrations hub row.
    if (!/^[A-Za-z0-9._-]+$/.test(name)) return null;
    return {
      section: "integrations",
      focus,
      card: null,
      target: `[data-hub-connection="${name}"]`,
      required: true,
    };
  }
  if (focus.startsWith("cloud.")) {
    const named = connectionNamed(focus.slice("cloud.".length));
    return named && named.section === "cloud"
      ? { section: "cloud", focus: named.focus, card: null, target: named.target, required: false }
      : null;
  }
  // The URL scheme's second segment, bare: `accounts/github`, `accounts/machines`.
  const named = connectionNamed(focus);
  if (named) return { section: named.section, focus: named.focus, card: null, target: named.target, required: true };
  const where = cardHome(focus, category);
  if (where) {
    return {
      section: where,
      focus: `card.${focus}`,
      card: focus as CategoryCard,
      target: cardTarget(focus),
      required: false,
    };
  }
  // `connections/<id>`: a hosted connection by its catalog id.
  if (pathSection === "connections" && /^[A-Za-z0-9._-]+$/.test(focus))
    return resolveFocus(`connection.${focus}`, category, undefined);
  return null;
}

/**
 * Where `#/settings/<section>?focus=<focus>` lands. An old Personalization link keeps its mapping
 * (legacyLinks.ts). A card's own focus (`models.add`, `appearance.background`'s picker) that is no
 * row passes through to the card unchanged; a bare word nothing knows is `missing`.
 */
export function resolveSettingsLink(section: string | undefined, rawFocus: string | null | undefined): SettingsLink {
  const legacy = legacyPart(section, rawFocus);
  if (legacy) {
    const card = legacy.focus?.startsWith("card.") ? (legacy.focus.slice(5) as CategoryCard) : null;
    return { section: legacy.section, focus: legacy.focus, card, target: null, targetRequired: false, missing: null };
  }
  let category: string | null = null;
  let focus = rawFocus ?? null;
  let missing: string | null = null;
  let pathTarget: FocusHit | null = null;
  if (!section) category = defaultCategory;
  else if ((category = categoryNamed(section))) {
    // A path that is a category and also a card of it (`machines`) opens on that card.
    if (!focus) pathTarget = section !== category ? resolveFocus(section, category, undefined) : null;
  } else if ((pathTarget = resolveFocus(section, null, undefined))) {
    category = pathTarget.section;
  } else {
    missing = section;
  }
  const hit = focus ? resolveFocus(focus, category, section) : pathTarget;
  if (focus && !hit && !focus.includes(".")) missing ??= focus;
  if (hit) {
    return {
      section: hit.section,
      focus: hit.focus,
      card: hit.card,
      target: hit.target,
      targetRequired: hit.required,
      missing,
    };
  }
  if (focus && !focus.includes(".")) focus = null;
  return { section: category ?? defaultCategory, focus, card: null, target: null, targetRequired: false, missing };
}

/** One registered link and where it must land. */
export type SettingsLinkId = { id: string; section: string; target: string | null };

/** Every registered id (see the header), each with the category and element it must land on. */
export function settingsLinkIds(): SettingsLinkId[] {
  const out: SettingsLinkId[] = [];
  for (const category of categories) {
    out.push({ id: category.id, section: category.id, target: null });
    for (const card of [...category.lead, ...category.trail]) {
      out.push({ id: `${category.id}/${card}`, section: category.id, target: cardTarget(card) });
      if (cardHome(card) === category.id && !categoryNamed(card)) {
        out.push({ id: card, section: category.id, target: cardTarget(card) });
      }
    }
  }
  for (const [alias, id] of [...schemaAliases, ...Object.entries(SECTION_ALIASES)]) {
    if (!isCategory(alias)) out.push({ id: alias, section: id, target: null });
  }
  for (const [key, home] of homes) {
    out.push({ id: key, section: home.category, target: rowTarget(key) });
    out.push({ id: `${home.category}/${key}`, section: home.category, target: rowTarget(key) });
  }
  for (const [name, connection] of Object.entries({
    ...SETTINGS_CONNECTIONS,
    ...Object.fromEntries(Object.entries(CONNECTION_ALIASES).map(([a, n]) => [a, SETTINGS_CONNECTIONS[n]!])),
  })) {
    out.push({ id: `connections/${name}`, section: connection.section, target: connection.target });
    out.push({ id: name, section: connection.section, target: connection.target });
    out.push({ id: `${connection.section}/${name}`, section: connection.section, target: connection.target });
  }
  return out;
}

/** How a `cmux://settings/<path>` link reaches the page (Swift DeepLink.settingsRoute's
 * pass-through): the first segment is the section, the rest the focus. */
export function splitSettingsPath(path: string): { section: string | undefined; focus: string | undefined } {
  const [section, ...rest] = path.split("/").filter(Boolean);
  return { section, focus: rest.length ? rest.join(".") : undefined };
}
