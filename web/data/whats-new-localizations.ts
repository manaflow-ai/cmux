import en from "../messages/en.json";
import de from "../messages/de.json";
import fr from "../messages/fr.json";
import es from "../messages/es.json";
import ja from "../messages/ja.json";
import ko from "../messages/ko.json";
import zhCN from "../messages/zh-CN.json";
import zhTW from "../messages/zh-TW.json";
import ar from "../messages/ar.json";
import it from "../messages/it.json";
import da from "../messages/da.json";
import pl from "../messages/pl.json";
import ru from "../messages/ru.json";
import bs from "../messages/bs.json";
import no from "../messages/no.json";
import ptBR from "../messages/pt-BR.json";
import th from "../messages/th.json";
import tr from "../messages/tr.json";
import km from "../messages/km.json";
import uk from "../messages/uk.json";
import { ios106MacRequirement } from "./mobile-mac-compat";
import type { WhatsNewAnnouncementContent } from "./whats-new";

const messages = {
  "en": en.MobileRelease106,
  "de": de.MobileRelease106,
  "fr": fr.MobileRelease106,
  "es": es.MobileRelease106,
  "ja": ja.MobileRelease106,
  "ko": ko.MobileRelease106,
  "zh-CN": zhCN.MobileRelease106,
  "zh-TW": zhTW.MobileRelease106,
  "ar": ar.MobileRelease106,
  "it": it.MobileRelease106,
  "da": da.MobileRelease106,
  "pl": pl.MobileRelease106,
  "ru": ru.MobileRelease106,
  "bs": bs.MobileRelease106,
  "no": no.MobileRelease106,
  "pt-BR": ptBR.MobileRelease106,
  "th": th.MobileRelease106,
  "tr": tr.MobileRelease106,
  "km": km.MobileRelease106,
  "uk": uk.MobileRelease106
};

function format(detail: string): string {
  return detail
    .replaceAll("{stableVersion}", ios106MacRequirement.stableMinVersion)
    .replaceAll("{nightlyVersion}", `${ios106MacRequirement.nightly.minBaseVersion}-nightly.${ios106MacRequirement.nightly.minBuild}`)
    .replaceAll("{rollbackBuild}", "20260914204800");
}

export const ios106Localizations: Record<string, WhatsNewAnnouncementContent> = Object.fromEntries(
  Object.entries(messages).map(([locale, copy]) => [locale, {
    title: copy.title,
    releaseLabel: copy.releaseLabel,
    features: [
      { symbol: "network", title: copy.connectionTitle, detail: copy.connectionDetail },
      { symbol: "arrow.down.circle", title: copy.updateTitle, detail: format(copy.updateDetail) },
      { symbol: "clock.arrow.circlepath", title: copy.rollbackTitle, detail: format(copy.rollbackDetail) },
    ],
  }]),
);
