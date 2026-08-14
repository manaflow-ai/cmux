import type { Locale } from "../../../../i18n/routing";

import ar from "./content/ar.json";
import bs from "./content/bs.json";
import da from "./content/da.json";
import de from "./content/de.json";
import en from "./content/en.json";
import es from "./content/es.json";
import fr from "./content/fr.json";
import it from "./content/it.json";
import ja from "./content/ja.json";
import km from "./content/km.json";
import ko from "./content/ko.json";
import no from "./content/no.json";
import pl from "./content/pl.json";
import ptBR from "./content/pt-BR.json";
import ru from "./content/ru.json";
import th from "./content/th.json";
import tr from "./content/tr.json";
import uk from "./content/uk.json";
import zhCN from "./content/zh-CN.json";
import zhTW from "./content/zh-TW.json";

export type PrivacyPolicySubsection = {
  readonly heading: string;
  readonly paragraphs?: readonly string[];
  readonly bullets?: readonly string[];
  readonly afterBullets?: readonly string[];
};

export type PrivacyPolicySection = {
  readonly heading?: string;
  readonly paragraphs?: readonly string[];
  readonly bullets?: readonly string[];
  readonly afterBullets?: readonly string[];
  readonly subsections?: readonly PrivacyPolicySubsection[];
};

export type PrivacyPolicyContent = {
  readonly metadataTitle: string;
  readonly metadataDescription: string;
  readonly title: string;
  readonly lastUpdated: string;
  readonly sections: readonly PrivacyPolicySection[];
};

export const privacyPolicyContent = {
  en,
  ja,
  "zh-CN": zhCN,
  "zh-TW": zhTW,
  ko,
  de,
  es,
  fr,
  it,
  da,
  pl,
  ru,
  bs,
  ar,
  no,
  "pt-BR": ptBR,
  th,
  tr,
  km,
  uk,
} satisfies Record<Locale, PrivacyPolicyContent>;

export function privacyPolicyForLocale(locale: string): PrivacyPolicyContent {
  return privacyPolicyContent[locale as Locale] ?? privacyPolicyContent.en;
}
