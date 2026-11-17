"use client";

import { useEffect } from "react";

/**
 * A desktop Mac: the only browser that can open a `cmux://` link. iPhone and
 * iPad Safari show an "address is invalid" alert for it (the iOS app registers
 * its own scheme), and iPadOS reports a Mac user agent, so touch points tell
 * it apart.
 */
export function canAutoOpen(nav: Pick<Navigator, "userAgent" | "maxTouchPoints">): boolean {
  return /Macintosh/.test(nav.userAgent) && nav.maxTouchPoints <= 1;
}

/** Navigates `win` to `href` when it is a browser that can open it; what AutoOpen runs on load. */
export function openOnLoad(
  href: string,
  win: {
    navigator: Pick<Navigator, "userAgent" | "maxTouchPoints">;
    location: { href: string };
  },
): void {
  if (canAutoOpen(win.navigator)) win.location.href = href;
}

/**
 * Hands the native link to the app as soon as the page loads, the way a chat
 * app's invite page opens the app: a click on a cmux.com link lands in cmux, and the
 * page stays behind as the fallback (Open button, download, native URL) for a
 * browser with no cmux to open it. It only ever opens the href the page itself
 * validated and would put on its Open button, so it adds nothing a click on that
 * button would not do.
 */
export function AutoOpen({ href }: { href: string }) {
  useEffect(() => {
    openOnLoad(href, window);
  }, [href]);
  return null;
}
