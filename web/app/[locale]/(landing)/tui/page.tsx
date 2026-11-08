import Image from "next/image";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { Link } from "@/i18n/navigation";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { TuiInstallTabs } from "./install-tabs";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "tui.marketing" });
  const alternates = buildAlternates(locale, "/tui");
  const title = t("metaTitle");
  const description = t("metaDescription");

  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
      images: [
        {
          url: "/tui/cmux-tui-overview.png",
          width: 5120,
          height: 2820,
          alt: t("screenshotAlt"),
        },
      ],
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function TuiPage() {
  const t = await getTranslations("tui.marketing");

  return (
    <>
      <SiteHeader section={t("sectionLabel")} />
      <main className="mx-auto w-full max-w-2xl overflow-visible px-6 py-16 sm:py-24">
        <section className="mb-3">
          <h1 className="text-2xl font-semibold tracking-tight">
            {t("title")}
          </h1>
          <p className="mt-4 text-base leading-relaxed text-muted">{t("intro")}</p>
          <div id="install" className="scroll-mt-20">
            <TuiInstallTabs
              unixLabel={t("installTabs.unix")}
              windowsLabel={t("installTabs.windows")}
              tabListLabel={t("installTabs.label")}
              viewScriptLabel={t("installTabs.viewScript")}
              copyLabel={t("installTabs.copy")}
              copiedLabel={t("installTabs.copied")}
            />
          </div>
        </section>

        <section className="py-3">
          <h2 className="mb-3 text-xs font-medium tracking-tight text-muted">
            {t("workflowEyebrow")}
          </h2>
          <ul className="space-y-3 text-[15px] leading-[1.275]">
            {(["tree", "agents", "browser", "remote"] as const).map(
              (feature) => (
                <li key={feature} className="flex gap-3">
                  <span className="shrink-0 text-muted">-</span>
                  <span>
                    <strong className="font-medium">
                      {t(`features.${feature}.title`)}
                    </strong>{" "}
                    <span className="text-muted">
                      {t(`features.${feature}.body`)}
                    </span>
                  </span>
                </li>
              ),
            )}
          </ul>
        </section>

        <figure className="relative left-1/2 mb-12 mt-12 w-[min(90rem,100vw_-_3rem)] -translate-x-1/2">
          <Image
            src="/tui/cmux-tui-overview.png"
            width={5120}
            height={2820}
            priority
            sizes="(min-width: 1440px) 1440px, calc(100vw - 3rem)"
            alt={t("screenshotAlt")}
            className="h-auto w-full [filter:drop-shadow(0_24px_44px_rgba(0,0,0,0.45))]"
          />
          <figcaption className="mt-3 text-center text-xs text-muted">
            {t("screenshotCaption")}
          </figcaption>
        </figure>

        <section className="mb-10">
          <h2 className="mb-3 text-xs font-medium tracking-tight text-muted">
            {t("keyboardEyebrow")}
          </h2>
          <p className="mb-1 font-medium">{t("keyboardTitle")}</p>
          <p className="text-[15px] leading-relaxed text-muted">
            {t("keyboardBody")}
          </p>
          <ul className="mt-4 space-y-3 text-[15px]">
            {[
              ["Ctrl-b %", t("keys.split")],
              ["Ctrl-b t", t("keys.tab")],
              ["Ctrl-b W", t("keys.workspace")],
              ["Ctrl-b g", t("keys.viewport")],
            ].map(([keys, label]) => (
              <li key={keys} className="flex gap-3">
                <code className="w-24 shrink-0 font-mono text-sm">{keys}</code>
                <span className="text-muted">{label}</span>
              </li>
            ))}
          </ul>
        </section>

        <div className="flex flex-wrap items-center gap-4 text-[15px]">
          <Link
            href="/docs/tui"
            className="underline decoration-link-underline underline-offset-4"
          >
            {t("fullDocs")} <span aria-hidden>→</span>
          </Link>
          <a
            href="https://github.com/manaflow-ai/cmux/tree/main/cmux-tui"
            className="text-muted underline decoration-link-underline underline-offset-4"
          >
            {t("browseSource")} <span aria-hidden>↗</span>
          </a>
        </div>
      </main>
    </>
  );
}
