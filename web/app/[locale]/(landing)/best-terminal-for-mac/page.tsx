import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { CompareTable, LandingCTA } from "../landing-ui";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.bestTerminal" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/best-terminal-for-mac"),
  };
}

export default function BestTerminalForMacPage() {
  const t = useTranslations("landing.bestTerminal");
  const tl = useTranslations("landing.links");
  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("glance")}</h2>
      <CompareTable
        headers={[t("thTerminal"), t("thBuiltFor"), t("thRenderer"), t("thPlatform")]}
        rows={[
          ["cmux", t("cmuxBuiltFor"), "GPU (libghostty)", "macOS"],
          ["Ghostty", t("ghosttyBuiltFor"), "GPU", "macOS, Linux"],
          ["iTerm2", t("iterm2BuiltFor"), "GPU / CPU", "macOS"],
          ["Warp", t("warpBuiltFor"), "GPU", "macOS, Linux, Windows"],
          ["Terminal.app", t("terminalAppBuiltFor"), "CPU", "macOS"],
          ["Alacritty", t("alacrittyBuiltFor"), "GPU", "cross-platform"],
          ["kitty", t("kittyBuiltFor"), "GPU", "macOS, Linux"],
          ["WezTerm", t("weztermBuiltFor"), "GPU", "cross-platform"],
          ["tmux", t("tmuxBuiltFor"), "n/a", "Unix"],
        ]}
      />

      <h2>cmux</h2>
      <p>{t("cmuxBody")}</p>

      <h2>{t("ghosttyTitle")}</h2>
      <p>{t("ghosttyBody")}</p>

      <h2>{t("iterm2Title")}</h2>
      <p>{t("iterm2Body")}</p>

      <h2>{t("warpTitle")}</h2>
      <p>{t("warpBody")}</p>

      <h2>{t("terminalAppTitle")}</h2>
      <p>{t("terminalAppBody")}</p>

      <h2>{t("otherTitle")}</h2>
      <p>{t("otherBody")}</p>

      <h2>{t("tmuxTitle")}</h2>
      <p>{t("tmuxBody")}</p>

      <LandingCTA
        related={[
          { href: "/built-on-ghostty", label: tl("builtOnGhostty") },
          { href: "/claude-code-terminal", label: tl("claude") },
          { href: "/docs/getting-started", label: tl("getStarted") },
        ]}
      />
    </>
  );
}
