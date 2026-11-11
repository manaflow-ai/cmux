"use client";

import { useEffect } from "react";

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
    window.location.href = href;
  }, [href]);
  return null;
}
