/**
 * The cmux-owned desktop wrapper: the URL a person actually sees and keeps.
 *
 * A desktop preview gateway owns its own token query parameter and cannot be
 * asked to rename it, so instead the raw tokened preview URL stops being
 * user-visible at all. `openUrl` for a port open points at
 * `/vm/desktop/<machine>?cmux_token=…` on our origin; that page validates the
 * upstream host and token, then sends the pane to the noVNC page top-level with
 * the gateway's own parameter. It must be a top-level navigation, not an iframe:
 * the gateway answers the tokened request with a matching cookie that every
 * later asset, and the websockify upgrade, must carry, and WebKit refuses
 * third-party cookies inside a cross-site frame — an iframed desktop rendered as
 * unstyled noVNC HTML with a dead Connect button. The wrapper also knows the
 * token's expiry, so a lapsed pane shows an honest "reopen from cmux" screen
 * instead of a silent white one.
 *
 * DORMANT: no driver implements `openPort`, so nothing produces an upstream URL
 * for this wrapper today. It is kept as the seam for Freestyle desktop support
 * (public Freestyle serves arbitrary ports through a TLS rule on a verified
 * domain). Whoever wires that up sets DESKTOP_UPSTREAM_TOKEN_PARAM and the host
 * suffix to whatever that edge actually uses.
 */

/** Hosts the wrapper will agree to send a pane to: the cmux-branded machine domain. */
const ALLOWED_UPSTREAM_SUFFIXES = [".vm.cmux.sh"] as const;

/**
 * The upstream gateway's own token parameter. Still carries the retired
 * gateway's name because no replacement edge has been chosen yet.
 */
const DESKTOP_UPSTREAM_TOKEN_PARAM = "bl_preview_token";

export function isAllowedDesktopUpstreamHost(host: string | null | undefined): boolean {
  const normalized = host?.trim().toLowerCase();
  if (!normalized) return false;
  // Previews terminate on the gateway's 443 only; a port marks a forgery.
  if (normalized.includes(":") || normalized.includes("/") || normalized.includes("@")) return false;
  return ALLOWED_UPSTREAM_SUFFIXES.some(
    (suffix) => normalized.endsWith(suffix) && normalized.length > suffix.length,
  );
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
  const wrapper = new URL(`/vm/desktop/${encodeURIComponent(input.vmId)}`, input.origin);
  wrapper.searchParams.set("cmux_token", input.token);
  wrapper.searchParams.set("host", upstreamHost);
  if (input.expiresAtMs && Number.isFinite(input.expiresAtMs)) {
    wrapper.searchParams.set("exp", String(Math.floor(input.expiresAtMs)));
  }
  return wrapper.toString();
}

/**
 * Where the wrapper page sends the pane: the upstream noVNC page with the
 * gateway's own token parameter plus the forwarded display options.
 */
export function desktopUpstreamUrl(input: {
  readonly host: string;
  readonly token: string;
  readonly params: Readonly<Record<string, string | string[] | undefined>>;
}): string | null {
  if (!isAllowedDesktopUpstreamHost(input.host)) return null;
  const token = input.token.trim();
  if (!token || !/^[A-Za-z0-9_-]{8,512}$/.test(token)) return null;
  const url = new URL(`https://${input.host.trim().toLowerCase()}/`);
  url.searchParams.set(DESKTOP_UPSTREAM_TOKEN_PARAM, token);
  for (const key of FORWARDED_DISPLAY_PARAMS) {
    const value = input.params[key];
    const single = Array.isArray(value) ? value[0] : value;
    if (typeof single === "string" && single.length > 0 && single.length <= 64) {
      url.searchParams.set(key, single);
    }
  }
  return url.toString();
}
