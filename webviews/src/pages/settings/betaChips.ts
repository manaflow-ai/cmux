// Beta chips (Taste Board #15, `appearance.settingsBetaChips`, off by default): with the opt-in on,
// the page draws a small Beta chip beside the title of each experimental row and beside the
// Experimental category's sidebar entry, so people find new experiments. It reads only what the
// schema export already has (the page layout's homes, each row's key and keywords); off, nothing
// is drawn and the page is unchanged.
import { useSettingsSelector } from "./context";
import { homes } from "./categories";
import type { SchemaRow } from "./schema";
import { valueOf } from "./store";

export const BETA_CHIPS_KEY = "appearance.settingsBetaChips";

/** The category whose sidebar entry gets the chip; every row on it is experimental. */
export const EXPERIMENTAL_CATEGORY = "experimental";

/** Keywords that mark a row as an experiment wherever it lives (Advanced's labs.* rows,
 * Customize From the Window). "beta" alone is not one: the Update Channel row offers a beta ring. */
const EXPERIMENT_KEYWORDS: ReadonlySet<string> = new Set(["labs", "experimental"]);

/** Whether a row is an experiment: it lives on the Experimental page, is a `labs.` key, or its
 * schema keywords say labs or experimental. */
export function isExperimentalRow(row: Pick<SchemaRow, "key" | "keywords">): boolean {
  if (homes.get(row.key)?.category === EXPERIMENTAL_CATEGORY) return true;
  if (row.key.startsWith("labs.")) return true;
  return row.keywords.some((word) => EXPERIMENT_KEYWORDS.has(word));
}

/** Whether a category's sidebar entry gets the chip. */
export function isExperimentalCategory(id: string): boolean {
  return id === EXPERIMENTAL_CATEGORY;
}

/** True while the opt-in is on; a row renders again only when it flips. */
export function useBetaChips(): boolean {
  return useSettingsSelector((state) => valueOf(state, BETA_CHIPS_KEY) === true);
}
