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
 * On the sign-in recovery page: if a remembered account was just sent
 * straight to its provider and that ended here, it opens the full sign-in
 * options next time instead of repeating the same provider. A failed OAuth
 * return is redirected here on the server, so the callback page's own
 * handling never runs for it.
 */
export function DemoteFailedProvider() {
  useEffect(() => {
    try {
      const accountId = parsePendingOAuth(window.localStorage.getItem(PENDING_OAUTH_KEY));
      if (!accountId) return;
      const history = parseAccountHistory(window.localStorage.getItem(ACCOUNT_HISTORY_KEY));
      window.localStorage.setItem(ACCOUNT_HISTORY_KEY, JSON.stringify(demoteRememberedMethod(history, accountId)));
      window.localStorage.removeItem(PENDING_OAUTH_KEY);
    } catch {
      // The remembered list is a convenience; the page works without it.
    }
  }, []);
  return null;
}
