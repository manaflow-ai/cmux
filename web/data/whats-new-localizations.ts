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

// 1.0.7 is prepared before its translation batch lands. Keep the base copy
// complete so every supported locale still receives the announcement through
// the client's English fallback instead of silently losing required actions.
const ios107English: WhatsNewAnnouncementContent = {
  title: "What's New in 1.0.7",
  releaseLabel: "1.0.7 · September 2026",
  features: [
    {
      symbol: "arrow.triangle.2.circlepath",
      title: "More reliable Mac connections",
      detail: "Startup and background recovery now move past an unresponsive Mac sooner, and the computer list stays stable while it refreshes.",
    },
    {
      symbol: "safari",
      title: "Browse from your iPhone",
      detail: "Open a paired Mac browser on this iPhone when that Mac advertises browser support. Older Macs show an update hint for this feature.",
    },
    {
      symbol: "arrow.down.circle",
      title: "Update cmux on your Mac",
      detail: `Core connections require cmux ${ios106MacRequirement.stableMinVersion} or later, or NIGHTLY ${ios106MacRequirement.nightly.minBaseVersion}-nightly.${ios106MacRequirement.nightly.minBuild} or later. Update any Mac that shows an update hint.`,
    },
    {
      symbol: "gearshape",
      title: "Enable iOS pairing",
      detail: "On every Mac you want to use, open Settings > Mobile and turn on Enable iOS pairing.",
    },
  ],
};

export const ios107Localizations: Record<string, WhatsNewAnnouncementContent> = {
  en: ios107English,
};
