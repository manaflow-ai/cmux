// Whether address bar text is a URL to load or a search query (BrowserURLResolver.swift). The
// rules, in order, are the Swift type's doc comment; URLs are returned as the text Foundation's
// `absoluteString` gives.
import { chromiumPage } from "./chromium-page";
import {
  asciiHost,
  authorityEnd,
  componentsURL,
  fileURL,
  hasWhitespace,
  isLetter,
  isNewline,
  isNumber,
  isWhitespace,
  lenientURL,
  parseUnsigned,
  trimWhitespace,
} from "./url-text";

export interface URLResolverConfig {
  /** The user's home directory path (`/Users/me`); without it `~` paths are searched. */
  homeDirectory?: string | null;
  /** Chromium tabs: `chrome://`, `chrome-extension://` and WebUI `about:` pages load. */
  allowsChromiumSchemes?: boolean;
}

/** cmux's own pages that are no browser page, which the App opens instead of loading. */
export const CMUX_APP_PAGE_HOSTS: ReadonlySet<string> = new Set(["stashed"]);

const NON_UNIQUE_SUFFIXES = [
  "local",
  "lan",
  "internal",
  "intranet",
  "corp",
  "home",
  "localdomain",
  "test",
  "example",
  "invalid",
  "home.arpa",
];

/**
 * Whether `text` holds an old Mac Screen pairing link (`cmux-vnc://pair?…` or `cmux-vnc:pair?…`,
 * any case, anywhere in the text). It carries a room secret: never load, search or send it.
 */
export function containsPairingLink(text: string): boolean {
  const lower = text.toLowerCase();
  let from = 0;
  for (;;) {
    const scheme = lower.indexOf("cmux-vnc:", from);
    if (scheme < 0) return false;
    from = scheme + "cmux-vnc:".length;
    if (lower.startsWith("pair", from) || lower.startsWith("//pair", from)) return true;
  }
}

/** Lowercased host (brackets stripped from IPv6) and whether a numeric port follows it. */
export function splitHostAndPort(authority: string): { host: string; hasPort: boolean } {
  const lower = authority.toLowerCase();
  const isPort = (text: string) => text !== "" && /^[0-9]+$/.test(text) && parseUnsigned(text, 0xffff) != null;
  if (lower.startsWith("[")) {
    const close = lower.indexOf("]");
    if (close < 0) return { host: "", hasPort: false };
    const host = lower.slice(1, close);
    const rest = lower.slice(close + 1);
    if (!rest) return { host, hasPort: false };
    return rest.startsWith(":") && isPort(rest.slice(1)) ? { host, hasPort: true } : { host: "", hasPort: false };
  }
  const colon = lower.indexOf(":");
  if (colon < 0) return { host: lower, hasPort: false };
  return isPort(lower.slice(colon + 1)) ? { host: lower.slice(0, colon), hasPort: true } : { host: "", hasPort: false };
}

/** `localhost`, `*.localhost`, `127.0.0.0/8`, `::1`, and `0.0.0.0`. */
export function isLoopback(host: string): boolean {
  if (host === "localhost" || host.endsWith(".localhost") || host === "::1" || host === "0.0.0.0") return true;
  const octets = host.split(".");
  return octets.length === 4 && octets[0] === "127" && octets.every((octet) => parseUnsigned(octet, 255) != null);
}

/** Chromium's `net::IsHostnameNonUnique`: private and intranet names that never get a public certificate. */
export function isNonUniqueHost(host: string): boolean {
  if (host.includes(":")) {
    const lower = host.toLowerCase();
    return ["fc", "fd", "fe8", "fe9", "fea", "feb"].some((prefix) => lower.startsWith(prefix));
  }
  const labels = host.split(".");
  const octets = labels.map((label) => parseUnsigned(label, 255));
  if (labels.length === 4 && octets.every((octet) => octet != null)) {
    const [a, b] = octets as number[];
    return (
      a === 10 ||
      (a === 192 && b === 168) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 100 && b >= 64 && b <= 127)
    );
  }
  if (labels.some((label) => !label)) return false;
  if (labels.length === 1) return !Array.from(host).every(isNumber);
  return NON_UNIQUE_SUFFIXES.some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
}

/** At least two labels, the last one a TLD-like label (letters or punycode), or an IPv4 address. */
function isDottedHost(host: string): boolean {
  const labels = host.split(".");
  if (labels.length < 2 || labels.some((label) => !label)) return false;
  if (labels.length === 4 && labels.every((label) => parseUnsigned(label, 255) != null)) return true;
  const tld = Array.from(labels[labels.length - 1]);
  if (tld.length < 2) return false;
  return tld.every(isLetter) || tld.join("").startsWith("xn--");
}

/** Whitespace and breaks are single UTF-16 units, so a code unit scan finds them. */
function firstIndex(text: string, predicate: (character: string) => boolean): number {
  for (let index = 0; index < text.length; index++) if (predicate(text[index])) return index;
  return -1;
}

const isWrapBreak = (character: string) => isNewline(character) || character === "\t";

/** The text with wrap breaks removed, unchanged without any, or null when a break sits in the host. */
function removingWrapBreaks(text: string): string | null {
  const breakIndex = firstIndex(text, isWrapBreak);
  if (breakIndex < 0) return text;
  const separator = text.indexOf("://");
  const authorityStart = separator < 0 ? 0 : separator + 3;
  const end = authorityEnd(text, authorityStart);
  if (authorityStart > breakIndex || end < 0 || end >= breakIndex) return null;
  const compacted = Array.from(text, (character) => (isWrapBreak(character) ? "" : character)).join("");
  return hasWhitespace(compacted) ? null : compacted;
}

