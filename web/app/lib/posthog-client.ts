"use client";

import posthog from "posthog-js";

if (typeof window !== "undefined") {
  posthog.init("phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP", {
    api_host: "https://r.cmux.com",
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

let openAnalyticsGate: () => void = () => {};
const analyticsGate = new Promise<void>((resolve) => {
  openAnalyticsGate = resolve;
});

/**
 * Resolves once the route tracker buffers captures instead of the initial
 * `before_send` dropping them. Captures sent before this are discarded.
 */
export function whenAnalyticsCaptureBuffered(): Promise<void> {
  return analyticsGate;
}

/** Called by the route tracker after it installs its capture buffer. */
export function markAnalyticsCaptureBuffered() {
  openAnalyticsGate();
}

export { posthog };
