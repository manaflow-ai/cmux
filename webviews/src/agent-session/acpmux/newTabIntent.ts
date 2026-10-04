/// What the new tab field's text means (plans/cmux-next/new-tab.md section 3.1). Pure and
/// synchronous, so the page decides on every keystroke. The Swift `NewTabIntent` (CLI, MCP)
/// implements the same rules; `webviews/test/fixtures/new-tab-intents.json` is the table both
/// pass.

/// Search | Ask: what plain text does. A command or an address ignores it.
export type NewTabMode = "search" | "ask";

export type NewTabIntent =
  | { kind: "none" }
  /// `!` first: the tab becomes a terminal, `command` typed (not run) at its prompt.
  | { kind: "terminal"; command: string }
  /// An address the browser loads.
  | { kind: "url"; url: string }
  /// Plain text in Ask mode: a prompt for an agent.
  | { kind: "prompt"; text: string }
  /// Plain text in Search mode: a web search.
  | { kind: "search"; text: string };

export type NewTabIntentOptions = {
  /// The user's home folder, for `~` and `~/path`; without it those are text.
  home?: string;
};

/// The leading character that turns the tab into a terminal.
export const TERMINAL_PREFIX = "!";

/// File extensions that are also top-level domains or look like one. A bare `name.ext` with one
/// of these is text (Q4); a scheme, `www.`, a port or a path makes it an address.
const FILE_EXTENSIONS = new Set([
  "c", "cc", "cfg", "cjs", "conf", "cpp", "cs", "css", "csv", "dart", "env", "ex", "exs", "gif", "go",
  "gradle", "gz", "h", "hpp", "html", "ini", "java", "jpeg", "jpg", "js", "json", "jsx", "kt", "lock",
  "log", "lua", "md", "mdx", "mjs", "mts", "nix", "pdf", "php", "pl", "plist", "png", "py", "rb", "rs",
  "scss", "sh", "sql", "svelte", "svg", "swift", "tar", "toml", "ts", "tsx", "txt", "vue", "xml",
  "yaml", "yml", "zig", "zip", "zsh",
]);

export function classifyNewTabInput(input: string, mode: NewTabMode, options: NewTabIntentOptions = {}): NewTabIntent {
  const trimmed = input.trim();
  if (!trimmed) return { kind: "none" };
  if (trimmed.startsWith(TERMINAL_PREFIX)) return { kind: "terminal", command: trimmed.slice(1).trim() };
  const url = newTabURL(trimmed, options.home);
  if (url) return { kind: "url", url };
  return mode === "ask" ? { kind: "prompt", text: trimmed } : { kind: "search", text: trimmed };
}

/// The address to load for `text`, or undefined for text. BrowserURLResolver's rules (WebKit
/// tabs: no `chrome://`), then the file-name filter.
export function newTabURL(input: string, home?: string): string | undefined {
  const trimmed = input.trim();
  if (!trimmed) return undefined;
  const text = removingWrapBreaks(trimmed);
  if (text === undefined) return undefined;
  const file = fileURL(text, home);
  if (file !== undefined) return file;
  if (/\s/u.test(text)) return undefined;
  const scheme = explicitScheme(text);
  if (scheme !== undefined) return explicitURL(text, scheme);
  if (looksLikeFileName(text)) return undefined;
  return schemeLessURL(text);
}

