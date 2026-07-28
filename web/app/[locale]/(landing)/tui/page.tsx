import Image from "next/image";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { Link } from "@/i18n/navigation";
import { SiteHeader } from "@/app/[locale]/components/site-header";

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
          width: 4608,
          height: 2538,
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
          <p className="mt-4 text-lg leading-relaxed">{t("workflowTitle")}</p>
          <p className="mt-2 text-base leading-relaxed text-muted">{t("intro")}</p>
          <div className="mt-5 flex flex-wrap items-center gap-3">
            <a
              href="#install"
              className="rounded-full bg-foreground px-5 py-2.5 text-[15px] font-medium text-background transition-opacity hover:opacity-80"
            >
              {t("runButton")}
            </a>
            <Link
              href="/docs/tui"
              className="rounded-full border border-border px-5 py-2.5 text-[15px] font-medium transition-colors hover:bg-code-bg"
            >
              {t("docsButton")}
            </Link>
            <a
              href="https://github.com/manaflow-ai/cmux/tree/main/cmux-tui"
              className="px-1 py-2 text-[15px] text-muted underline decoration-link-underline underline-offset-4 transition-colors hover:text-foreground"
            >
              {t("sourceButton")} <span aria-hidden>↗</span>
            </a>
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
            width={4608}
            height={2538}
            priority
            quality={85}
            sizes="(min-width: 1440px) 1440px, calc(100vw - 3rem)"
            alt={t("screenshotAlt")}
            className="h-auto w-full [filter:drop-shadow(0_24px_44px_rgba(0,0,0,0.45))]"
          />
          <figcaption className="mt-3 text-center text-xs text-muted">
            {t("screenshotCaption")}
          </figcaption>
        </figure>

        <section id="install" className="mb-10 scroll-mt-20">
          <h2 className="mb-3 text-xs font-medium tracking-tight text-muted">
            {t("installEyebrow")}
          </h2>
          <p className="mb-1 font-medium">{t("installTitle")}</p>
          <p className="text-[15px] leading-relaxed text-muted">
            {t("installBody")}
          </p>
          <pre className="mt-4 overflow-x-auto rounded-lg bg-code-bg px-4 py-3 font-mono text-[13px] leading-7">
            <code>{`$ npx cmux

${t("installOr")}
$ npm install --global cmux
$ cmux`}</code>
          </pre>
        </section>

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
