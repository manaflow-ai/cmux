import type { Metadata } from "next";
import { NextIntlClientProvider } from "next-intl";
import {
  getMessages,
  getTranslations,
  setRequestLocale,
} from "next-intl/server";
import { notFound } from "next/navigation";
import { routing } from "../../i18n/routing";
import { buildAlternates } from "../../i18n/seo";
import { Providers } from "./providers";
import { DevPanel } from "./components/spacing-control";
import { SiteFooter } from "./components/site-footer";
import { ThemeBootstrapScript } from "./theme-bootstrap-script";
import { darkThemeColor, lightThemeColor } from "./theme-colors";
import { DOWNLOAD_URL } from "../lib/download";

const themeBootstrapScript = `(function(){try{var t=localStorage.getItem("theme");var light=t==="light"||(t==="system"&&window.matchMedia("(prefers-color-scheme:light)").matches);if(!light)document.documentElement.classList.add("dark");document.querySelectorAll('meta[name="theme-color"]').forEach(function(m){m.content=light?"${lightThemeColor}":"${darkThemeColor}"})}catch(e){}})()`;

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, "");
  return {
    title: t("title"),
    description: t("description"),
    keywords: [
      "terminal",
      "macOS",
      "coding agents",
      "Claude Code",
      "Codex",
      "OpenCode",
      "Gemini CLI",
      "Kiro",
      "Aider",
      "Ghostty",
      "AI",
      "terminal for AI agents",
    ],
    openGraph: {
      title: t("title"),
      description: t("ogDescription"),
      url: alternates.canonical,
      siteName: "cmux",
      type: "website",
    },
    twitter: {
      card: "summary_large_image",
      title: t("title"),
      description: t("ogDescription"),
    },
    alternates,
    metadataBase: new URL("https://cmux.com"),
  };
}

export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }));
}

export default async function LocaleLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;

  if (!routing.locales.includes(locale as typeof routing.locales[number])) {
    notFound();
  }

  setRequestLocale(locale);

  const messages = await getMessages();

  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "cmux",
    operatingSystem: "macOS",
    applicationCategory: "DeveloperApplication",
    url: "https://cmux.com",
    downloadUrl: DOWNLOAD_URL,
    description:
      "Free and open source native macOS terminal built on Ghostty. Works with Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, and any CLI tool. Vertical tabs, notification rings, split panes, and a socket API.",
    keywords:
      "terminal, macOS, open source terminal, Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, AI coding agents, Ghostty",
    isAccessibleForFree: true,
    license: "https://github.com/manaflow-ai/cmux/blob/main/LICENSE",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  };
  const jsonLdScript = JSON.stringify(jsonLd).replace(/</g, "\\u003c");

  return (
    <>
      <meta name="theme-color" content={darkThemeColor} />
      <script type="application/ld+json">{jsonLdScript}</script>
      <ThemeBootstrapScript script={themeBootstrapScript} />
      <NextIntlClientProvider messages={messages}>
        <Providers>
          {children}
          <SiteFooter />
          <DevPanel />
        </Providers>
      </NextIntlClientProvider>
    </>
  );
}
