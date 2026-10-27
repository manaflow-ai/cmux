import { AGENT_SESSION_TOKEN } from "./links";

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

/// A cmux app link (`cmux://workspace/ws_…`, `pane/pane_…`, `tab/tab_…`, `session/<id>`,
/// `chief/<home>/session/<id>`, `agent/<harness>/<session>?host=&name=`) in this build's scheme or the plain `cmux` one: drawn as a link,
/// and a click goes to the host, which opens it inside the app (`link.open`) and never in another
/// app. The host checks the ids again (DeepLink.parse); this only keeps every other scheme
/// (`javascript:`, `file:`, `data:`, `ssh:`...) as text.
export function appHref(href: string): string | undefined {
  const text = href.trim();
  const authority = /^cmux(-[a-z0-9-]+)?:\/\//;
  const rest = text.slice(text.indexOf("://") + 3);
  const ordinary = /^(workspace|pane|tab|session|chief)\/[A-Za-z0-9._~/-]+(\?[A-Za-z0-9._~=&-]+)?(#[A-Za-z0-9._~-]+)?$/;
  const agent = /^agent\/[a-z0-9-]{1,64}\/([^/?#]+)(\?[A-Za-z0-9._~=&-]+)?$/;
  const agentMatch = rest.match(agent);
  const isAgent = agentMatch !== null && AGENT_SESSION_TOKEN.test(agentMatch[1]);
  if (!authority.test(text) || !(ordinary.test(rest) || isAgent)) return undefined;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return undefined;
  }
  if (url.username || url.password || url.port) return undefined;
  return text;
}

/// A link target the reply draws as a link: a web link (``safeHref``) or a cmux app link (``appHref``).
export function linkHref(href: string): string | undefined {
  return safeHref(href) ?? appHref(href);
}
