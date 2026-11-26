/**
 * What `/connected` accepts: a known app id (anything else renders the generic
 * page), a status, and an own URL scheme to go back to (anything else is
 * ignored, so the page is never an open redirect).
 */
export type ConnectedApp = {
  id: string;
  name: string;
  /** The tile's background; the tile shows the name's first letter in white. */
  color: string;
};

const APPS: readonly ConnectedApp[] = [
  { id: "cmux", name: "cmux", color: "#2d8cff" },
  { id: "github", name: "GitHub", color: "#24292f" },
  { id: "linear", name: "Linear", color: "#5e6ad2" },
  { id: "slack", name: "Slack", color: "#4a154b" },
  { id: "sentry", name: "Sentry", color: "#362d59" },
  { id: "notion", name: "Notion", color: "#191919" },
  { id: "stripe", name: "Stripe", color: "#635bff" },
  { id: "vercel", name: "Vercel", color: "#000000" },
  { id: "supabase", name: "Supabase", color: "#3ecf8e" },
  { id: "neon", name: "Neon", color: "#00b386" },
  { id: "atlassian", name: "Atlassian", color: "#0052cc" },
  { id: "asana", name: "Asana", color: "#f06a6a" },
  { id: "intercom", name: "Intercom", color: "#1f8ded" },
  { id: "canva", name: "Canva", color: "#00c4cc" },
  { id: "posthog", name: "PostHog", color: "#f54e00" },
  { id: "monday", name: "monday.com", color: "#ff3d57" },
  { id: "figma", name: "Figma", color: "#a259ff" },
  { id: "cloudflare", name: "Cloudflare", color: "#f38020" },
  { id: "datadog", name: "Datadog", color: "#632ca6" },
  { id: "grafana", name: "Grafana", color: "#f46800" },
  { id: "chatgpt", name: "ChatGPT", color: "#10a37f" },
  { id: "claude", name: "Claude", color: "#d97757" },
  { id: "gemini", name: "Gemini", color: "#4285f4" },
  { id: "google", name: "Google", color: "#4285f4" },
];

const APPS_BY_ID = new Map(APPS.map((app) => [app.id, app]));

export const CONNECTED_APP_IDS: readonly string[] = APPS.map((app) => app.id);

/** The known app for `raw`, or null for the generic page. */
export function resolveConnectedApp(raw: string | null | undefined): ConnectedApp | null {
  return APPS_BY_ID.get(raw?.trim().toLowerCase() ?? "") ?? null;
}

export type ConnectedStatus = "ok" | "error";

export function resolveConnectedStatus(raw: string | null | undefined): ConnectedStatus {
  return raw?.trim().toLowerCase() === "error" ? "error" : "ok";
}

/** cmux's own URL schemes (web/app/lib/native-callback.ts's builds), the only places "Back to cmux" goes. */
const RETURN_SCHEMES = new Set([
  "cmux",
  "cmux-nightly",
  "cmux-rc",
  "cmux-next",
  "cmux-next-stable",
  "cmux-next-dev",
  "cmux-dev",
]);

export const DEFAULT_RETURN_SCHEME = "cmux";

/** `<scheme>://` for an allowlisted scheme (`cmux` or `cmux://` both read as `cmux`), else `cmux://`. */
export function connectedReturnHref(raw: string | null | undefined): string {
  const scheme = raw?.trim().toLowerCase().replace(/:(\/\/)?$/, "") ?? "";
  return `${RETURN_SCHEMES.has(scheme) ? scheme : DEFAULT_RETURN_SCHEME}://`;
}
