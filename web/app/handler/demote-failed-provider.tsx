"use client";

import { useEffect } from "react";
import {
  ACCOUNT_HISTORY_KEY,
  PENDING_OAUTH_KEY,
  demoteRememberedMethod,
  parseAccountHistory,
  parsePendingOAuth,
} from "./sign-in-entry";

/**
 * On the sign-in recovery page. If this tab had just sent a remembered
 * account straight to its provider (`demote`), that attempt ended here, so
 * the account opens the full sign-in options next time instead of repeating
 * the provider. A failed OAuth return is redirected here on the server, so
 * the callback page's own handling never runs for it. Either way the marker
 * is cleared, so a later, unrelated error can't act on it.
 */
export function DemoteFailedProvider({ demote }: { demote: boolean }) {
  useEffect(() => {
    try {
      const accountId = parsePendingOAuth(window.sessionStorage.getItem(PENDING_OAUTH_KEY));
      window.sessionStorage.removeItem(PENDING_OAUTH_KEY);
      if (!accountId || !demote) return;
      const history = parseAccountHistory(window.localStorage.getItem(ACCOUNT_HISTORY_KEY));
      window.localStorage.setItem(ACCOUNT_HISTORY_KEY, JSON.stringify(demoteRememberedMethod(history, accountId)));
    } catch {
      // The remembered list is a convenience; the page works without it.
    }
  }, [demote]);
  return null;
}
