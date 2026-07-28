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
          url: "/tui/cmux-tui-overview.jpeg",
          width: 1225,
          height: 768,
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
        <section>
          <p className="mb-3 text-xs font-medium text-muted">{t("eyebrow")}</p>
          <h1 className="text-2xl font-semibold tracking-tight">
            {t("title")}
          </h1>
          <p className="mt-4 text-base leading-relaxed text-muted">
            {t("intro")}
          </p>
          <div className="mt-6 flex flex-wrap items-center gap-3">
            <a
              href="#install"
              className="rounded-md bg-foreground px-3.5 py-2 text-sm font-medium text-background transition-opacity hover:opacity-80"
            >
              {t("runButton")}
            </a>
            <Link
              href="/docs/tui"
              className="rounded-md border border-border px-3.5 py-2 text-sm font-medium transition-colors hover:bg-code-bg"
            >
              {t("docsButton")}
            </Link>
            <a
              href="https://github.com/manaflow-ai/cmux/tree/main/cmux-tui"
              className="px-1 py-2 text-sm text-muted underline decoration-link-underline underline-offset-4 transition-colors hover:text-foreground"
            >
              {t("sourceButton")} <span aria-hidden>↗</span>
            </a>
          </div>

          <figure className="mt-12 w-full sm:relative sm:left-1/2 sm:w-[min(76rem,calc(100vw-3rem))] sm:-translate-x-1/2">
            <div className="overflow-hidden rounded-lg border border-border bg-code-bg">
              <Image
                src="/tui/cmux-tui-overview.jpeg"
                width={1225}
                height={768}
                priority
                alt={t("screenshotAlt")}
                className="h-auto w-full"
              />
            </div>
            <figcaption className="mt-3 text-center text-xs text-muted">
              {t("screenshotCaption")}
            </figcaption>
          </figure>
        </section>

        <section className="mt-16 grid grid-cols-3 divide-x divide-border border-y border-border">
          {(["platforms", "engine", "license"] as const).map((key) => (
            <div key={key} className="px-3 py-5 first:pl-0 last:pr-0 sm:px-6">
              <p className="text-xs text-muted">{t(`facts.${key}.label`)}</p>
              <p className="mt-1 text-sm font-medium">
                {t(`facts.${key}.value`)}
              </p>
            </div>
          ))}
        </section>

        <section className="pt-16">
          <p className="text-xs font-medium text-muted">
            {t("workflowEyebrow")}
          </p>
          <h2 className="mt-3 text-xl font-semibold tracking-tight">
            {t("workflowTitle")}
          </h2>
          <p className="mt-3 text-[15px] leading-relaxed text-muted">
            {t("workflowBody")}
          </p>
          <ul className="mt-7 space-y-4 text-[15px]">
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

        <section className="pt-16">
          <p className="text-xs font-medium text-muted">
            {t("keyboardEyebrow")}
          </p>
          <h2 className="mt-3 text-xl font-semibold tracking-tight">
            {t("keyboardTitle")}
          </h2>
          <p className="mt-3 text-[15px] leading-relaxed text-muted">
            {t("keyboardBody")}
          </p>
          <div className="mt-6 divide-y divide-border border-y border-border">
            {[
              ["Ctrl-b %", t("keys.split")],
              ["Ctrl-b t", t("keys.tab")],
              ["Ctrl-b W", t("keys.workspace")],
              ["Ctrl-b g", t("keys.viewport")],
            ].map(([keys, label]) => (
              <div
                key={keys}
                className="flex items-center justify-between gap-6 py-3"
              >
                <code className="font-mono text-sm">{keys}</code>
                <span className="text-right text-sm text-muted">{label}</span>
              </div>
            ))}
          </div>
        </section>

        <section id="install" className="scroll-mt-20 pt-16">
          <p className="text-xs font-medium text-muted">
            {t("installEyebrow")}
          </p>
          <h2 className="mt-3 text-xl font-semibold tracking-tight">
            {t("installTitle")}
          </h2>
          <p className="mt-3 text-[15px] leading-relaxed text-muted">
            {t("installBody")}
          </p>
          <div className="mt-6 rounded-lg border border-border bg-code-bg p-4 font-mono text-[13px] leading-7">
            <div>$ npx cmux</div>
            <div className="my-1 text-xs text-muted">{t("installOr")}</div>
            <div>$ npm install --global cmux</div>
            <div>$ cmux</div>
          </div>
          <div className="mt-8 flex flex-wrap items-center gap-4 border-t border-border pt-6 text-sm">
            <Link
              href="/docs/tui"
              className="font-medium underline decoration-link-underline underline-offset-4"
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
        </section>
      </main>
    </>
  );
}
