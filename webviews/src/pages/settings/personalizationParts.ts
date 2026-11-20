// Settings > Personalization's parts as data (PersonalizationCard draws them): which keys each part
// draws and which categories are their homes. Data only, with literal keys, so the router
// (sectionQueries.routeSection) reads it without importing the page's components (an import cycle).
import { DENSITY_CARD_ROWS, DENSITY_ROWS } from "./density";

/** A part of the page: its jump-bar id, the categories that are the homes of what it draws (each
 * gets a More in … link), the keys its cards draw and the schema rows drawn under them. */
export type Part = { id: PartID; homes: readonly string[]; cardKeys: readonly string[]; rows: readonly string[] };
export type PartID = "theme" | "background" | "chief" | "text" | "sounds";

/** The background rows the picker draws while it shows; without art they are rows of their own. */
const BACKGROUND_ROWS = [
  "appearance.background",
  "appearance.backgroundBlur",
  "appearance.backgroundOpacity",
  "appearance.paneBackgrounds",
  "appearance.backgroundRotation",
];

export const PERSONALIZATION_PARTS: readonly Part[] = [
  // The theme's one home is this page (the Theme page's card moved here), so its part links nowhere.
  { id: "theme", homes: [], cardKeys: ["appearance.theme", "appearance.appTheme", "appearance.accent"], rows: [] },
  {
    id: "background",
    homes: ["appearance"],
    cardKeys: [
      "appearance.background",
      "appearance.backgroundOpacity",
      "appearance.backgroundBlur",
      "appearance.backgroundRotation",
    ],
    rows: BACKGROUND_ROWS,
  },
  { id: "chief", homes: ["chief"], cardKeys: ["home.chiefPetEnabled", "home.chiefPetMascot"], rows: [] },
  {
    id: "text",
    // The density tiles are Appearance's; the chat text rows (Chat's whole Chat Text card) are Chat's.
    homes: ["appearance", "chat"],
    cardKeys: [...DENSITY_ROWS],
    rows: [
      "agentPane.display.font.ui",
      "agentPane.display.font.preset",
      "agentPane.display.font.size",
      "agentPane.display.font.lineHeight",
      "agentPane.display.code.family",
      "agentPane.display.code.scale",
      "agentPane.display.transcriptView",
    ],
  },
  {
    id: "sounds",
    homes: ["notifications"],
    cardKeys: [],
    rows: ["notifications.sound", "notifications.sounds.volume", "notifications.sounds.when"],
  },
];

/** Every key this page reads and writes: each one a row of its home category (personalization.test.ts). */
export const PERSONALIZATION_KEYS: readonly string[] = [
  ...new Set(PERSONALIZATION_PARTS.flatMap((part) => [...part.cardKeys, ...part.rows])),
];

export const FOCUS_PREFIX = "personalization.";

/** The part that draws a key, for a key only this page draws (a search result opens that part). */
export function personalizationPartOf(key: string): PartID | null {
  // The density card there also draws Text Size and the custom densities.
  if (DENSITY_CARD_ROWS.has(key)) return "text";
  return PERSONALIZATION_PARTS.find((part) => part.cardKeys.includes(key) || part.rows.includes(key))?.id ?? null;
}

/** `#/settings/personalization?focus=personalization.background` opens on that part (Change Background…);
 * `?focus=<key>` (a search result) opens on the part that draws the key. */
export function personalizationPart(focus: string | null): PartID | null {
  if (focus && !focus.startsWith(FOCUS_PREFIX)) return personalizationPartOf(focus);
  const id = focus?.slice(FOCUS_PREFIX.length) ?? null;
  return PERSONALIZATION_PARTS.some((part) => part.id === id) ? (id as PartID) : null;
}
