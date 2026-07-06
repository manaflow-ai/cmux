import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
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
      <SiteHeader section={tl("bestTerminal")} />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
          <h1>{t("title")}</h1>
          <p>{t("intro")}</p>

          <h2>{t("glance")}</h2>
          <CompareTable
            headers={[t("thTerminal"), t("thBuiltFor"), t("thRenderer"), t("thPlatform")]}
            rows={[
              ["cmux", t("cmuxBuiltFor"), t("rGpuLib"), t("pMac")],
              ["Ghostty", t("ghosttyBuiltFor"), t("rGpu"), t("pMacLinux")],
              ["iTerm2", t("iterm2BuiltFor"), t("rGpuCpu"), t("pMac")],
              ["Warp", t("warpBuiltFor"), t("rGpu"), t("pMacLinuxWin")],
              ["Terminal.app", t("terminalAppBuiltFor"), t("rCpu"), t("pMac")],
              ["Alacritty", t("alacrittyBuiltFor"), t("rGpu"), t("pCross")],
              ["kitty", t("kittyBuiltFor"), t("rGpu"), t("pMacLinux")],
              ["WezTerm", t("weztermBuiltFor"), t("rGpu"), t("pCross")],
              ["tmux", t("tmuxBuiltFor"), t("rNa"), t("pUnix")],
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
              { href: "/agents/claude-code", label: tl("claude") },
              { href: "/docs/getting-started", label: tl("getStarted") },
            ]}
          />
        </div>
      </main>
    </>
  );
}
