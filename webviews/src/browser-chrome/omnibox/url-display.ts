// How the address bar shows a URL (BrowserURLDisplay.swift). URLs are strings as the host reports
// them; they are split here without normalizing, so the text matches what Foundation shows.
import type { TextRange } from "./types";

export interface URLParts {
  scheme: string;
  /** Present when the URL has `//`. */
  authority: string | null;
  userinfo: string | null;
  /** IPv6 hosts keep their brackets. */
  host: string | null;
  port: string | null;
  path: string;
  query: string | null;
  fragment: string | null;
}

const URL_PATTERN = /^([A-Za-z][A-Za-z0-9+.-]*):(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#([\s\S]*))?$/;

export function parseURL(url: string): URLParts | null {
  const match = URL_PATTERN.exec(url);
  if (!match) return null;
  const authority = match[2] ?? null;
  let userinfo: string | null = null;
  let host: string | null = null;
  let port: string | null = null;
  if (authority != null) {
    const at = authority.lastIndexOf("@");
    if (at >= 0) userinfo = authority.slice(0, at);
    const hostPort = authority.slice(at + 1);
    const close = hostPort.startsWith("[") ? hostPort.indexOf("]") : -1;
    const colon = hostPort.indexOf(":", close + 1);
    host = colon >= 0 ? hostPort.slice(0, colon) : hostPort;
    port = colon >= 0 ? hostPort.slice(colon + 1) || null : null;
  }
  return {
    scheme: match[1],
    authority,
    userinfo,
    host,
    port,
    path: match[3],
    query: match[4] ?? null,
    fragment: match[5] ?? null,
  };
}

export function formatURL(parts: URLParts): string {
  let text = `${parts.scheme}:`;
  if (parts.authority != null) {
    text += "//";
    if (parts.userinfo != null) text += `${parts.userinfo}@`;
    text += parts.host ?? "";
    if (parts.port != null) text += `:${parts.port}`;
  }
  text += parts.path;
  if (parts.query != null) text += `?${parts.query}`;
  if (parts.fragment != null) text += `#${parts.fragment}`;
  return text;
}

export function urlScheme(url: string): string | null {
  return parseURL(url)?.scheme.toLowerCase() ?? null;
}

/** `url.host(percentEncoded: false)`: without IPv6 brackets. */
export function urlHost(url: string): string | null {
  const host = parseURL(url)?.host;
  if (host == null) return null;
  return decode(host.startsWith("[") && host.endsWith("]") ? host.slice(1, -1) : host);
}

function decode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

/** Chromium's own schemes, shown with their scheme (`ChromiumInternalURL.chromiumSchemes`). */
const CHROMIUM_SCHEMES = new Set(["chrome", "chrome-extension"]);

/** The New Tab page and the blank page: the omnibar shows nothing (`BrowserNewTabPage`). */
export function isNewTabPage(url: string): boolean {
  const lowered = url.toLowerCase();
  return lowered === "about:blank" || lowered === "chrome://newtab/" || lowered === "chrome://newtab";
}

/** A remote desktop tab (`cmux://remote-view?…`): its address is a saved record, not a page. */
export function isRemoteDesktopPage(url: string): boolean {
  const parts = parseURL(url);
  return parts?.scheme.toLowerCase() === "cmux" && parts.host?.toLowerCase() === "remote-view";
}

function stripsWWW(host: string): boolean {
  return host.toLowerCase().startsWith("www.") && host.split(".").filter(Boolean).length > 2;
}

/**
 * Compact text shown when the field is not being edited: no `https://`, no `www.`, no trailing
 * slash on a bare host, percent escapes decoded. `http://` and Chromium's schemes stay. A file
 * shows its path, `~/…` under `home`.
 */
export function urlDisplayText(url: string | null | undefined, home = ""): string {
  if (url == null) return "";
  if (isNewTabPage(url) || isRemoteDesktopPage(url)) return "";
  const parts = parseURL(url);
  if (parts?.scheme.toLowerCase() === "file") return tildePath(decode(parts.path), home);
  if (!parts || !parts.host) return url;
  const scheme = parts.scheme.toLowerCase();
  const host = stripsWWW(parts.host) ? parts.host.slice(4) : parts.host;
  let text = formatURL({ ...parts, userinfo: null, host }).slice(parts.scheme.length + 3);
  if (parts.path === "/" && parts.query == null && parts.fragment == null) text = text.slice(0, -1);
  text = decode(text);
  if (scheme === "http" || CHROMIUM_SCHEMES.has(scheme)) return `${scheme}://${text}`;
  return text;
}

/** `path` with `home` (and only home, never a sibling such as `/Users/me2`) replaced by `~`. */
export function tildePath(path: string, home: string): string {
  let root = home;
  while (root.length > 1 && root.endsWith("/")) root = root.slice(0, -1);
  if (root.length <= 1) return path;
  let trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith("/")) trimmed = trimmed.slice(0, -1);
  if (trimmed === root) return "~";
  if (!path.startsWith(`${root}/`)) return path;
  return `~${path.slice(root.length)}`;
}

/**
 * The host's UTF-16 range inside `text` (the compact text or the full URL), drawn at full strength
 * while the rest is dimmed. Null for file URLs and blank pages.
 */
export function urlHostRange(text: string, url: string | null | undefined): TextRange | null {
  if (url == null || urlScheme(url) === "file") return null;
  const fullHost = urlHost(url);
  if (!fullHost) return null;
  const host = stripsWWW(fullHost) ? fullHost.slice(4) : fullHost;
  const scheme = urlScheme(url) ?? "";
  const prefix = scheme && text.toLowerCase().startsWith(`${scheme}://`) ? `${scheme}://` : "";
  const rest = text.slice(prefix.length).toLowerCase();
  for (const candidate of [host, fullHost]) {
    const hostText = candidate.includes(":") && !candidate.startsWith("[") ? `[${candidate}]` : candidate;
    if (rest.startsWith(hostText.toLowerCase())) return { location: prefix.length, length: hostText.length };
  }
  return null;
}

/** Full text placed in the field when editing starts. */
export function urlEditingText(url: string | null | undefined): string {
  if (url == null || isNewTabPage(url) || isRemoteDesktopPage(url)) return "";
  return url;
}

/** Title for tab strips: the page title, else the host, else null (callers show "New Tab"). */
export function tabTitle(tab: { title?: string | null; url?: string | null }): string | null {
  if (tab.title != null) return tab.title;
  if (tab.url == null || isNewTabPage(tab.url)) return null;
  const host = urlHost(tab.url);
  if (host) return host;
  const path = parseURL(tab.url)?.path ?? "";
  const last = path.split("/").filter(Boolean).pop();
  return last ?? (path.startsWith("/") ? "/" : null);
}
