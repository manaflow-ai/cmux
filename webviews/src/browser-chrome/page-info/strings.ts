import { createStrings, type Strings } from "../../pages/shared/i18n";
import table from "./generated/strings.json";

let shared: Strings | undefined;

/** The Page Info table (Localizable.xcstrings next to this file), made once per page. */
export function pageInfoStrings(languages?: readonly string[]): Strings {
  if (languages) return createStrings(table, languages);
  shared ??= createStrings(table);
  return shared;
}
