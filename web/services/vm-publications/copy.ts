import en from "../../messages/en.json";
import ja from "../../messages/ja.json";

export function publicationApiCopy(key: keyof typeof en.PublicationApi, language?: string | null) {
  return (language?.toLowerCase().startsWith("ja") ? ja : en).PublicationApi[key];
}
