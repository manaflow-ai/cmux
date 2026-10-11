import { createStrings } from "../../pages/shared/i18n";
import table from "./generated/strings.json";
export const variantPickStrings = (languages?: readonly string[]) => createStrings(table, languages);
