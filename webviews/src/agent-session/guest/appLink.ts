// Open a share link in the cmux app first (Leo, 2026-11-07: "if somebody has the app itself, it
// should be able to redirect them to the desktop app for sharing ... by default"). The guest page
// asks the app's URL scheme to open the link, `<scheme>://share?link=<page URL>#<secret>`: the
// secret moves only inside that URL's fragment, handed by the browser to the operating system,
// never to a server. The app opens the page in its own web view signed in as the person's cmux
// account (the platform's hand-off, `?cmux_handoff=`) and marks it `?in_app=1`, where this step is
// skipped. Without the app nothing opens, and the page carries on as before.

/**
 * The app a link opens when it names none: cmux NEXT ships as cmux NIGHTLY, which registers
 * `cmux-nightly`. A link another build made names its own scheme in `?app=` (the daemon's
 * `set_link_share_app_scheme`, from the scheme that build registers), so the page keeps no list.
 */
export const DEFAULT_APP_SCHEME = "cmux-nightly";

/**
 * A cmux build's own scheme (`cmux`, `cmux-nightly`, `cmux-dev-<tag>`, or a bundle's `cmux.<name>`): `?app=` may
 * name one. The daemon's `is_cmux_scheme` (agent_session_share_link.rs) reads the same grammar.
 */
const CMUX_SCHEME = /^cmux(?:[-.][a-z0-9]+)*$/;

/** How long the page waits for the app to take the link before it carries on in the browser. */
export const APP_OPEN_WAIT_MS = 1500;

export type AppLinkTarget = { shareId: string; secret?: string; invite?: boolean };

/** The app's scheme for this page: the link's `?app=`, else the default; none off https (a local page). */
export function appScheme(location: Pick<Location, "protocol" | "search">): string | undefined {
  const asked = new URLSearchParams(location.search).get("app");
  if (asked && CMUX_SCHEME.test(asked)) return asked;
  return location.protocol === "https:" ? DEFAULT_APP_SCHEME : undefined;
}

/** The app URL for a link: the page's own address in `link` (no secret), the secret in the fragment. */
export function appLinkUrl(scheme: string, origin: string, target: AppLinkTarget): string {
  const page = `${origin}/${target.invite ? "i" : "g"}/${encodeURIComponent(target.shareId)}`;
  const fragment = !target.invite && target.secret ? `#${target.secret}` : "";
  return `${scheme}://share?link=${encodeURIComponent(page)}${fragment}`;
}

const browserKey = (shareId: string) => `cmux.guest.${shareId}.browser`;

/** Remembers, for this tab, that the visitor chose the browser for this share: a reload asks no more. */
export function chooseBrowser(storage: Storage, shareId: string): void {
  try {
    storage.setItem(browserKey(shareId), "1");
  } catch {
    // Storage off: the choice holds until a reload.
  }
}

/**
 * Whether the page first asks the app to open the link: not inside the app (`in_app=1`), not where no
 * app scheme fits, not after the visitor chose the browser, and not once this tab has joined.
 */
export function offersApp(
  location: Pick<Location, "protocol" | "search">,
  storage: Storage,
  shareId: string,
  joined: boolean,
): boolean {
  if (!shareId || joined) return false;
  if (new URLSearchParams(location.search).get("in_app") === "1") return false;
  if (!appScheme(location)) return false;
  try {
    return storage.getItem(browserKey(shareId)) !== "1";
  } catch {
    return true;
  }
}

/** The bits of a window an app attempt reads; tests pass a fake. */
export type AppOpenWindow = {
  location: { assign(url: string): void };
  document: { visibilityState: DocumentVisibilityState };
  addEventListener(type: "visibilitychange" | "pagehide", listener: () => void): void;
  removeEventListener(type: "visibilitychange" | "pagehide", listener: () => void): void;
  setTimeout(handler: () => void, ms: number): number;
  clearTimeout(id: number): void;
};

/**
 * Asks the operating system to open `url` and answers whether the app took it: the page was hidden within
 * `waitMs` (`visibilitychange` to hidden, or `pagehide`, as when an app handler takes over the screen), else
 * `false`. A blur alone is not proof (the visitor may only have switched windows), and whatever this answers,
 * the card keeps "Continue in browser", so a wrong guess strands no one. The one timer and both listeners are
 * removed when it settles.
 */
export function tryOpenApp(
  win: AppOpenWindow,
  url: string,
  waitMs = APP_OPEN_WAIT_MS,
  signal?: AbortSignal,
): Promise<boolean> {
  if (win.document.visibilityState !== "hidden") return attempt(win, url, waitMs);
  // An unmount between the page showing and this callback still ends it: `shown` alone is not enough.
  return whenVisible(win, signal).then((shown) => (shown && !signal?.aborted ? attempt(win, url, waitMs) : false));
}

/**
 * A page opened hidden (a background tab) asks nothing until it is shown: hidden is the only proof the app took
 * the link, so an attempt from a hidden page would always look taken. Answers true when shown, false when
 * `signal` ends the wait first (the card unmounted), so a page restored later from the back-forward cache never
 * asks for a card that is gone. The one listener goes either way.
 */
function whenVisible(win: AppOpenWindow, signal?: AbortSignal): Promise<boolean> {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve(false);
    const end = (shown: boolean) => {
      win.removeEventListener("visibilitychange", changed);
      signal?.removeEventListener("abort", aborted);
      resolve(shown);
    };
    const changed = () => {
      if (win.document.visibilityState !== "hidden") end(true);
    };
    const aborted = () => end(false);
    win.addEventListener("visibilitychange", changed);
    signal?.addEventListener("abort", aborted);
  });
}

function attempt(win: AppOpenWindow, url: string, waitMs: number): Promise<boolean> {
  return new Promise((resolve) => {
    let settled = false;
    const settle = (opened: boolean) => {
      if (settled) return;
      settled = true;
      win.clearTimeout(timer);
      win.removeEventListener("visibilitychange", changed);
      win.removeEventListener("pagehide", left);
      resolve(opened);
    };
    const changed = () => {
      if (win.document.visibilityState === "hidden") settle(true);
    };
    const left = () => settle(true);
    win.addEventListener("visibilitychange", changed);
    win.addEventListener("pagehide", left);
    const timer = win.setTimeout(() => settle(win.document.visibilityState === "hidden"), waitMs);
    try {
      win.location.assign(url);
    } catch {
      settle(false);
    }
  });
}
