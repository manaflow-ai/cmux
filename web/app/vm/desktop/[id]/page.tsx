import { createTranslator } from "next-intl";
import { headers } from "next/headers";
import { preferredLocaleFromAcceptLanguage } from "../../../../i18n/accept-language";
import { loadMessages } from "../../../../i18n/messages";
import DesktopFrame from "./desktop-frame";

// The browser reads the fragment and navigates top-level so gateway cookies
// remain first-party. Credentials never reach this server in new wrapper URLs.
export const instant = false;
export const metadata = { referrer: "no-referrer" };

export default async function VmDesktopPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { id } = await params;
  const query = await searchParams;
  const machine = decodeURIComponent(id);

  const acceptLanguage = (await headers()).get("accept-language") ?? "";
  const locale = preferredLocaleFromAcceptLanguage(acceptLanguage);
  // Messages load at runtime, so createTranslator cannot type the ICU
  // parameters; the narrow cast keeps the call sites honest.
  const t = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmDesktop",
  }) as unknown as (key: string, values?: Record<string, string | number>) => string;

  return (
    <DesktopFrame
      machine={machine}
      legacyQuery={query}
      strings={{
        invalidTitle: t("invalidTitle"),
        invalidBody: t("invalidBody", { machine }),
        expiredTitle: t("expiredTitle"),
        expiredBody: t("expiredBody", { machine }),
      }}
    />
  );
}
