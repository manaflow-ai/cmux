import { getLocale, getTranslations } from "next-intl/server";
import Image from "next/image";
import type { Metadata } from "next";
import { routing, type Locale } from "@/i18n/routing";
import { ThemeBootstrapScript } from "./[locale]/theme-bootstrap-script";
import { NotFoundDownloadLink } from "./[locale]/components/not-found-download-link";
import { NotFoundAnalytics } from "./[locale]/components/not-found-analytics";
import { NotFoundLink } from "./[locale]/components/not-found-link";
import { NotFoundTerminal } from "./[locale]/components/not-found-terminal";

const themeBootstrapScript = `(function(){try{var t=localStorage.getItem("theme");var light=t==="light"||(t==="system"&&window.matchMedia("(prefers-color-scheme:light)").matches);if(!light)document.documentElement.classList.add("dark")}catch(e){}})()`;

export async function generateMetadata(): Promise<Metadata> {
  const locale = await getLocale();
  const t = await getTranslations({ locale, namespace: "notFoundPage" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
  };
}

function localizedHref(locale: Locale, path: string) {
  return locale === routing.defaultLocale ? path : `/${locale}${path}`;
}

export default async function NotFound() {
  const locale = (await getLocale()) as Locale;
  const t = await getTranslations("notFoundPage");
  const homeHref = localizedHref(locale, "/");
  const docsHref = localizedHref(locale, "/docs/getting-started");

  return (
    <>
      <ThemeBootstrapScript script={themeBootstrapScript} />
      <NotFoundAnalytics locale={locale} />
      <main className="min-h-screen px-4 py-5 sm:px-8 sm:py-8">
        <div className="mx-auto flex w-full max-w-[72rem] flex-col">
          <header className="flex items-center justify-between">
            <a
              href={homeHref}
              className="flex items-center gap-2 rounded-md focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground"
            >
              <Image
                src="/logo.png"
                alt=""
                width={24}
                height={24}
                className="rounded-md"
                priority
              />
              <span className="text-sm font-medium tracking-tight">cmux</span>
            </a>
            <span className="font-mono text-xs text-muted">404</span>
          </header>

          <section className="py-12 sm:py-16">
            <h1 className="sr-only">{t("title")}</h1>
            <NotFoundTerminal
              title={t("terminalTitle")}
              command={t("terminalCommand")}
              welcome={t("terminalWelcome")}
              docsLabel={t("terminalDocs")}
              docsHref={docsHref}
            />

            <div className="mt-7 flex justify-center gap-3">
              <NotFoundDownloadLink className="inline-flex min-h-10 items-center justify-center gap-2 rounded-md bg-foreground px-4 text-sm font-medium text-background transition-opacity hover:opacity-85 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground">
                {t("downloadAction")}
                <DownloadIcon />
              </NotFoundDownloadLink>
              <NotFoundLink
                href={docsHref}
                action="docs"
                className="inline-flex min-h-10 items-center justify-center rounded-md border border-border px-4 text-sm font-medium transition-colors hover:bg-code-bg focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground"
              >
                {t("docsAction")}
              </NotFoundLink>
            </div>
          </section>
        </div>
      </main>
    </>
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
