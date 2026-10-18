import { NextIntlClientProvider } from "next-intl";
import { getMessages, getTranslations } from "next-intl/server";
import { sharedClientMessages } from "../i18n/client-messages";
import { SiteFooter } from "./[locale]/components/site-footer";
import { Providers } from "./[locale]/providers";
import { ThemeBootstrapScript } from "./[locale]/theme-bootstrap-script";
import { siteThemeBootstrapScript } from "./[locale]/theme-colors";

/**
 * The page for every unmatched URL. It renders under the root layout only,
 * so it mounts the providers the site footer's client parts read itself.
 */
export default async function NotFound() {
  const messages = sharedClientMessages(await getMessages());
  const t = await getTranslations("dashboard.notFound");

  return (
    <>
      <ThemeBootstrapScript script={siteThemeBootstrapScript} />
      <NextIntlClientProvider messages={messages}>
        <Providers>
          <div className="min-h-screen">
            <main className="flex min-h-[60vh] flex-col items-center justify-center gap-4 px-4 text-center">
              <h1 className="font-mono text-6xl font-semibold tracking-tight">404</h1>
              <p className="text-muted">{t("title")}</p>
            </main>
            <SiteFooter />
          </div>
        </Providers>
      </NextIntlClientProvider>
    </>
  );
}
