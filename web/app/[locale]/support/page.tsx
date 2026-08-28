import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "../../../i18n/seo";
import { Link } from "../../../i18n/navigation";
import { SiteHeader } from "../components/site-header";
import { SupportContactForm } from "./support-contact-form";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "support" });
  const alternates = buildAlternates(locale, "/support");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
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

const channels = [
  { key: "docs", href: "/docs/getting-started", internal: true },
  { key: "discord", href: "https://discord.gg/xsgFEVrWCZ", internal: false },
  {
    key: "github",
    href: "https://github.com/manaflow-ai/cmux/issues",
    internal: false,
  },
  { key: "email", href: "mailto:founders@manaflow.com", internal: false },
] as const;

export default function SupportPage() {
  const t = useTranslations("support");

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="mx-auto grid w-full max-w-6xl gap-10 px-6 py-16 sm:py-20 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <section>
          <p className="mb-3 text-sm font-medium text-muted">{t("section")}</p>
          <h1 className="max-w-xl text-3xl font-medium tracking-tight">
            {t("title")}
          </h1>
          <p className="mt-5 max-w-xl text-[15px] leading-relaxed text-muted">
            {t("body")}
          </p>
          <ul className="mt-8 grid gap-3 text-[15px] text-muted">
            {channels.map((channel) => (
              <li key={channel.key} className="border-l border-border pl-4">
                {channel.internal ? (
                  <Link
                    href={channel.href}
                    className="font-medium text-foreground transition-colors hover:text-muted"
                  >
                    {t(`channels.${channel.key}.label`)}
                  </Link>
                ) : (
                  <a
                    href={channel.href}
                    target={channel.href.startsWith("http") ? "_blank" : undefined}
                    rel={
                      channel.href.startsWith("http")
                        ? "noopener noreferrer"
                        : undefined
                    }
                    className="font-medium text-foreground transition-colors hover:text-muted"
                  >
                    {t(`channels.${channel.key}.label`)}
                  </a>
                )}
                <span className="block">
                  {t(`channels.${channel.key}.description`)}
                </span>
              </li>
            ))}
          </ul>
        </section>

        <section
          aria-label={t("formAriaLabel")}
          className="border border-border p-5 sm:p-6"
        >
          <SupportContactForm />
        </section>
      </main>
    </div>
  );
}
