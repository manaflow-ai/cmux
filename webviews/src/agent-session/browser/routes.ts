// Browser navigation is a view of the existing chat route. Resolution and authorization stay
// with acpmux; a link never supplies a transport endpoint or a device credential.
import { cmuxLinkTarget } from "../acpmux/conversation/cmuxLinks";

export type BrowserChatRoute = { session: string; message?: string; turn?: string };

const SESSION = /^(?!\.+$)[A-Za-z0-9._:-]{1,256}$/;
const PEER_SESSION = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\/(?!\.+$)[A-Za-z0-9._:-]{1,256}$/;
const ROW = /^(?!\.+$)[A-Za-z0-9._-]{1,200}$/;
const MACHINE = /^machine_[0-9a-f]{32}$/;

function single(params: URLSearchParams, key: string): string | undefined {
  const values = params.getAll(key);
  return values.length === 1 ? values[0] : undefined;
}

function row(params: URLSearchParams, key: string): string | undefined {
  const value = single(params, key);
  return value && ROW.test(value) ? value : undefined;
}

function sessionRoute(value: string): BrowserChatRoute | undefined {
  if (SESSION.test(value) || PEER_SESSION.test(value)) return { session: value };
  const target = cmuxLinkTarget(value);
  if (target?.kind === "session") return { session: target.session, ...(target.turn && { turn: target.turn }) };
  if (target?.kind !== "agent") return undefined;

  // Rebuild from the shared parser's routing fields. Do not copy unknown query parameters or
  // fragments (notably the listener's launch token) to history, the resolver or another link.
  const params = new URLSearchParams();
  if (target.opaque) params.set("id", target.opaque);
  else if (target.harness && target.session) {
    params.set("harness", target.harness);
    params.set("session", target.session);
  } else if (target.session) {
    // The resolver accepts a harness-free link by its session id, as sessionRefs.agentRef does.
    const query = new URL(value.replace(/&amp;/g, "&")).searchParams;
    const message = row(query, "message");
    return { session: target.session, ...(message && { message }) };
  } else return undefined;
  if (target.host) params.set("host", target.host);
  if (target.name) params.set("name", target.name);
  const query = new URL(value.replace(/&amp;/g, "&")).searchParams;
  const machine = single(query, "machine");
  if (machine && MACHINE.test(machine)) params.set("machine", machine);
  const message = row(query, "message");
  return {
    session: `https://cmux.com/deeplink/agent?${params}`,
    ...(message && { message }),
  };
}

/** A session key, native chat link, public agent link, or this listener's /app/ URL. */
export function browserChatRoute(href: string, baseURL: string): BrowserChatRoute | undefined {
  if (!href || href.length > 4096 || href.trim() !== href) return undefined;
  const direct = sessionRoute(href);
  if (direct) return direct;
  let url: URL;
  let base: URL;
  try {
    base = new URL(baseURL);
    url = new URL(href, base);
  } catch {
    return undefined;
  }
  if (url.origin !== base.origin || url.username || url.password || !/^\/app\/?$/.test(url.pathname)) return undefined;
  const session = single(url.searchParams, "session");
  if (!session) return undefined;
  const route = sessionRoute(session);
  if (!route) return undefined;
  const message = row(url.searchParams, "message") ?? route.message;
  const turn = row(url.searchParams, "turn") ?? route.turn;
  return { session: route.session, ...(message && { message }), ...(turn && { turn }) };
}

/** A shareable listener-relative URL, with routing fields only. */
export function browserChatHref(route: BrowserChatRoute): string {
  const params = new URLSearchParams({ session: route.session });
  if (route.message) params.set("message", route.message);
  if (route.turn) params.set("turn", route.turn);
  return `/app/?${params}`;
}

/** The shell's chat.select and link.open handlers share this navigation path. */
export function installBrowserNavigation(
  select: (route: BrowserChatRoute | undefined) => void,
  browser: Window = window,
): { navigate: (href: string) => boolean; dispose: () => void } {
  const read = () => {
    const route = browserChatRoute(browser.location.href, browser.location.href);
    // The shell has already consumed the launch token. Canonicalize the entry too, so going
    // Back never restores auth or transport fields from a pasted URL.
    if (route) browser.history.replaceState(null, "", browserChatHref(route));
    select(route);
  };
  const navigate = (href: string): boolean => {
    const route = browserChatRoute(href, browser.location.href);
    if (!route) return false;
    const next = browserChatHref(route);
    if (`${browser.location.pathname}${browser.location.search}` !== next || browser.location.hash)
      browser.history.pushState(null, "", next);
    select(route);
    return true;
  };
  const click = (event: MouseEvent) => {
    if (
      event.defaultPrevented ||
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    )
      return;
    const anchor = event.composedPath().find((node) => node instanceof Element && node.matches("a[href]")) as
      | HTMLAnchorElement
      | undefined;
    if (!anchor || anchor.hasAttribute("download") || (anchor.target && anchor.target !== "_self")) return;
    if (!navigate(anchor.href)) return;
    event.preventDefault();
    event.stopPropagation();
  };
  browser.addEventListener("popstate", read);
  browser.document.addEventListener("click", click, true);
  read();
  return {
    navigate,
    dispose: () => {
      browser.removeEventListener("popstate", read);
      browser.document.removeEventListener("click", click, true);
    },
  };
}
