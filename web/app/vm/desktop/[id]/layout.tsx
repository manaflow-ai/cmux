import { headers } from "next/headers";
import { preferredLocaleFromAcceptLanguage } from "../../../../i18n/accept-language";

// The desktop wrapper lives outside the [locale] tree (like /billing) so the
// URL a person keeps in a pane never gets rewritten by next-intl; it carries
// its own html/body per the out-of-locale layout requirement, negotiating the
// document language from Accept-Language since no locale segment exists here.
export default async function VmDesktopLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const acceptLanguage = (await headers()).get("accept-language") ?? "";
  const locale = preferredLocaleFromAcceptLanguage(acceptLanguage);
  return (
    <html lang={locale} suppressHydrationWarning>
      <body style={{ margin: 0, background: "#101418" }}>{children}</body>
    </html>
  );
}
