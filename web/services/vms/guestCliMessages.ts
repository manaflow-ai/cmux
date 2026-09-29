import english from "../../messages/en.json";
import japanese from "../../messages/ja.json";
import arabic from "../../messages/ar.json";
import bosnian from "../../messages/bs.json";
import danish from "../../messages/da.json";
import german from "../../messages/de.json";
import spanish from "../../messages/es.json";
import french from "../../messages/fr.json";
import italian from "../../messages/it.json";
import khmer from "../../messages/km.json";
import korean from "../../messages/ko.json";
import norwegian from "../../messages/no.json";
import polish from "../../messages/pl.json";
import portuguese from "../../messages/pt-BR.json";
import russian from "../../messages/ru.json";
import thai from "../../messages/th.json";
import turkish from "../../messages/tr.json";
import ukrainian from "../../messages/uk.json";
import simplifiedChinese from "../../messages/zh-CN.json";
import traditionalChinese from "../../messages/zh-TW.json";

const guestMessages = {
  en: english.guestCLI, ja: japanese.guestCLI,
  ar: arabic.guestCLI, bs: bosnian.guestCLI, da: danish.guestCLI,
  de: german.guestCLI, es: spanish.guestCLI, fr: french.guestCLI,
  it: italian.guestCLI, km: khmer.guestCLI, ko: korean.guestCLI,
  no: norwegian.guestCLI, pl: polish.guestCLI, "pt-BR": portuguese.guestCLI,
  ru: russian.guestCLI, th: thai.guestCLI, tr: turkish.guestCLI,
  uk: ukrainian.guestCLI, "zh-CN": simplifiedChinese.guestCLI, "zh-TW": traditionalChinese.guestCLI,
};

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

export function guestMessageShell(keys?: readonly string[]): string {
  const cases = Object.entries(guestMessages)
    .map(([locale, messages]) => [locale, Object.fromEntries(Object.entries(messages).filter(([key]) => !keys || keys.includes(key)))] as const)
    .flatMap(([locale, messages]) => Object.entries(messages).map(([key, message]) =>
      `    ${locale}/${key}) printf ${shellQuote(message + "\n")} "$@" ;;`,
    ))
    .join("\n");

  return `cmux_message_lookup() {
  cmux_message_locale="$1"; cmux_message_key="$2"; shift 2
  case "$cmux_message_locale/$cmux_message_key" in
${cases}
    *) return 1 ;;
  esac
}

cmux_message() {
  case "\${LC_ALL:-\${LC_MESSAGES:-\${LANG:-en}}}" in
    ja*) cmux_message_locale=ja ;;
    zh_TW*|zh-TW*|zh_HK*|zh-HK*|zh_Hant*|zh-Hant*) cmux_message_locale=zh-TW ;;
    zh*) cmux_message_locale=zh-CN ;;
    pt*) cmux_message_locale=pt-BR ;;
    nb*|nn*|no*) cmux_message_locale=no ;;
${Object.keys(guestMessages).filter(locale => !["en", "ja", "zh-CN", "zh-TW", "pt-BR", "no"].includes(locale)).map(locale => `    ${locale}*) cmux_message_locale=${locale} ;;`).join("\n")}
    *) cmux_message_locale=en ;;
  esac
  cmux_message_lookup "$cmux_message_locale" "$@" || cmux_message_lookup en "$@"
}`;
}

export const GUEST_CMUX_MESSAGE_SHELL = guestMessageShell();
