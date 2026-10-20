// A web link the person clicks in Home opens on the right side of the Home workspace (hq-6d
// Home workspace design, cx-ebm.59.4; Lawrence 2026-10-14: "if i click links that chief gives
// me, it should open on the right side as well"). The daemon owns the rule
// (`workspace.open_url`: reuse a browser tab on the right, never the docked chat; with no
// workspace named, the session's Home workspace), so every host (the app, a plain browser,
// Chromium, GPUI) gets the same result. A daemon without the operation, or one that cannot open a
// browser engine gets the click as before: the page only takes a click when the daemon names the
// operation's capability (`workspace-open-url-v1` in `identify`). The daemon takes the operation
// from a page only with the person's confirmation, so the handler is installed only where the host
// relays the click with one (not yet: cx-ebm.59.6).
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

/** The capability that names `workspace.open_url` (cmux-tui spec, resource-operations-v2.json). */
export const OPEN_URL_CAPABILITY = "workspace-open-url-v1";

/** The capture-phase click handler of the Home page root: a web link goes to the Home workspace's
 *  right side once the daemon says it has the operation; until then, and on an older daemon, the
 *  click is left to the host. A second click of a double click is the same open, so it is dropped. */
export function homeLinkClickHandler(daemon: DaemonSocket): (event: MouseEvent) => void {
  let supported = false;
  void daemon
    .request<{ capabilities?: unknown }>("identify")
    .then((identity) => {
      supported = Array.isArray(identity.capabilities) && identity.capabilities.includes(OPEN_URL_CAPABILITY);
    })
    .catch(() => {});
  return (event) => {
    if (!supported) return;
    const url = clickedWebLink(event);
    if (!url) return;
    event.preventDefault();
    if (event.detail > 1) return;
    void openOnHomeRight(daemon, url);
  };
}
