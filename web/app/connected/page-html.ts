import type { ConnectedApp, ConnectedStatus } from "./apps";
import type { ConnectedPageVariant } from "./variants";

/**
 * One "you're signed in, back to cmux" page for every sign-in callback: `/connected`
 * (MCP servers, Connections, anything that ends in a browser tab) and the cmux account's
 * after-sign-in page. A whole HTML document with no web build behind it: the sign-in
 * page's frame (app/handler/cmux-sign-in.tsx) with app/globals.css's tokens written
 * out, light and dark from the system, system fonts only (no font fetch).
 */
export type ConnectedPageInput = {
  locale: string;
  dir: "ltr" | "rtl";
  title: string;
  body: string;
  /** The primary button's label; it links to `href`. */
  button: string;
  /** A cmux URL (only ever an allowlisted own scheme or a native callback the caller checked). */
  href: string;
  /** A quiet line under the actions ("You can close this tab."). */
  hint?: string;
  secondary?: { href: string; label: string };
  /** The app signed in to; null draws the generic tile. */
  app: ConnectedApp | null;
  status: ConnectedStatus;
  variant: ConnectedPageVariant;
  /** Try `href` once on load (never for a link that carries tokens the person has not seen). */
  autoOpen: boolean;
};

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

const CMUX_MARK =
  '<svg viewBox="0 0 256 256" aria-hidden="true"><defs><linearGradient id="cmux-chevron" x1="91" y1="128" x2="179" y2="128" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#12c7f5"/><stop offset="0.52" stop-color="#2d8cff"/><stop offset="1" stop-color="#6c5cff"/></linearGradient></defs><path d="M91 65 L179 128 L91 191 L91 151 L139 128 L91 105 Z" fill="url(#cmux-chevron)"/></svg>';

const CHECK =
  '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const CROSS =
  '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 4.5l7 7m0-7l-7 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
const GENERIC =
  '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 15l6-6M10.5 6.5l1.8-1.8a4 4 0 015.7 5.7l-1.8 1.8M13.5 17.5l-1.8 1.8a4 4 0 01-5.7-5.7l1.8-1.8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';

function appTile(app: ConnectedApp | null, size: "sm" | "lg"): string {
  if (app?.id === "cmux") return `<span class="tile tile-${size} tile-cmux">${CMUX_MARK}</span>`;
  if (!app) return `<span class="tile tile-${size} tile-generic">${GENERIC}</span>`;
  const letter = escapeHtml(Array.from(app.name)[0]?.toUpperCase() ?? "?");
  return `<span class="tile tile-${size}" style="background:${app.color}">${letter}</span>`;
}

function badge(status: ConnectedStatus): string {
  return `<span class="badge badge-${status}">${status === "ok" ? CHECK : CROSS}</span>`;
}

function art(input: ConnectedPageInput): string {
  switch (input.variant) {
    case "card":
      // The app, then cmux: where you were, and where the button goes.
      return input.app?.id === "cmux"
        ? `<div class="art art-pair">${appTile(input.app, "sm")}${badge(input.status)}</div>`
        : `<div class="art art-pair">${appTile(input.app, "sm")}<span class="link-line"></span>${badge(input.status)}<span class="link-line"></span><span class="tile tile-sm tile-cmux">${CMUX_MARK}</span></div>`;
    case "spotlight":
      return `<div class="art art-spot">${appTile(input.app, "lg")}${badge(input.status)}</div>`;
    case "plain":
      return "";
  }
}

