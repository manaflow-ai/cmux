import { NextIntlClientProvider } from "next-intl";
import { getLocale, getMessages, getTranslations } from "next-intl/server";
import Image from "next/image";
import type { Metadata } from "next";
import { routing, type Locale } from "@/i18n/routing";
import { ThemeBootstrapScript } from "./[locale]/theme-bootstrap-script";
import { DownloadButton } from "./[locale]/components/download-button";
import { NotFoundAnalytics } from "./[locale]/components/not-found-analytics";
import { NotFoundLink } from "./[locale]/components/not-found-link";
import { NotFoundTerminal } from "./[locale]/components/not-found-terminal";

const themeBootstrapScript = `(function(){try{var t=localStorage.getItem("theme");var light=t==="light"||(t==="system"&&window.matchMedia("(prefers-color-scheme:light)").matches);if(!light)document.documentElement.classList.add("dark")}catch(e){}})()`;

/** Builds a locale-prefixed path using the site's as-needed locale policy. */
function localizedHref(locale: Locale, path: string) {
  return locale === routing.defaultLocale ? path : `/${locale}${path}`;
}

/** Supplies metadata for the root Next.js not-found boundary. */
export async function generateMetadata(): Promise<Metadata> {
  const locale = await getLocale();
  const t = await getTranslations({ locale, namespace: "notFoundPage" });
  return { title: t("metaTitle"), description: t("metaDescription") };
}

/** Renders the reference 404 surface with locale-aware recovery actions. */
export default async function NotFound() {
  const locale = (await getLocale()) as Locale;
  const t = await getTranslations("notFoundPage");
  const messages = await getMessages({ locale });
  const homeHref = localizedHref(locale, "/");
  const docsHref = localizedHref(locale, "/docs/getting-started");
  const supportHref = localizedHref(locale, "/support");

  return (
    <>
      <ThemeBootstrapScript script={themeBootstrapScript} />
      <NotFoundAnalytics locale={locale} />
      <main className="relative isolate flex min-h-screen overflow-x-clip px-[clamp(1rem,6.3vw,7rem)] py-5 sm:py-8">
        <div className="mx-auto flex w-full max-w-none flex-1 flex-col">
          <header className="relative z-30 flex items-center justify-between">
            <NotFoundLink href={homeHref} action="home" className="flex items-center gap-2 rounded-md focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground">
              <Image src="/logo.png" alt="" width={24} height={24} className="rounded-md" priority />
              <span className="text-sm font-medium tracking-tight">cmux</span>
            </NotFoundLink>
          </header>

          <section className="flex-1 py-12 sm:py-16">
            <div className="relative z-30 mb-10 text-center sm:mb-12">
              <h1 className="font-mono text-[clamp(5.5rem,13vw,10rem)] font-semibold leading-[0.8] tracking-[-0.09em] text-foreground">404</h1>
              <p className="mt-5 text-sm text-muted sm:text-base">{t("title")}</p>
            </div>

            <NotFoundTerminal command={t("terminalCommand")} welcome={t("terminalWelcome")} lastLogin={t("terminalLastLogin")} dragLabel={t("terminalDragLabel")} />

            <div className="relative z-30 mt-7 flex justify-center gap-3">
              <NextIntlClientProvider locale={locale} messages={{ common: messages.common, platforms: messages.platforms, browserDownloads: messages.browserDownloads, footer: messages.footer, waitlist: messages.waitlist }}>
                <DownloadButton location="not_found" directDownload />
              </NextIntlClientProvider>
              <NotFoundLink href={docsHref} action="docs" className="inline-flex min-h-10 items-center justify-center px-2 text-sm text-muted underline decoration-transparent underline-offset-4 transition-colors hover:text-foreground hover:decoration-current focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground">{t("docsAction")}</NotFoundLink>
            </div>
          </section>

          <footer className="relative z-30 flex items-center justify-between py-3 text-xs text-muted">
            <span>{t("footer")}</span>
            <NotFoundLink href={supportHref} action="support" className="underline decoration-transparent underline-offset-4 transition-colors hover:text-foreground hover:decoration-current focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground">{t("supportAction")}</NotFoundLink>
          </footer>
        </div>
      </main>
    </>
  );
}
