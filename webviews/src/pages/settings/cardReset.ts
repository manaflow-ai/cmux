// Reset <card> on every Settings page outside the appearance ones (those reset a card from their own
// floating bar, AppearanceBar). Leo, 11-19: "make sure you can recover and stuff. for all
// customizations". A card is one as the page draws it (rowLevels.ts merges small ones); its reset
// clears only the keys of it the person set, never a managed one (the team's), and is one step of the
// page's card history, which the bar's Undo and Redo walk. The history is page state, never written.
import { APPEARANCE_CATEGORIES } from "./appearanceUndo";
import { categoryById } from "./categories";
import { DENSITY_CARD_ROWS } from "./density";
import { PERSONALIZATION_KEYS } from "./personalizationParts";
import { arrangeGroups } from "./rowLevels";
import type { LocalizedText } from "./schema";
import { t, text } from "./strings";

/** One card Reset <card> resets alone: its key in the page layout, its title and its keys (the rows
 * it shows and the ones behind its More Options; hidden rows are not on it). */
export type ResetCard = { key: string; title: LocalizedText; keys: string[] };

/** Keys Personalization draws, though their home is another page: that page does not show them. */
const HUB_KEYS: ReadonlySet<string> = new Set([...PERSONALIZATION_KEYS, ...DENSITY_CARD_ROWS]);

const cache = new Map<string, ResetCard[]>();

/** The cards of a page its Reset menu offers, in page order; none on an appearance page (its own
 * bar resets its cards). A merged card that draws no title keeps the title of the card merged into
 * ("When Quitting"). */
export function resetCards(categoryId: string): ResetCard[] {
  const known = cache.get(categoryId);
  if (known) return known;
  const category = categoryById(categoryId);
  const groups = APPEARANCE_CATEGORIES.includes(category.id)
    ? []
    : category.groups
        .map((group) => ({ ...group, rows: group.rows.filter((row) => !HUB_KEYS.has(row.key)) }))
        .filter((group) => group.rows.length > 0);
  const cards = arrangeGroups(category.id, groups).flatMap((card): ResetCard[] => {
    const keys = [...card.rows, ...(card.more ?? [])].map((row) => row.key);
    return keys.length === 0 ? [] : [{ key: card.key, title: card.title, keys }];
  });
  cache.set(categoryId, cards);
  return cards;
}

/** The name of a card's reset, in its menu and in Undo ("Reset Notifications"). */
export function cardResetLabel(card: ResetCard): string {
  return t("settingsPage.cardReset.item", text(card.title));
}
