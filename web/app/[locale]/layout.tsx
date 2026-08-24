import type { Metadata } from "next";
import { NextIntlClientProvider } from "next-intl";
import {
  getMessages,
  getTranslations,
  setRequestLocale,
} from "next-intl/server";
import { notFound } from "next/navigation";
import { routing } from "../../i18n/routing";
import {
  buildAlternates,
  defaultOpenGraphImage,
  openGraphDefaults,
  twitterSummary,
} from "../../i18n/seo";
import { homeSeoCopy } from "../../i18n/audited-seo";
import { Providers } from "./providers";
import { DevPanel } from "./components/spacing-control";
import { ThemeBootstrapScript } from "./theme-bootstrap-script";
import { darkThemeColor, lightThemeColor } from "./theme-colors";

const themeBootstrapScript = `(function(){try{var t=localStorage.getItem("theme");var light=t==="light"||(t==="system"&&window.matchMedia("(prefers-color-scheme:light)").matches);if(!light)document.documentElement.classList.add("dark");document.querySelectorAll('meta[name="theme-color"]').forEach(function(m){m.content=light?"${lightThemeColor}":"${darkThemeColor}"})}catch(e){}})()`;

type MessageTree = Record<string, unknown>;

function isMessageTree(value: unknown): value is MessageTree {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

function pruneClientMessages(messages: MessageTree): MessageTree {
  const pruned: MessageTree = { ...messages };
  const landing = isMessageTree(messages.landing)
    ? { ...messages.landing }
    : undefined;
  if (landing && isMessageTree(landing.compare)) {
    const compare = { ...landing.compare };
    delete compare.pages;
    landing.compare = compare;
    pruned.landing = landing;
  }

  const blog = isMessageTree(messages.blog) ? { ...messages.blog } : undefined;
  if (blog && isMessageTree(blog.posts)) {
    blog.posts = Object.fromEntries(
      Object.entries(blog.posts).map(([key, value]) => {
        if (!isMessageTree(value)) {
          return [key, value];
        }
        const { title, date, summary } = value;
        return [key, { title, date, summary }];
      }),
    );
    pruned.blog = blog;
  }

  return pruned;
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, "");
  const { title, description } = homeSeoCopy(locale, t);
  return {
    title,
    description,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
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

  const messages = pruneClientMessages(await getMessages());
  const t = await getTranslations({ locale, namespace: "meta" });
  const { description: webSiteDescription } = homeSeoCopy(locale, t);

  const organizationJsonLd = {
    "@context": "https://schema.org",
    "@type": "Organization",
    name: "cmux",
    url: "https://cmux.com",
    logo: "https://cmux.com/logo.png",
    sameAs: [
      "https://github.com/manaflow-ai/cmux",
      "https://twitter.com/manaflowai",
    ],
  };
  const webSiteJsonLd = {
    "@context": "https://schema.org",
    "@type": "WebSite",
    name: "cmux",
    url: "https://cmux.com",
    description: webSiteDescription,
    publisher: {
      "@type": "Organization",
      name: "cmux",
      url: "https://cmux.com",
      logo: "https://cmux.com/logo.png",
    },
    image: defaultOpenGraphImage.url,
  };
  const organizationJsonLdScript = JSON.stringify(organizationJsonLd).replace(
    /</g,
    "\\u003c",
  );
  const webSiteJsonLdScript = JSON.stringify(webSiteJsonLd).replace(
    /</g,
    "\\u003c",
  );

  return (
    <>
      <meta name="theme-color" content={darkThemeColor} />
      <script type="application/ld+json">{organizationJsonLdScript}</script>
      <script type="application/ld+json">{webSiteJsonLdScript}</script>
      <ThemeBootstrapScript script={themeBootstrapScript} />
      <NextIntlClientProvider messages={messages}>
        <Providers>
          {children}
          <DevPanel />
        </Providers>
      </NextIntlClientProvider>
    </>
  );
}
