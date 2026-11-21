// The cards' words: `Localizable.xcstrings` next to this file, with the keys of the Swift catalogs
// they replace (`home.mcpConnect.*`, `home.agentPane.*`, `home.firstRun.*`, `home.starter.*`,
// `home.linkPreview.*`, `home.headerPanels.*`), so translations carry over. gen-strings.mjs
// (`home-messages-cards`) writes `generated/strings.json` from it.
import { createStrings, type Strings } from "../../shared/i18n";
import table from "./generated/strings.json";

export type { Strings };

/** The cards' table in the app's language (`tags`: the page's languages, for tests). */
export function cardStrings(tags?: readonly string[]): Strings {
  return createStrings(table, tags);
}
