/// A link target from untrusted text (a reply, a tool's output) that the page may draw as a link:
/// an absolute http or https URL with no user name or password, returned in its parsed form, so
/// the link opens exactly what was checked. Anything else draws as text: a relative target
/// (`README.md`, `../`, `?x`, `#x`, `//host`) resolves against the pane's own page and would
/// navigate it away, and a URL with credentials in it is a phishing shape.
export function safeHref(href: string): string | undefined {
  if (!/^https?:/i.test(href.trim())) return undefined;
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return undefined;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return undefined;
  if (url.username || url.password || !url.hostname) return undefined;
  return url.href;
}
