"use client";

import posthog from "posthog-js";

// Website analytics are off until the visitor turns them on (Leo: "whatever we
// do, we need to make sure it's opt out by defautl"). Until the visitor accepts
// in the consent banner, `posthog.init` never runs: no PostHog cookie or
// localStorage entry is written, no identify, no capture, no autocapture and no
// pageview. Calls such as `posthog.capture` on the uninitialized client are
// no-ops in posthog-js. Declining later opts the client out and clears what it
// stored.

/** The site's public PostHog project key (it is in every page's bundle). */
export const POSTHOG_PROJECT_KEY = "phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP";
/** The first-party PostHog proxy. */
export const POSTHOG_API_HOST = "https://r.cmux.com";

/** localStorage key holding the visitor's choice: "granted" or "denied". */
export const ANALYTICS_CONSENT_STORAGE_KEY = "cmux.analytics-consent";
/** Window event fired when the choice changes, in this tab. */
export const ANALYTICS_CONSENT_CHANGED_EVENT = "cmux:analytics-consent-changed";

export type AnalyticsConsent = "granted" | "denied";

/** posthog.init ran in this page (it cannot be undone, only opted out). */
let loaded = false;
/** The visitor accepted, in this page. */
let granted = false;

/** The visitor's stored choice, or null when they have not chosen (analytics off). */
export function readAnalyticsConsent(): AnalyticsConsent | null {
  if (typeof window === "undefined") return null;
  try {
    const value = window.localStorage.getItem(ANALYTICS_CONSENT_STORAGE_KEY);
    return value === "granted" || value === "denied" ? value : null;
  } catch {
    return null;
  }
}

/** Whether PostHog is running in this page: only after the visitor accepted. */
export function analyticsEnabled(): boolean {
  return loaded && granted;
}

function initAnalytics() {
  if (typeof window === "undefined") return;
  granted = true;
  if (loaded) {
    // Accepted again after declining in this page.
    if (posthog.has_opted_out_capturing()) posthog.opt_in_capturing();
    return;
  }
  loaded = true;
  posthog.init(POSTHOG_PROJECT_KEY, {
    api_host: POSTHOG_API_HOST,
    ui_host: "https://us.posthog.com",
    person_profiles: "identified_only",
    capture_pageview: false,
    capture_pageleave: true,
    advanced_disable_feature_flags: true,
    // The default target inserts before the first `body > script`, which is a
    // React-owned JSON-LD tag in the locale layout. When this module loads
    // before hydration, that insertion fails hydration for the whole page.
    external_scripts_inject_target: "head",
    // The route tracker opens this gate only after resolving the current
    // server-authenticated identity.
    before_send: () => null,
  });
}

const POSTHOG_COOKIE = /^(ph_|__ph_opt_in_out_)/;

function clearStoredAnalytics() {
  try {
    for (const key of Object.keys(window.localStorage)) {
      if (POSTHOG_COOKIE.test(key)) window.localStorage.removeItem(key);
    }
    for (const key of Object.keys(window.sessionStorage)) {
      if (POSTHOG_COOKIE.test(key)) window.sessionStorage.removeItem(key);
    }
  } catch {
    // Storage may be unavailable; nothing was stored there then.
  }
  for (const cookie of document.cookie.split(";")) {
    const name = cookie.split("=")[0]?.trim();
    if (!name || !POSTHOG_COOKIE.test(name)) continue;
    const expired = `${name}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/`;
    document.cookie = expired;
    document.cookie = `${expired}; domain=${window.location.hostname}`;
    const parent = window.location.hostname.split(".").slice(-2).join(".");
    document.cookie = `${expired}; domain=.${parent}`;
  }
}

/**
 * Record the visitor's choice. Accepting starts PostHog; declining stops it and
 * clears what it stored. null forgets the choice, so the notice asks again;
 * analytics stay off meanwhile.
 */
export function setAnalyticsConsent(consent: AnalyticsConsent | null) {
  try {
    if (consent) window.localStorage.setItem(ANALYTICS_CONSENT_STORAGE_KEY, consent);
    else window.localStorage.removeItem(ANALYTICS_CONSENT_STORAGE_KEY);
  } catch {
    // Without storage the choice lasts for this page only.
  }
  if (consent === "granted") {
    initAnalytics();
  } else {
    granted = false;
    if (loaded) {
      posthog.opt_out_capturing();
      posthog.reset();
    }
    clearStoredAnalytics();
  }
  window.dispatchEvent(new Event(ANALYTICS_CONSENT_CHANGED_EVENT));
}

if (typeof window !== "undefined" && readAnalyticsConsent() === "granted") {
  initAnalytics();
}

let openAnalyticsGate: () => void = () => {};
const analyticsGate = new Promise<void>((resolve) => {
  openAnalyticsGate = resolve;
});

/**
 * Resolves once the route tracker buffers captures instead of the initial
 * `before_send` dropping them. Captures sent before this are discarded. It
 * never resolves for a visitor who has not accepted analytics.
 */
export function whenAnalyticsCaptureBuffered(): Promise<void> {
  return analyticsGate;
}

/** Called by the route tracker after it installs its capture buffer. */
export function markAnalyticsCaptureBuffered() {
  openAnalyticsGate();
}

export { posthog };
