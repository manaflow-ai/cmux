"use client";

import { useEffect } from "react";
import { forgetAllSessions } from "./account-sessions-client";

/**
 * On the hosted sign-out page: signing out ends every account this browser
 * keeps for switching, as the dashboard's sign-out does. It sits outside the
 * page's loading boundary, so it starts before the sign-out redirects away.
 */
export function EndSavedSessions() {
  useEffect(() => {
    void forgetAllSessions({ keepalive: true });
  }, []);
  return null;
}
