import { createStrings, type Strings } from "../../pages/shared/i18n";
import table from "./generated/strings.json";

let shared: Strings | undefined;

/** The toolbar's table (Localizable.xcstrings next to this file, plus the Page Info chip's words). */
export function toolbarStrings(languages?: readonly string[]): Strings {
  if (languages) return createStrings(table, languages);
  shared ??= createStrings(table);
  return shared;
}
