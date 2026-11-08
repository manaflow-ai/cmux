// Swift and Foundation semantics the URL resolver relies on: Character's whitespace, newline,
// letter and number tests, `URLComponents(string:)` and `URL(string:)` (each encodes a
// component's invalid characters first, macOS 14+) and `URL(filePath:)`.

/** `CharacterSet.whitespacesAndNewlines`, and `Character.isWhitespace` for one code point. */
const WHITESPACE = /[\t-\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]/;
const NEWLINE = /[\n\v\f\r\u0085\u2028\u2029]/;
const LEADING_WHITESPACE = new RegExp(`^${WHITESPACE.source}+`);
const TRAILING_WHITESPACE = new RegExp(`${WHITESPACE.source}+$`);

export const isWhitespace = (character: string): boolean => WHITESPACE.test(character);
export const isNewline = (character: string): boolean => NEWLINE.test(character);
export const hasWhitespace = (text: string): boolean => WHITESPACE.test(text);
export const isLetter = (character: string): boolean => /^\p{L}$/u.test(character);
export const isNumber = (character: string): boolean => /^\p{N}$/u.test(character);

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export function trimWhitespace(text: string): string {
  return text.replace(LEADING_WHITESPACE, "").replace(TRAILING_WHITESPACE, "");
}

/** Index of the first of `/`, `?` or `#` at or after `from`, or -1. */
export function authorityEnd(text: string, from = 0): number {
  for (let index = from; index < text.length; index++) {
    const character = text[index];
    if (character === "/" || character === "?" || character === "#") return index;
  }
  return -1;
}

/** Swift `UInt8(text)` / `UInt16(text)`: ASCII digits, an optional `+`, at most `max`. */
export function parseUnsigned(text: string, max: number): number | null {
  if (!/^\+?[0-9]+$/.test(text)) return null;
  const value = Number(text);
  return value <= max ? value : null;
}

