import { createStrings, type Strings } from "../../pages/shared/i18n";
import table from "./generated/strings.json";

let shared: Strings | undefined;

/** The edit bubble's words (CmuxNextBookmarks' Localizable.xcstrings), made once per page. */
export function bookmarkEditStrings(languages?: readonly string[]): Strings {
  if (languages) return createStrings(table, languages);
  shared ??= createStrings(table);
  return shared;
}
