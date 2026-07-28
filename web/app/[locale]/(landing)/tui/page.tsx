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
          width: 1360,
          height: 842,
          alt: t("screenshotAlt"),
        },
      ],
    },
    twitter: twitterSummary(locale, title, description),
  };
}

const commandClass =
  "rounded-lg border border-white/10 bg-black/35 px-4 py-3 font-mono text-[13px] text-white/90";

export default async function TuiPage() {
  const t = await getTranslations("tui.marketing");

  return (
    <>
      <SiteHeader section={t("sectionLabel")} />
      <main className="overflow-hidden">
        <section className="mx-auto max-w-6xl px-6 pb-16 pt-16 sm:pb-24 sm:pt-24">
          <div className="mx-auto max-w-3xl text-center">
            <p className="mb-5 font-mono text-xs font-medium uppercase tracking-[0.2em] text-muted">
              {t("eyebrow")}
            </p>
            <h1 className="text-balance text-3xl font-semibold tracking-[-0.04em] sm:text-6xl">
              {t("title")}
            </h1>
            <p className="mx-auto mt-6 max-w-2xl text-balance text-lg leading-8 text-muted">
              {t("intro")}
            </p>
            <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
              <a
                href="#install"
                className="rounded-lg bg-foreground px-4 py-2.5 text-sm font-medium text-background transition-opacity hover:opacity-80"
              >
                {t("runButton")}
              </a>
              <Link
                href="/docs/tui"
                className="rounded-lg border border-border px-4 py-2.5 text-sm font-medium transition-colors hover:bg-code-bg"
              >
                {t("docsButton")}
              </Link>
              <a
                href="https://github.com/manaflow-ai/cmux/tree/main/cmux-tui"
                className="px-2 py-2.5 text-sm text-muted transition-colors hover:text-foreground"
              >
                {t("sourceButton")} <span aria-hidden>↗</span>
              </a>
            </div>
          </div>

          <figure className="mt-14 w-full sm:relative sm:left-1/2 sm:mt-20 sm:w-[min(90rem,calc(100vw-2rem))] sm:-translate-x-1/2">
            <div className="rounded-xl border border-border bg-[#282d35] p-1 shadow-2xl shadow-black/15">
              <Image
                src="/tui/cmux-tui-overview.png"
                width={1360}
                height={842}
                priority
                alt={t("screenshotAlt")}
                className="h-auto w-full rounded-lg"
              />
            </div>
            <figcaption className="mt-3 text-center font-mono text-[11px] text-muted">
              {t("screenshotCaption")}
            </figcaption>
          </figure>
        </section>

        <section className="border-y border-border bg-code-bg/50">
          <div className="mx-auto grid max-w-5xl gap-px px-6 py-10 sm:grid-cols-3 sm:py-0">
            {(["platforms", "engine", "license"] as const).map((key) => (
              <div
                key={key}
                className="px-5 py-5 text-center sm:border-x sm:border-border sm:py-8"
              >
                <p className="font-mono text-xs uppercase tracking-[0.16em] text-muted">
                  {t(`facts.${key}.label`)}
                </p>
                <p className="mt-2 text-sm font-medium">
                  {t(`facts.${key}.value`)}
                </p>
              </div>
            ))}
          </div>
        </section>

        <section className="mx-auto max-w-5xl px-6 py-20 sm:py-28">
          <div className="max-w-2xl">
            <p className="font-mono text-xs uppercase tracking-[0.18em] text-muted">
              {t("workflowEyebrow")}
            </p>
            <h2 className="mt-4 text-3xl font-semibold tracking-[-0.03em] sm:text-4xl">
              {t("workflowTitle")}
            </h2>
            <p className="mt-4 text-base leading-7 text-muted">
              {t("workflowBody")}
            </p>
          </div>
          <div className="mt-10 grid gap-4 sm:grid-cols-2">
            {(["tree", "agents", "browser", "remote"] as const).map(
              (feature) => (
                <article
                  key={feature}
                  className="rounded-xl border border-border p-6"
                >
                  <p className="font-mono text-xs text-muted">
                    {t(`features.${feature}.number`)}
                  </p>
                  <h3 className="mt-5 text-lg font-semibold">
                    {t(`features.${feature}.title`)}
                  </h3>
                  <p className="mt-2 text-sm leading-6 text-muted">
                    {t(`features.${feature}.body`)}
                  </p>
                </article>
              ),
            )}
          </div>
        </section>

        <section className="bg-[#20242b] text-white">
          <div className="mx-auto grid max-w-5xl gap-12 px-6 py-20 sm:grid-cols-[1fr_1.15fr] sm:items-center sm:py-28">
            <div>
              <p className="font-mono text-xs uppercase tracking-[0.18em] text-white/50">
                {t("keyboardEyebrow")}
              </p>
              <h2 className="mt-4 text-3xl font-semibold tracking-[-0.03em]">
                {t("keyboardTitle")}
              </h2>
              <p className="mt-4 text-base leading-7 text-white/60">
                {t("keyboardBody")}
              </p>
            </div>
            <div className="grid gap-3">
              {[
                ["Ctrl-b %", t("keys.split")],
                ["Ctrl-b t", t("keys.tab")],
                ["Ctrl-b W", t("keys.workspace")],
                ["Ctrl-b g", t("keys.viewport")],
              ].map(([keys, label]) => (
                <div
                  key={keys}
                  className="flex items-center justify-between gap-6 border-b border-white/10 py-3"
                >
                  <code className="font-mono text-sm text-white">{keys}</code>
                  <span className="text-sm text-white/55">{label}</span>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section
          id="install"
          className="mx-auto max-w-5xl scroll-mt-20 px-6 py-20 sm:py-28"
        >
          <div className="grid gap-10 sm:grid-cols-[1fr_1.1fr] sm:items-start">
            <div>
              <p className="font-mono text-xs uppercase tracking-[0.18em] text-muted">
                {t("installEyebrow")}
              </p>
              <h2 className="mt-4 text-3xl font-semibold tracking-[-0.03em]">
                {t("installTitle")}
              </h2>
              <p className="mt-4 text-base leading-7 text-muted">
                {t("installBody")}
              </p>
            </div>
            <div className="rounded-xl bg-[#20242b] p-3 shadow-xl shadow-black/10">
              <div className={commandClass}>$ npx cmux</div>
              <div className="my-2 px-4 font-mono text-[11px] text-white/35">
                {t("installOr")}
              </div>
              <div className={commandClass}>$ npm install --global cmux</div>
              <div className={`${commandClass} mt-2`}>$ cmux</div>
            </div>
          </div>
          <div className="mt-12 flex flex-wrap items-center gap-4 border-t border-border pt-8 text-sm">
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