/** The scheme when the text starts with one; `localhost:3000` and `example.com:8080/x` are host and port. */
function explicitScheme(text: string): string | null {
  const colon = text.indexOf(":");
  if (colon < 0) return null;
  const candidate = Array.from(text.slice(0, colon));
  if (!candidate.length || !isLetter(candidate[0])) return null;
  if (!candidate.every((c) => isLetter(c) || isNumber(c) || "+-.".includes(c))) return null;
  const afterColon = Array.from(text.slice(colon + 1));
  let portLength = 0;
  while (portLength < afterColon.length && isNumber(afterColon[portLength])) portLength++;
  if (portLength > 0 && afterColon.slice(0, 2).join("") !== "//") {
    const next = afterColon[portLength];
    if (next == null || "/?#".includes(next)) return null;
  }
  return candidate.join("").toLowerCase();
}

export type URLResolve = (input: string) => string | null;

/** `BrowserURLResolver.url(for:)`: a URL to load, or null when the text should be searched. */
export function createURLResolver(config: URLResolverConfig = {}): URLResolve {
  const home = config.homeDirectory ? config.homeDirectory.replace(/\/*$/, "/") : null;
  const allowsChromiumSchemes = config.allowsChromiumSchemes ?? false;

  function fileURLFor(text: string): string | null | undefined {
    if (text.startsWith("/")) return fileURL(text);
    if (text === "~" || text.startsWith("~/")) return home ? fileURL(home + text.slice(2).replace(/^\/+/, "")) : null;
    return undefined;
  }

  function macScreenAddress(text: string, scheme: string): string | null {
    const url = lenientURL(text);
    if (!url) return null;
    if (scheme === "cmux-vnc") return containsPairingLink(text) ? url.text : null;
    return url.parsed.host?.toLowerCase() === "mac-screen" ? url.text : null;
  }

  function cmuxAppPage(text: string): string | null {
    const host = lenientURL(text)?.parsed.host?.toLowerCase();
    return host && CMUX_APP_PAGE_HOSTS.has(host) ? `cmux://${host}` : null;
  }

  function explicitURL(text: string, scheme: string): string | null {
    switch (scheme) {
      case "http":
      case "https": {
        const url = componentsURL(text);
        return url?.parsed.host ? url.text : null;
      }
      case "file": {
        const url = lenientURL(text);
        return url && url.parsed.scheme.toLowerCase() === "file" && url.parsed.path.startsWith("/") ? url.text : null;
      }
      case "about":
        if (text.toLowerCase() === "about:blank") return "about:blank";
        return chromiumPage(text, scheme, allowsChromiumSchemes);
      case "chrome":
      case "chrome-extension":
        return chromiumPage(text, scheme, allowsChromiumSchemes);
      case "cmux-vnc":
        return macScreenAddress(text, scheme);
      case "cmux":
        return macScreenAddress(text, scheme) ?? cmuxAppPage(text);
      default:
        return null;
    }
  }

  /** An `http`, `https` or `file` URL with spaces only after its host, the spaces percent-encoded. */
  function encodingSpaces(text: string): string | null {
    const scheme = explicitScheme(text);
    if (scheme !== "http" && scheme !== "https" && scheme !== "file") return null;
    const separator = text.indexOf("://");
    if (separator < 0) return null;
    const end = authorityEnd(text, separator + 3);
    if (end < 0 || end >= firstIndex(text, isWhitespace)) return null;
    if (firstIndex(text, (c) => isWhitespace(c) && c !== " ") >= 0) return null;
    return explicitURL(text.replaceAll(" ", "%20"), scheme);
  }

  function schemeLessURL(text: string): string | null {
    const end = authorityEnd(text);
    const authority = end < 0 ? text : text.slice(0, end);
    if (!authority || authority.includes("@")) return null;
    const split = splitHostAndPort(authority);
    // A Unicode host is judged in its punycode form (`例え.みんな` is `xn--r8jz45g.xn--q9jyb4c`).
    const host = split.host && asciiHost(split.host);
    const hasPort = split.hasPort;
    if (!host) return null;
    const hasPath = end >= 0 && text[end] === "/";
    let scheme: string;
    if (isLoopback(host)) {
      scheme = "http";
    } else if (isNonUniqueHost(host)) {
      // Never upgraded: a router, NAS or dev server has no certificate. A single label needs a
      // port or a path ("devbox:8080", "router/"); alone it is a search.
      if (!host.includes(".") && !host.includes(":") && !hasPort && !hasPath) return null;
      scheme = "http";
    } else if (hasPort || isDottedHost(host) || host.includes(":")) {
      scheme = "https";
    } else {
      return null;
    }
    const url = componentsURL(`${scheme}://${text}`);
    return url?.parsed.host ? url.text : null;
  }

  return (input: string) => {
    const trimmed = trimWhitespace(input);
    if (!trimmed) return null;
    const text = removingWrapBreaks(trimmed);
    if (text == null) return null;
    const file = fileURLFor(text);
    if (file !== undefined) return file;
    if (hasWhitespace(text)) return encodingSpaces(text);
    const scheme = explicitScheme(text);
    return scheme != null ? explicitURL(text, scheme) : schemeLessURL(text);
  };
}
