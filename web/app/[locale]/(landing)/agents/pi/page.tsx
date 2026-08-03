import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "@/i18n/navigation";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { LandingCTA } from "../../landing-ui";
import { LandingFaq, LandingSchema } from "../../landing-schema";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.pi" });
  const alternates = buildAlternates(locale, "/agents/pi", ["en"]);
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    keywords: [
      "best terminal for Pi",
      "Pi coding agent terminal",
      "terminal for Pi",
      "Pi agent macOS",
    ],
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default function PiPage() {
  const t = useTranslations("landing.pi");
  const tl = useTranslations("landing.links");
  const code = (chunks: React.ReactNode) => <code>{chunks}</code>;
  return (
    <>
      <SiteHeader section="Pi" />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
          <LandingSchema namespace="landing.pi" path="/agents/pi" />
          <h1>{t("title")}</h1>
          <p>{t.rich("intro", { code })}</p>

          <h2>{t("organizeTitle")}</h2>
          <p>{t("organizeBody")}</p>

          <h2>{t("notifyTitle")}</h2>
          <p>{t("notifyBody")}</p>

          <h2>{t("integrationTitle")}</h2>
          <p>
            {t.rich("integrationBody", {
              code,
              link: (chunks) => (
                <Link
                  href="/docs/agent-integrations/oh-my-pi"
                  className="underline underline-offset-2"
                >
                  {chunks}
                </Link>
              ),
            })}
          </p>

          <h2>{t("scriptTitle")}</h2>
          <p>{t("scriptBody")}</p>

          <LandingFaq namespace="landing.pi" />

          <LandingCTA
            related={[
              { href: "/agents", label: tl("agents") },
              { href: "/agents/claude-code", label: tl("claude") },
              { href: "/agents/codex", label: tl("codex") },
              {
                href: "/docs/agent-integrations/oh-my-pi",
                label: "oh-my-pi",
              },
            ]}
          />
        </div>
      </main>
    </>
  );
}