/// The text with wrap breaks from a terminal paste removed when every break comes after the
/// host ended; unchanged without breaks; undefined when a break sits inside the host.
function removingWrapBreaks(text: string): string | undefined {
  const firstBreak = text.search(/[\n\r\t]/);
  if (firstBreak < 0) return text;
  const scheme = text.indexOf("://");
  const authorityStart = scheme < 0 ? 0 : scheme + 3;
  if (authorityStart > firstBreak) return undefined;
  const after = text.slice(authorityStart).search(/[/?#]/);
  if (after < 0 || authorityStart + after >= firstBreak) return undefined;
  const compacted = text.replace(/[\n\r\t]/g, "");
  return /\s/u.test(compacted) ? undefined : compacted;
}

function fileURL(text: string, home?: string): string | undefined {
  if (text.startsWith("/")) return "file://" + encodePath(text);
  if (!home || (text !== "~" && !text.startsWith("~/"))) return undefined;
  const base = home.endsWith("/") ? home : home + "/";
  return "file://" + encodePath(text === "~" ? base : base + text.slice(2));
}

const encodePath = (path: string) => path.split("/").map(encodeURIComponent).join("/");

const isPort = (text: string) => /^[0-9]+$/.test(text) && Number(text) <= 65535;

/// The scheme when the text starts with one. `localhost:3000` and `example.com:8080/x` are a
/// host and port, not a scheme.
function explicitScheme(text: string): string | undefined {
  const colon = text.indexOf(":");
  if (colon < 0) return undefined;
  const candidate = text.slice(0, colon);
  if (!/^\p{L}[\p{L}\p{N}+.-]*$/u.test(candidate)) return undefined;
  const after = text.slice(colon + 1);
  const port = /^[0-9]*/.exec(after)![0];
  if (port && !after.startsWith("//")) {
    const rest = after.slice(port.length);
    if (!rest || "/?#".includes(rest[0]!)) return undefined;
  }
  return candidate.toLowerCase();
}

function explicitURL(text: string, scheme: string): string | undefined {
  switch (scheme) {
    case "http":
    case "https":
      return hostOf(text) ? text : undefined;
    case "file":
      return /^file:\/\/\//i.test(text) ? text : undefined;
    case "about":
      return text.toLowerCase() === "about:blank" ? "about:blank" : undefined;
    default:
      return undefined;
  }
}

/// The host of `scheme://host...`, or "" when there is none.
function hostOf(text: string): string {
  const match = /^[^:]+:\/\/([^/?#]*)/.exec(text);
  if (!match) return "";
  const authority = match[1]!.replace(/^[^@]*@/, "");
  return authority.startsWith("[") ? authority.slice(1, authority.indexOf("]")) : authority.replace(/:[0-9]*$/, "");
}

function schemeLessURL(text: string): string | undefined {
  const end = text.search(/[/?#]/);
  const authority = end < 0 ? text : text.slice(0, end);
  if (!authority || authority.includes("@")) return undefined;
  const { host, hasPort } = splitHostAndPort(authority);
  if (!host) return undefined;
  if (isLoopback(host)) return "http://" + text;
  if (hasPort || isDottedHost(host)) return "https://" + text;
  return undefined;
}

/// Lowercased host (IPv6 brackets stripped) and whether a numeric port follows. A non-numeric
/// port gives an empty host.
function splitHostAndPort(authority: string): { host: string; hasPort: boolean } {
  const lower = authority.toLowerCase();
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

/// `localhost`, `*.localhost`, `127.0.0.0/8`, `::1` and `0.0.0.0`.
function isLoopback(host: string): boolean {
  if (host === "localhost" || host.endsWith(".localhost") || host === "::1" || host === "0.0.0.0") return true;
  const octets = host.split(".");
  return octets.length === 4 && octets[0] === "127" && octets.every(isOctet);
}

const isOctet = (label: string) => /^[0-9]+$/.test(label) && Number(label) <= 255;

/// Two or more labels whose last looks like a TLD (letters, or a numeric IPv4 address).
function isDottedHost(host: string): boolean {
  const labels = host.split(".");
  if (labels.length < 2 || labels.some((label) => !label)) return false;
  if (labels.length === 4 && labels.every(isOctet)) return true;
  const tld = labels[labels.length - 1]!;
  return /^\p{L}{2,}$/u.test(tld) || tld.startsWith("xn--");
}

/// `node.js`, `readme.md`: one token, no port, no path, no `www.`, ending in a file extension.
function looksLikeFileName(text: string): boolean {
  if (/[/?#:]/.test(text)) return false;
  const lower = text.toLowerCase();
  if (lower.startsWith("www.")) return false;
  const dot = lower.lastIndexOf(".");
  return dot > 0 && FILE_EXTENSIONS.has(lower.slice(dot + 1));
}