const UNRESERVED = "A-Za-z0-9\\-._~";
const SUB_DELIMS = "!$&'()*+,;=";
const PERCENT = "%[0-9A-Fa-f]{2}";
const component = (extra: string) => new RegExp(`^(?:[${UNRESERVED}${SUB_DELIMS}${extra}]|${PERCENT})*$`);
const USERINFO = component(":");
const REG_NAME = component("");
const PATH = component(":@/");
const QUERY = component(":@/?");
const IP_LITERAL = /^\[[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*\]$/;
const URL_SHAPE = /^([A-Za-z][A-Za-z0-9+.-]*):(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#([\s\S]*))?$/;

export interface ParsedURL {
  scheme: string;
  /** Without IPv6 brackets; null when the URL has no `//`. */
  host: string | null;
  path: string;
}

/** `URLComponents(string:)`: the URL's parts, or null when the text is no valid RFC 3986 URL. */
export function parseStrictURL(text: string): ParsedURL | null {
  const match = URL_SHAPE.exec(text);
  if (!match) return null;
  const [, scheme, authority, path, query, fragment] = match;
  if (!PATH.test(path) || (query != null && !QUERY.test(query)) || (fragment != null && !QUERY.test(fragment))) {
    return null;
  }
  if (authority == null) return { scheme, host: null, path };
  const at = authority.lastIndexOf("@");
  if (at >= 0 && !USERINFO.test(authority.slice(0, at))) return null;
  const hostPort = authority.slice(at + 1);
  let host: string;
  let port: string;
  if (hostPort.startsWith("[")) {
    const close = hostPort.indexOf("]");
    if (close < 0 || !IP_LITERAL.test(hostPort.slice(0, close + 1))) return null;
    host = hostPort.slice(1, close);
    const rest = hostPort.slice(close + 1);
    if (rest && !rest.startsWith(":")) return null;
    port = rest.slice(1);
  } else {
    const colon = hostPort.indexOf(":");
    host = colon < 0 ? hostPort : hostPort.slice(0, colon);
    port = colon < 0 ? "" : hostPort.slice(colon + 1);
    if (!REG_NAME.test(host)) return null;
  }
  if (!/^[0-9]*$/.test(port)) return null;
  return { scheme, host, path };
}

const encoder = new TextEncoder();

function percentEncode(text: string, keep: (character: string, index: number) => boolean): string {
  let result = "";
  for (let index = 0; index < text.length;) {
    const point = text.codePointAt(index) ?? 0;
    const character = String.fromCodePoint(point);
    if (point < 0x80 && keep(character, index)) {
      result += character;
    } else {
      for (const byte of encoder.encode(character)) result += `%${byte.toString(16).toUpperCase().padStart(2, "0")}`;
    }
    index += character.length;
  }
  return result;
}

const URL_CHARACTER = /^[A-Za-z0-9\-._~!$&'()*+,;=:@/?#[\]]$/;

/** `URL(string:)`: invalid characters percent-encoded, then parsed strictly. The URL text, or null. */
export function lenientURL(text: string): { text: string; parsed: ParsedURL } | null {
  const strict = parseStrictURL(text);
  if (strict) return { text, parsed: strict };
  const encoded = percentEncode(
    text,
    (character, index) =>
      URL_CHARACTER.test(character) || (character === "%" && /^[0-9A-Fa-f]{2}$/.test(text.slice(index + 1, index + 3))),
  );
  const parsed = parseStrictURL(encoded);
  return parsed ? { text: encoded, parsed } : null;
}

const isASCII = (text: string): boolean => Array.from(text).every((character) => character.charCodeAt(0) < 0x80);

/**
 * A host as IDNA gives it (UTS #46, the WHATWG URL parser's host step): an ASCII host unchanged,
 * a Unicode one in punycode (`例え.jp` is `xn--r8jz45g.jp`), or null when it has no ASCII form.
 */
export function asciiHost(host: string): string | null {
  if (isASCII(host)) return host;
  try {
    return new URL(`http://${host}/`).hostname || null;
  } catch {
    return null;
  }
}

const USERINFO_CHARACTER = new RegExp(`^[${UNRESERVED}${SUB_DELIMS}:]$`);
const PATH_COMPONENT_CHARACTER = new RegExp(`^[${UNRESERVED}${SUB_DELIMS}:@/]$`);
const QUERY_CHARACTER = new RegExp(`^[${UNRESERVED}${SUB_DELIMS}:@/?]$`);

/** Percent-encodes, as UTF-8, every character of `text` that `allowed` refuses; a valid `%XX` stays. */
const encodingInvalid = (text: string, allowed: RegExp): string =>
  percentEncode(
    text,
    (character, index) =>
      allowed.test(character) || (character === "%" && /^[0-9A-Fa-f]{2}$/.test(text.slice(index + 1, index + 3))),
  );

/**
 * `URLComponents(string:)` on macOS 14 and later: a Unicode host in punycode and each other
 * component's invalid characters percent-encoded, then parsed strictly (`https://例え.jp/café` is
 * `https://xn--r8jz45g.jp/caf%C3%A9`, `https://example.com/a|b` is `https://example.com/a%7Cb`).
 */
export function componentsURL(text: string): { text: string; parsed: ParsedURL } | null {
  const strict = parseStrictURL(text);
  if (strict) return { text, parsed: strict };
  const match = URL_SHAPE.exec(text);
  if (!match) return null;
  const [, scheme, authority, path, query, fragment] = match;
  let encoded = `${scheme}:`;
  if (authority != null) {
    const at = authority.lastIndexOf("@");
    const userinfo = at < 0 ? "" : `${encodingInvalid(authority.slice(0, at), USERINFO_CHARACTER)}@`;
    const hostPort = authority.slice(at + 1);
    const colon = hostPort.startsWith("[") ? hostPort.indexOf(":", hostPort.indexOf("]")) : hostPort.indexOf(":");
    const host = colon < 0 ? hostPort : hostPort.slice(0, colon);
    const ascii = host.startsWith("[") ? host : asciiHost(host);
    if (ascii == null) return null;
    encoded += `//${userinfo}${ascii}${colon < 0 ? "" : hostPort.slice(colon)}`;
  }
  encoded += encodingInvalid(path, PATH_COMPONENT_CHARACTER);
  if (query != null) encoded += `?${encodingInvalid(query, QUERY_CHARACTER)}`;
  if (fragment != null) encoded += `#${encodingInvalid(fragment, QUERY_CHARACTER)}`;
  const parsed = parseStrictURL(encoded);
  return parsed ? { text: encoded, parsed } : null;
}

const PATH_CHARACTER = /^[A-Za-z0-9\-._~!$&'()*+,;=:@/]$/;

/** `URL(filePath:).absoluteString` for an absolute path. */
export function fileURL(path: string): string {
  return `file://${percentEncode(path, (character) => PATH_CHARACTER.test(character))}`;
}
