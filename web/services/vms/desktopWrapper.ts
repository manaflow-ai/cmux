/**
 * The cmux-owned desktop wrapper: the URL a person actually sees and keeps.
 *
 * Blaxel's gateway owns the `bl_preview_token` query parameter — it cannot be
 * renamed at their edge — so instead the raw tokened preview URL stops being
 * user-visible at all. `openUrl` for a port open points at
 * `/vm/desktop/<machine>#cmux_token=…` on our origin; that page validates the
 * upstream host and frames the noVNC page with the token internal to the
 * iframe src. The wrapper also knows the token's expiry, so a lapsed pane
 * shows an honest "reopen from cmux" screen instead of a silent white one.
 *
 * The session rides in the URL *fragment*, not the query string: a fragment
 * never leaves the browser, so the week-long bearer token stays out of server
 * access logs, request traces, and Referer headers. Query parameters are still
 * accepted for wrapper URLs minted before this change.
 */

/** Hosts the wrapper will agree to frame: Blaxel previews, branded or not. */
const ALLOWED_UPSTREAM_SUFFIXES = [".vm.cmux.sh", ".preview.bl.run"] as const;

export function isAllowedDesktopUpstreamHost(host: string | null | undefined): boolean {
  const normalized = host?.trim().toLowerCase();
  if (!normalized) return false;
  // Previews terminate on the gateway's 443 only; a port marks a forgery.
  if (normalized.includes(":") || normalized.includes("/") || normalized.includes("@")) return false;
  return ALLOWED_UPSTREAM_SUFFIXES.some(
    (suffix) => normalized.endsWith(suffix) && normalized.length > suffix.length,
  );
}

/**
 * On the cmux-owned domain every preview is branded `<machine>-<port>.vm.cmux.sh`,
 * so the wrapper can also insist the host names the machine in its path — a
 * forged link cannot dress another machine's screen up as this one. Opaque
 * `preview.bl.run` hash hosts carry no machine name, so only the suffix
 * allowlist applies there.
 */
export function desktopHostMatchesVm(host: string, vmId: string): boolean {
  const normalizedHost = host.trim().toLowerCase();
  if (!normalizedHost.endsWith(".vm.cmux.sh")) return true;
  const machine = vmId.trim().toLowerCase();
  if (!machine) return false;
  const label = normalizedHost.slice(0, normalizedHost.length - ".vm.cmux.sh".length);
  // Port previews are the only branded shape the wrapper frames, so the label
  // is exactly `<machine>-<port>` — a plain prefix test would let a machine
  // named "tidy" claim "tidy-heron-6901".
  if (!label.startsWith(`${machine}-`)) return false;
  return /^\d{1,5}$/.test(label.slice(machine.length + 1));
}

/** noVNC display options the wrapper forwards into the iframe, nothing else. */
const FORWARDED_DISPLAY_PARAMS = [
  "autoconnect",
  "resize",
  "reconnect",
  "reconnect_delay",
  "view_only",
] as const;

export function desktopWrapperUrl(input: {
  readonly origin: string;
  readonly vmId: string;
  readonly upstreamUrl: string;
  readonly token: string;
  readonly expiresAtMs?: number;
}): string | null {
  let upstreamHost: string;
  try {
    const upstream = new URL(input.upstreamUrl);
    if (upstream.protocol !== "https:") return null;
    upstreamHost = upstream.host;
  } catch {
    return null;
  }
  if (!isAllowedDesktopUpstreamHost(upstreamHost)) return null;
  if (!desktopHostMatchesVm(upstreamHost, input.vmId)) return null;
  const wrapper = new URL(`/vm/desktop/${encodeURIComponent(input.vmId)}`, input.origin);
  // The session travels in the fragment so the token never reaches a server.
  // Callers that append display options with a bare `&` (the mac CLI does)
  // extend the fragment, and the page parses the whole fragment as a query
  // string, so those options still arrive.
  const session = new URLSearchParams();
  session.set("cmux_token", input.token);
  session.set("host", upstreamHost);
  if (input.expiresAtMs && Number.isFinite(input.expiresAtMs)) {
    session.set("exp", String(Math.floor(input.expiresAtMs)));
  }
  wrapper.hash = session.toString();
  return wrapper.toString();
}

export type DesktopSession = {
  readonly token: string;
  readonly host: string;
  readonly expiresAtMs: number | null;
  readonly displayParams: Readonly<Record<string, string>>;
};

/**
 * Extracts the desktop session from the page's inputs. The fragment is the
 * current format; the legacy query parameters (wrapper URLs minted before the
 * fragment change) fill any field the fragment does not carry.
 */
export function desktopSessionFromInputs(input: {
  readonly fragment: string;
  readonly legacyQuery: Readonly<Record<string, string | string[] | undefined>>;
}): DesktopSession {
  const fragmentParams = new URLSearchParams(input.fragment.replace(/^#/, ""));
  const legacy = (key: string): string => {
    const value = input.legacyQuery[key];
    const single = Array.isArray(value) ? value[0] : value;
    return typeof single === "string" ? single : "";
  };
  const pick = (key: string): string => fragmentParams.get(key)?.trim() || legacy(key).trim();
  const expRaw = pick("exp");
  const exp = expRaw ? Number.parseInt(expRaw, 10) : NaN;
  const displayParams: Record<string, string> = {};
  for (const key of FORWARDED_DISPLAY_PARAMS) {
    const value = pick(key);
    if (value) displayParams[key] = value;
  }
  return {
    token: pick("cmux_token"),
    host: pick("host"),
    expiresAtMs: Number.isFinite(exp) ? exp : null,
    displayParams,
  };
}

/**
 * Rewrites a legacy wrapper URL (token in the query string) into the fragment
 * form, preserving any fragment values already present. Returns null when the
 * URL is malformed or carries no legacy token, so callers touch history only
 * when there is something to scrub.
 */
export function upgradedLegacyWrapperUrl(href: string): string | null {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return null;
  }
  if (!url.searchParams.has("cmux_token")) return null;
  const fragment = new URLSearchParams(url.hash.replace(/^#/, ""));
  for (const [key, value] of url.searchParams) {
    if (!fragment.has(key)) fragment.set(key, value);
  }
  url.search = "";
  url.hash = fragment.toString();
  return url.toString();
}

/**
 * The iframe src the wrapper page renders: the upstream noVNC page with the
 * gateway's own token parameter plus the forwarded display options.
 */
export function desktopIframeUrl(input: {
  readonly host: string;
  readonly token: string;
  readonly vmId?: string;
  readonly params: Readonly<Record<string, string | string[] | undefined>>;
}): string | null {
  if (!isAllowedDesktopUpstreamHost(input.host)) return null;
  if (typeof input.vmId === "string" && !desktopHostMatchesVm(input.host, input.vmId)) return null;
  const token = input.token.trim();
  if (!token || !/^[A-Za-z0-9_-]{8,512}$/.test(token)) return null;
  const url = new URL(`https://${input.host.trim().toLowerCase()}/`);
  url.searchParams.set("bl_preview_token", token);
  for (const key of FORWARDED_DISPLAY_PARAMS) {
    const value = input.params[key];
    const single = Array.isArray(value) ? value[0] : value;
    if (typeof single === "string" && single.length > 0 && single.length <= 64) {
      url.searchParams.set(key, single);
    }
  }
  return url.toString();
}
