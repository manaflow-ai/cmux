import { createTranslator } from "next-intl";
import { headers } from "next/headers";
import { preferredLocaleFromAcceptLanguage } from "../../../../i18n/accept-language";
import { loadMessages } from "../../../../i18n/messages";
import DesktopFrame from "./desktop-frame";

// The cmux-owned face of a machine's screen. The pane's address bar shows
// this URL (`cmux_token` in the fragment on our origin — the token never
// reaches this server); the gateway's own token parameter exists only inside
// the iframe src. The fragment is browser-only, so the session is parsed and
// the frame mounted by the client component; this server shell resolves the
// machine name and the localized invalid/expired copy. Legacy wrapper URLs
// (token in the query string) still work and are scrubbed into the fragment
// form client-side. When the token lapses, the overlay says so and points at
// the fix instead of leaving a silent white canvas.
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
