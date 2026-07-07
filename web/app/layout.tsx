import { Geist, Geist_Mono } from "next/font/google";
import { headers } from "next/headers";
import { routing, type Locale } from "../i18n/routing";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const nextIntlLocaleHeader = "x-next-intl-locale";

function localeFromHeader(value: string | null): Locale {
  return routing.locales.includes(value as Locale)
    ? (value as Locale)
    : routing.defaultLocale;
}

function directionForLocale(locale: Locale): "ltr" | "rtl" {
  return locale === "ar" ? "rtl" : "ltr";
}

export default async function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const locale = localeFromHeader((await headers()).get(nextIntlLocaleHeader));
  const dir = directionForLocale(locale);

  return (
    <html lang={locale} dir={dir} suppressHydrationWarning>
      <body
        className={`${geistSans.variable} ${geistMono.variable} font-sans antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
