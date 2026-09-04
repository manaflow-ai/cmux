import { getLocale, getTranslations } from "next-intl/server";
import Image from "next/image";
import type { Metadata } from "next";
import { routing, type Locale } from "@/i18n/routing";
import { ThemeBootstrapScript } from "./[locale]/theme-bootstrap-script";
import { NotFoundDownloadLink } from "./[locale]/components/not-found-download-link";
import { NotFoundLink } from "./[locale]/components/not-found-link";

const themeBootstrapScript = `(function(){try{var t=localStorage.getItem("theme");var light=t==="light"||(t==="system"&&window.matchMedia("(prefers-color-scheme:light)").matches);if(!light)document.documentElement.classList.add("dark")}catch(e){}})()`;

export const metadata: Metadata = {
  title: "Page not found | cmux",
  description: "The requested cmux page could not be found.",
};

function localizedHref(locale: Locale, path: string) {
  return locale === routing.defaultLocale ? path : `/${locale}${path}`;
}

export default async function NotFound() {
  const locale = (await getLocale()) as Locale;
  const t = await getTranslations("notFoundPage");
  const homeHref = localizedHref(locale, "/");
  const docsHref = localizedHref(locale, "/docs/getting-started");
  const supportHref = localizedHref(locale, "/support");

  return (
    <>
      <ThemeBootstrapScript script={themeBootstrapScript} />
      <main className="relative flex min-h-screen overflow-hidden px-6 py-8 sm:px-10 sm:py-10">
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 opacity-60 dark:opacity-30"
          style={{
            backgroundImage:
              "radial-gradient(circle at 76% 38%, color-mix(in srgb, var(--cmux-product-blue) 12%, transparent), transparent 24rem)",
          }}
        />

        <div className="relative mx-auto flex w-full max-w-5xl flex-col">
          <header className="flex items-center justify-between">
            <a
              href={homeHref}
              className="flex items-center gap-2.5 rounded-lg focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground"
            >
              <Image
                src="/logo.png"
                alt=""
                width={28}
                height={28}
                className="rounded-lg"
                priority
              />
              <span className="text-sm font-semibold tracking-tight">cmux</span>
            </a>
            <span className="font-mono text-xs text-muted">404</span>
          </header>

          <section className="my-auto grid items-center gap-12 py-16 lg:grid-cols-[minmax(0,1fr)_minmax(22rem,0.88fr)] lg:gap-16">
            <div>
              <p className="mb-5 font-mono text-xs font-medium uppercase tracking-[0.18em] text-[var(--cmux-product-blue-on-background)]">
                {t("eyebrow")}
              </p>
              <h1 className="max-w-xl text-balance text-4xl font-semibold tracking-[-0.04em] sm:text-5xl sm:leading-[1.08]">
                {t("title")}
              </h1>
              <p className="mt-5 max-w-md text-pretty text-base leading-7 text-muted sm:text-lg">
                {t("description")}
              </p>

              <div className="mt-8 flex flex-wrap gap-3">
                <NotFoundDownloadLink className="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-foreground px-5 text-sm font-medium text-background transition-opacity hover:opacity-85 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground">
                  {t("downloadAction")}
                  <DownloadIcon />
                </NotFoundDownloadLink>
                <NotFoundLink
                  href={homeHref}
                  action="home"
                  className="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-foreground px-5 text-sm font-medium text-background transition-opacity hover:opacity-85 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground"
                >
                  {t("homeAction")}
                  <ArrowIcon />
                </NotFoundLink>
                <NotFoundLink
                  href={docsHref}
                  action="docs"
                  className="inline-flex min-h-11 items-center justify-center rounded-lg border border-border bg-background px-5 text-sm font-medium transition-colors hover:bg-code-bg focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground"
                >
                  {t("docsAction")}
                </NotFoundLink>
              </div>
            </div>

            <div
              aria-hidden="true"
              className="overflow-hidden rounded-xl border border-border bg-background shadow-2xl shadow-black/5 dark:shadow-black/30"
            >
              <div className="flex h-11 items-center gap-2 border-b border-border px-4">
                <span className="h-2.5 w-2.5 rounded-full bg-border" />
                <span className="h-2.5 w-2.5 rounded-full bg-border" />
                <span className="h-2.5 w-2.5 rounded-full bg-border" />
                <span className="ml-2 font-mono text-[11px] text-muted">
                  {t("terminalTitle")}
                </span>
              </div>
              <div className="min-h-56 p-5 font-mono text-[13px] leading-7 sm:p-6 sm:text-sm">
                <p>
                  <span className="text-[var(--cmux-product-blue-on-background)]">
                    ~
                  </span>{" "}
                  <span className="text-muted">$</span> {t("terminalCommand")}
                </p>
                <p className="text-muted">{t("terminalError")}</p>
                <p className="text-muted">{t("terminalHint")}</p>
                <p className="mt-5 flex items-center gap-2">
                  <span className="text-[var(--cmux-product-blue-on-background)]">
                    ~
                  </span>{" "}
                  <span className="text-muted">$</span>
                  <span className="animate-blink inline-block h-4 w-1.5 bg-foreground" />
                </p>
              </div>
            </div>
          </section>

          <footer className="flex items-center justify-between border-t border-border pt-5 text-xs text-muted">
            <span>{t("footer")}</span>
            <NotFoundLink
              href={supportHref}
              action="support"
              className="underline decoration-link-underline underline-offset-4 transition-colors hover:text-foreground hover:decoration-foreground focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground"
            >
              {t("supportAction")}
            </NotFoundLink>
          </footer>
        </div>
      </main>
    </>
  );
}

function ArrowIcon() {
  return (
    <svg
      width="15"
      height="15"
      viewBox="0 0 15 15"
      fill="none"
      aria-hidden="true"
    >
      <path
        d="M3.25 7.5h8.5m-3.5-3.5 3.5 3.5-3.5 3.5"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg
      width="15"
      height="15"
      viewBox="0 0 15 15"
      fill="none"
      aria-hidden="true"
    >
      <path
        d="M7.5 2.5v6m0 0 2.5-2.5M7.5 8.5 5 6M3 11.5h9"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
