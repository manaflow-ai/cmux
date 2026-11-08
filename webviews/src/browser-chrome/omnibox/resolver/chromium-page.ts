// Chromium internal pages in canonical form (ChromiumInternalURL.swift) and which of them cmux
// shows itself (ChromiumPageRoute.swift), so a WebKit tab can open them too.
import { authorityEnd, parseStrictURL } from "./url-text";

/** Hosts whose pages cmux shows itself (`chrome://history` is `cmux://history`). */
const CMUX_PAGE_HOSTS: ReadonlySet<string> = new Set(["history", "bookmarks"]);

/**
 * `ChromiumInternalURL(text, scheme:)`: `chrome://`, `chrome-extension://` or an `about:` alias,
 * scheme and host lowercased, slashes after the colon optional, an empty path `/`. `scheme` is the
 * lowercased scheme of `text`.
 */
export function chromiumInternalURL(text: string, scheme: string): string | null {
  const colon = text.indexOf(":");
  if (colon < 0) return null;
  let rest = text.slice(colon + 1);
  let canonicalScheme: string;
  if (scheme === "chrome" || scheme === "chrome-extension") {
    canonicalScheme = scheme;
  } else if (scheme === "about") {
    const pageEnd = rest.search(/[?#]/);
    const page = (pageEnd < 0 ? rest : rest.slice(0, pageEnd)).toLowerCase();
    if (page === "blank" || page === "srcdoc") return null;
    canonicalScheme = "chrome";
  } else {
    return null;
  }
  rest = rest.replace(/^\/+/, "");
  const end = authorityEnd(rest);
  const host = (end < 0 ? rest : rest.slice(0, end)).toLowerCase();
  if (!host || !/^[a-z0-9\-_.]+$/.test(host)) return null;
  let tail = end < 0 ? "" : rest.slice(end);
  if (!tail.startsWith("/")) tail = `/${tail}`;
  const url = `${canonicalScheme}://${host}${tail}`;
  return parseStrictURL(url)?.host === host ? url : null;
}

/** `ChromiumPageRoute(url)?.isCmuxOwned`: History, Bookmarks, Passwords or Settings > Browser. */
export function isCmuxOwnedPage(canonicalURL: string): boolean {
  const parsed = parseStrictURL(canonicalURL);
  if (!parsed || parsed.scheme !== "chrome" || !parsed.host) return false;
  const { host, path } = parsed;
  if (CMUX_PAGE_HOSTS.has(host) || host === "password-manager") return true;
  return host === "settings" && (path === "/" || path === "/passwords" || path.startsWith("/passwords/"));
}

/** A Chromium internal page; a WebKit tab takes only the pages cmux shows itself. */
export function chromiumPage(text: string, scheme: string, allowsChromiumSchemes: boolean): string | null {
  const page = chromiumInternalURL(text, scheme);
  if (page == null) return null;
  return allowsChromiumSchemes || isCmuxOwnedPage(page) ? page : null;
}
