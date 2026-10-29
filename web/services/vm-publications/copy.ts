import en from "../../messages/en.json";
import ja from "../../messages/ja.json";
import { preferredLocaleFromAcceptLanguage } from "../../i18n/accept-language";

export function publicationApiCopy(key: keyof typeof en.PublicationApi, language?: string | null) {
  return (preferredLocaleFromAcceptLanguage(language ?? "", ["en", "ja"]) === "ja" ? ja : en).PublicationApi[key];
}