const CSS = `
:root{--background:#fafafa;--foreground:#171717;--muted:#707070;--border:#e5e5e5;--panel:#fff;--ok:#16a34a;--error:#dc2626;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--background:#0a0a0a;--foreground:#ededed;--muted:#a3a3a3;--border:#262626;--panel:#111;--ok:#4ade80;--error:#f87171}}
*,::before,::after{box-sizing:border-box;margin:0;padding:0}
html{line-height:1.5;-webkit-text-size-adjust:100%;font-family:ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
body{background:var(--background);color:var(--foreground)}
main{display:flex;min-height:100vh;align-items:center;justify-content:center;padding:48px 16px}
section{width:100%;max-width:340px}
h1{font-size:22px;font-weight:600;letter-spacing:-0.02em;line-height:1.3}
.body{margin-top:6px;font-size:14px;line-height:22px;color:var(--muted)}
.actions{display:grid;gap:8px;margin-top:24px}
a.primary{display:flex;height:40px;align-items:center;justify-content:center;border:1px solid var(--foreground);background:var(--foreground);color:var(--background);font-size:14px;font-weight:500;text-decoration:none;transition:opacity .15s}
a.primary:hover{opacity:.85}a.primary:active{opacity:.75}
a.primary:focus-visible,a.secondary:focus-visible{outline:1px solid var(--foreground);outline-offset:2px}
a.secondary{display:flex;height:38px;align-items:center;justify-content:center;border:1px solid var(--border);color:var(--foreground);font-size:14px;text-decoration:none}
a.secondary:hover{background:color-mix(in srgb,var(--foreground) 5%,transparent)}
.hint{margin-top:16px;font-size:12px;color:var(--muted)}
.tile{display:inline-grid;place-items:center;flex:none;color:#fff;font-weight:600;border-radius:10px;box-shadow:inset 0 0 0 1px rgba(255,255,255,.08)}
.tile-sm{width:40px;height:40px;font-size:18px}
.tile-lg{width:72px;height:72px;font-size:32px;border-radius:18px}
.tile-cmux{background:#fff;box-shadow:inset 0 0 0 1px var(--border)}
.tile-cmux svg{width:78%;height:78%}
.tile-generic{background:var(--panel);color:var(--muted);box-shadow:inset 0 0 0 1px var(--border)}
.tile-generic svg{width:55%;height:55%}
.badge{display:inline-grid;place-items:center;width:22px;height:22px;border-radius:999px;color:#fff;flex:none}
.badge svg{width:14px;height:14px}
.badge-ok{background:var(--ok);color:var(--background)}
.badge-error{background:var(--error);color:var(--background)}
.art{display:flex;align-items:center}
.art-pair{gap:8px;margin-bottom:20px}
.link-line{width:20px;height:1px;background:var(--border)}
.art-spot{position:relative;width:72px;margin:0 auto 20px}
.art-spot .badge{position:absolute;inset-inline-end:-8px;bottom:-8px;width:28px;height:28px;box-shadow:0 0 0 3px var(--background)}
.art-spot .badge svg{width:16px;height:16px}
.v-card section{max-width:380px;border:1px solid var(--border);background:var(--panel);padding:28px}
.v-spotlight section{text-align:center;max-width:360px}
.v-spotlight h1{font-size:26px}
.v-spotlight .body{margin-top:8px}
.v-spotlight a.primary{height:44px;font-size:15px}
@media (prefers-reduced-motion:reduce){a.primary{transition:none}}
`;

export function renderConnectedPage(input: ConnectedPageInput): string {
  const secondary = input.secondary
    ? `      <a class="secondary" href="${escapeHtml(input.secondary.href)}">${escapeHtml(input.secondary.label)}</a>\n`
    : "";
  const hint = input.hint ? `    <p class="hint">${escapeHtml(input.hint)}</p>\n` : "";
  // Reads the button's own href, so no value is ever written into script.
  const autoOpen = input.autoOpen
    ? `<script>(function(){var a=document.querySelector("a.primary");if(a)setTimeout(function(){window.location.href=a.href},150)})()</script>\n`
    : "";
  return `<!doctype html>
<html lang="${escapeHtml(input.locale)}" dir="${input.dir}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <meta name="robots" content="noindex">
  <title>${escapeHtml(input.title)}</title>
  <style>${CSS}</style>
</head>
<body class="v-${input.variant}">
<main>
  <section data-status="${input.status}" data-variant="${input.variant}" data-app="${escapeHtml(input.app?.id ?? "generic")}">
    ${art(input)}<h1>${escapeHtml(input.title)}</h1>
    <p class="body">${escapeHtml(input.body)}</p>
    <div class="actions">
      <a class="primary" href="${escapeHtml(input.href)}">${escapeHtml(input.button)}</a>
${secondary}    </div>
${hint}  </section>
</main>
${autoOpen}</body>
</html>`;
}
