"use client";

import { useEffect, useRef } from "react";
import { useSearchParams } from "next/navigation";
import { hostedSignInAttempt, startHostedSignInPage, type HostedSignInPageShown } from "./sign-in-analytics";

/** This page's opted-in attempt id, or null. */
export function useHostedSignInAttempt(): string | null {
  return hostedSignInAttempt(useSearchParams());
}

/**
 * Reports the page load and its first interaction (see
 * `startHostedSignInPage`). A page view has no event handler to hang on, so
 * this is the one effect; it reads its inputs only on the first run and
 * removes its listeners on unmount.
 */
export function useHostedSignInPageShown(step: HostedSignInPageShown) {
  const attempt = useHostedSignInAttempt();
  const first = useRef({ attempt, step });
  useEffect(() => startHostedSignInPage(first.current.attempt, first.current.step, document), []);
}
