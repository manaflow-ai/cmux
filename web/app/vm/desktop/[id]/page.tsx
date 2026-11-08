import { createTranslator } from "next-intl";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { desktopUpstreamUrl } from "../../../../services/vms/desktopWrapper";
import { preferredLocaleFromAcceptLanguage } from "../../../../i18n/accept-language";
import { loadMessages } from "../../../../i18n/messages";

// The cmux-owned face of a machine's screen. `openUrl` (what the pane is
// handed, what a person keeps) is this route with `cmux_token` on our origin.
// It validates the upstream host and token, refuses lapsed tokens with an
// honest screen, and otherwise sends the pane top-level to the noVNC page.
// Top-level, not an iframe: the gateway sets its `bl_preview_token` cookie on
// the tokened request and every asset and the websockify upgrade need it, and
// WebKit blocks third-party cookies inside a cross-site frame.
// The redirect target depends on the request (token, host, expiry), so this route is
// never prerendered or instant-navigated; say so instead of tripping the guard.
export const instant = false;

export default async function VmDesktopPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  // The expiry check reads the clock; opt this render out of prerendering
  // explicitly instead of tripping Next's unstable-value guard.
  await connection();
  const { id } = await params;
  const query = await searchParams;
  const token = typeof query.cmux_token === "string" ? query.cmux_token : "";
  const host = typeof query.host === "string" ? query.host : "";
  const expiresAtMs = typeof query.exp === "string" ? Number.parseInt(query.exp, 10) : NaN;
  const upstream = desktopUpstreamUrl({ host, token, params: query });
  const machine = decodeURIComponent(id);
  const expired = Number.isFinite(expiresAtMs) && Date.now() > expiresAtMs;

  if (upstream && !expired) {
    redirect(upstream);
  }

  const acceptLanguage = (await headers()).get("accept-language") ?? "";
  const locale = preferredLocaleFromAcceptLanguage(acceptLanguage);
  // Messages load at runtime, so createTranslator cannot type the ICU
  // parameters; the narrow cast keeps the call sites honest.
  const t = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "vmDesktop",
  }) as unknown as (key: string, values?: Record<string, string | number>) => string;

  const shell: React.CSSProperties = {
    margin: 0,
    height: "100vh",
    background: "#101418",
    color: "#dbe5ea",
    fontFamily: "-apple-system, 'Segoe UI', sans-serif",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    textAlign: "center",
  };
  const titleKey = upstream ? "expiredTitle" : "invalidTitle";
  const bodyKey = upstream ? "expiredBody" : "invalidBody";

  return (
    <main style={shell}>
      <title>{`${machine} — desktop`}</title>
      <div style={{ maxWidth: 440, padding: 24 }}>
        <h1 style={{ fontSize: 18, margin: "0 0 8px" }}>{t(titleKey)}</h1>
        <p style={{ margin: 0, color: "#8fa2ac", fontSize: 14, lineHeight: 1.5 }}>
          {t(bodyKey, { machine })}
        </p>
      </div>
    </main>
  );
}
