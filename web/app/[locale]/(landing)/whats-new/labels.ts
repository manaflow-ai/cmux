import { getTranslations } from "next-intl/server";
import type { WhatsNewLabels } from "./whats-new-document";

/** The page's own strings (messages: whatsNew); release text comes localized in the documents. */
export async function whatsNewLabels(locale: string): Promise<WhatsNewLabels> {
  const t = await getTranslations({ locale, namespace: "whatsNew" });
  return {
    categories: {
      new: t("categories.new"),
      improved: t("categories.improved"),
      fixed: t("categories.fixed"),
      security: t("categories.security"),
    },
    channels: { stable: t("channels.stable"), rc: t("channels.rc"), nightly: t("channels.nightly") },
    audiences: { teams: t("audiences.teams"), enterprise: t("audiences.enterprise") },
    platforms: { macos: "macOS", ios: "iOS", cli: "CLI", web: t("platforms.web") },
    openInCmux: t("openInCmux"),
    learnMore: t("learnMore"),
  };
}
