"use client";

import { useEffect, useRef } from "react";
import { useSearchParams } from "next/navigation";
import { hostedSignInAttempt, reportHostedSignInStep, type HostedSignInStep } from "./sign-in-analytics";

/** This page's opted-in attempt id, or null. */
export function useHostedSignInAttempt(): string | null {
  return hostedSignInAttempt(useSearchParams());
}

/**
 * Reports `cmux_sign_in_page_shown` once per page load, with the screen the
 * page opened on. A page view has no event handler to hang on, so this is
 * the one effect; it reads its inputs only on the first run.
 */
export function useHostedSignInPageShown(step: Extract<HostedSignInStep, { event: "cmux_sign_in_page_shown" }>) {
  const attempt = useHostedSignInAttempt();
  const first = useRef({ attempt, step });
  useEffect(() => {
    const { attempt: openedAttempt, step: openedStep } = first.current;
    if (!openedAttempt || reportedPageLoads.has(openedAttempt)) return;
    reportedPageLoads.add(openedAttempt);
    reportHostedSignInStep(openedAttempt, openedStep);
    // The first pointer or key press anywhere on the page, once: it tells
    // "the person did something" apart from "nothing measured happened",
    // without saying what or where.
    const controller = new AbortController();
    const interacted = () => {
      controller.abort();
      reportHostedSignInStep(openedAttempt, { event: "cmux_sign_in_page_interacted" });
    };
    for (const type of ["pointerdown", "keydown"] as const) {
      document.addEventListener(type, interacted, { capture: true, passive: true, signal: controller.signal });
    }
  }, []);
}

/** Attempts already reported on this page load (Strict Mode runs effects twice). */
const reportedPageLoads = new Set<string>();
