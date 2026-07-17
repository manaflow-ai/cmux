"use client";

import { useEffect, useState } from "react";
import { useUser } from "@stackframe/stack";

/**
 * Resolves the current Stack access token once per user session. Narrow
 * effect contract: async token fetch tied to the user identity.
 */
export function useAccessToken(): string | null {
  const user = useUser();
  const [token, setToken] = useState<string | null>(null);
  const userId = user?.id ?? null;

  useEffect(() => {
    if (!user) return;
    let cancelled = false;
    void user.currentSession
      .getTokens()
      .then(({ accessToken }) => {
        if (!cancelled) setToken(accessToken);
      })
      .catch(() => {
        if (!cancelled) setToken(null);
      });
    return () => {
      cancelled = true;
    };
    // `user` object identity churns per render in the Stack SDK; the
    // session is keyed by user id.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId]);

  return user ? token : null;
}
