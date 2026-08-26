import { createTranslator } from "next-intl";
import { headers } from "next/headers";
import { desktopIframeUrl } from "../../../../services/vms/desktopWrapper";
import { preferredLocaleFromAcceptLanguage } from "../../../../i18n/accept-language";
import { loadMessages } from "../../../../i18n/messages";

// The cmux-owned face of a machine's screen. The pane's address bar shows
// this URL (`cmux_token` on our origin); the gateway's own token parameter
// exists only inside the iframe src. When the token lapses, the overlay says
// so and points at the fix instead of leaving a silent white canvas.
export default async function VmDesktopPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { id } = await params;
  const query = await searchParams;
  const token = typeof query.cmux_token === "string" ? query.cmux_token : "";
  const host = typeof query.host === "string" ? query.host : "";
  const expiresAtMs = typeof query.exp === "string" ? Number.parseInt(query.exp, 10) : NaN;
  const frameSrc = desktopIframeUrl({ host, token, params: query });
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

  if (!frameSrc) {
    return (
      <main style={shell}>
        <div style={{ maxWidth: 440, padding: 24 }}>
          <h1 style={{ fontSize: 18, margin: "0 0 8px" }}>{t("invalidTitle")}</h1>
          <p style={{ margin: 0, color: "#8fa2ac", fontSize: 14, lineHeight: 1.5 }}>
            {t("invalidBody", { machine })}
          </p>
        </div>
      </main>
    );
  }

  const expired = Number.isFinite(expiresAtMs) && Date.now() > expiresAtMs;
  if (expired) {
    return (
      <main style={shell}>
        <div style={{ maxWidth: 440, padding: 24 }}>
          <h1 style={{ fontSize: 18, margin: "0 0 8px" }}>{t("expiredTitle")}</h1>
          <p style={{ margin: 0, color: "#8fa2ac", fontSize: 14, lineHeight: 1.5 }}>
            {t("expiredBody", { machine })}
          </p>
        </div>
      </main>
    );
  }

  return (
    <main style={{ margin: 0, height: "100vh", background: "#101418" }}>
      <title>{`${machine} — desktop`}</title>
      <iframe
        src={frameSrc}
        title={`${machine} desktop`}
        allow="clipboard-read; clipboard-write; fullscreen"
        style={{ border: 0, width: "100%", height: "100%", display: "block" }}
      />
      {Number.isFinite(expiresAtMs) ? (
        <script
          // Long-lived panes outlive the token, and browser timers stall while
          // a pane is backgrounded or the machine sleeps — so the deadline is
          // re-checked on wake/focus/visibility as well as a chained timer
          // (re-armed, since a single stalled setTimeout can fire early
          // relative to real elapsed time). Crossing it reloads so the server
          // renders the honest expiry screen above.
          dangerouslySetInnerHTML={{
            __html: `(function () {
  var exp = ${expiresAtMs};
  function check() { if (Date.now() > exp) location.reload(); }
  document.addEventListener("visibilitychange", check);
  window.addEventListener("focus", check);
  window.addEventListener("pageshow", check);
  (function arm() {
    var delay = Math.min(Math.max(exp - Date.now() + 2000, 1000), 2147483647);
    setTimeout(function () { check(); if (Date.now() <= exp) arm(); }, delay);
  })();
})();`,
          }}
        />
      ) : null}
    </main>
  );
}
