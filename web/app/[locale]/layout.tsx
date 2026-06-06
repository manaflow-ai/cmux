import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import Script from "next/script";
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
import { DOWNLOAD_URL } from "../lib/download";
import "../globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const darkThemeColor = "#0a0a0a";
const lightThemeColor = "#fafafa";
const themeColorScript = `(function(){try{var t=localStorage.getItem("theme");if(t!=="light"&&t!=="dark")return;var c=t==="light"?"${lightThemeColor}":"${darkThemeColor}";document.querySelectorAll('meta[name="theme-color"]').forEach(function(m){m.content=c})}catch(e){}})()`;

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

  const dir = locale === "ar" ? "rtl" : "ltr";

  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "cmux",
    operatingSystem: "macOS",
    applicationCategory: "DeveloperApplication",
    url: "https://cmux.com",
    downloadUrl: DOWNLOAD_URL,
    description:
      "Native macOS terminal built on Ghostty. Works with Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, and any CLI tool. Vertical tabs, notification rings, split panes, and a socket API.",
    keywords:
      "terminal, macOS, Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, AI coding agents, Ghostty",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  };
  const jsonLdScript = JSON.stringify(jsonLd).replace(/</g, "\\u003c");

  return (
    <html lang={locale} dir={dir} suppressHydrationWarning>
      <head>
        <meta
          name="theme-color"
          content={lightThemeColor}
          media="(prefers-color-scheme: light)"
        />
        <meta
          name="theme-color"
          content={darkThemeColor}
          media="(prefers-color-scheme: dark)"
        />
        <script type="application/ld+json">{jsonLdScript}</script>
        <Script id="cmux-theme-color" strategy="afterInteractive">
          {themeColorScript}
        </Script>
      </head>
      <body
        className={`${geistSans.variable} ${geistMono.variable} font-sans antialiased`}
      >
        <NextIntlClientProvider messages={messages}>
          <Providers>
            {children}
            <SiteFooter />
            <DevPanel />
          </Providers>
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
