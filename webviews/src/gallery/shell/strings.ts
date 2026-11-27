import { resolveLanguage } from "../../pages/shared/i18n";
import table from "../generated/strings.json";
import { isPseudo, pseudoText } from "../pseudo";

export function experimentalLabel(locale: string): string {
  const english = table.en["gallery.experimental"];
  if (isPseudo(locale)) return pseudoText(english, locale);
  const language = resolveLanguage([locale], Object.keys(table)) as keyof typeof table;
  return table[language]?.["gallery.experimental"] ?? english;
}
