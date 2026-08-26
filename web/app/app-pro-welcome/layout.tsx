import type { Metadata, Viewport } from "next";
import { getLocale } from "./locale";

import { loadMessages } from "../../i18n/messages";
import { routing, type Locale } from "../../i18n/routing";

type AppProWelcomeMetadataMessages = {
  title: string;
  body: string;
};

export async function generateMetadata(): Promise<Metadata> {
  const locale = supportedLocale(await getLocale());
  const catalog = await loadMessages(locale) as {
    appProWelcome: AppProWelcomeMetadataMessages;
  };
  return {
    title: catalog.appProWelcome.title,
    description: catalog.appProWelcome.body,
  };
}

export const viewport: Viewport = {
  themeColor: "transparent",
};

export default function AppProWelcomeLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      <style>{`
        :root {
          --background: transparent;
          --foreground: #171717;
          --muted: #5f6368;
          --border: rgba(0, 0, 0, 0.14);
          --code-bg: rgba(245, 245, 245, 0.78);
          --button-foreground: #ffffff;
        }
        html, body { background: transparent !important; }
      `}</style>
      {children}
    </>
  );
}

function supportedLocale(locale: string): Locale {
  return routing.locales.find((candidate) => candidate === locale)
    ?? routing.defaultLocale;
}
