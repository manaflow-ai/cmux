// A web link the person clicks in Home opens on the right side of the Home workspace (hq-6d
// Home workspace design, cx-ebm.59.4; Lawrence 2026-10-14: "if i click links that chief gives
// me, it should open on the right side as well"). The daemon owns the rule
// (`workspace.open_url`: reuse a browser tab on the right, never the docked chat; with no
// workspace named, the session's Home workspace), so every host (the app, a plain browser,
// Chromium, GPUI) gets the same result. A daemon without the operation, or one that cannot open a
// browser, leaves the click to the host as before.
import type { DaemonSocket } from "../shared/daemonSocket";

/** An http(s) link the click landed on, when it is the person's own plain click. */
export function clickedWebLink(event: MouseEvent): string | null {
  if (!event.isTrusted || event.defaultPrevented || event.button !== 0) return null;
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return null;
  const anchor = (event.target as Element | null)?.closest?.("a[href]");
  if (!(anchor instanceof HTMLAnchorElement)) return null;
  const href = anchor.href;
  return /^https?:\/\/[^/?#\s]/i.test(href) ? href : null;
}

/** Opens `url` on the right side of the Home workspace; false when the daemon did not. */
export async function openOnHomeRight(daemon: DaemonSocket, url: string): Promise<boolean> {
  const key = `home-link-${globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`}`;
  try {
    await daemon.operation("workspace.open_url", { machine: "current", session: "current", url }, key);
    return true;
  } catch (error) {
    console.warn("workspace.open_url", error);
    return false;
  }
}

/** The capture-phase click handler of the Home page root: a web link goes to the Home
 *  workspace's right side; when the daemon cannot, the page opens it as a new window, which the
 *  host handles like any outside link. */
export function homeLinkClickHandler(daemon: DaemonSocket): (event: MouseEvent) => void {
  return (event) => {
    const url = clickedWebLink(event);
    if (!url) return;
    event.preventDefault();
    void openOnHomeRight(daemon, url).then((opened) => {
      if (!opened) window.open(url, "_blank", "noopener,noreferrer");
    });
  };
}
