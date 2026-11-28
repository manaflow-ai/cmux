"use client";

import { posthog, whenAnalyticsCaptureBuffered } from "./posthog-client";

/** Class Hexclave gives the full-screen card it appends to `<body>`. */
export const HEXCLAVE_SETUP_OVERLAY_CLASS = "hexclave-setup-error-overlay";

/**
 * Hexclave renders a failed authentication flow as a full-screen modal that
 * it appends to `<body>` outside React, so no error boundary can contain it.
 * `globals.css` hides that card for visitors; this reports what it said, so
 * the failure still reaches PostHog instead of disappearing.
 */
export function reportHexclaveSetupOverlays() {
  if (typeof MutationObserver === "undefined" || !document.body) return;
  const reported = new WeakSet<Element>();
  const report = (element: Element) => {
    if (reported.has(element)) return;
    reported.add(element);
    const summary = (element.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 500);
    const path = window.location.pathname;
    // A setup error can fire before hydration, while PostHog still drops
    // every capture. Send it once the route tracker buffers captures.
    void whenAnalyticsCaptureBuffered().then(() => {
      try {
        posthog?.captureException(new Error(`Hexclave setup error overlay: ${summary}`), {
          boundary: "hexclave-setup-overlay",
          path,
        });
      } catch {
        // Reporting must never break the page it is protecting.
      }
    });
  };
  const scan = () => {
    for (const element of document.body.querySelectorAll(`.${HEXCLAVE_SETUP_OVERLAY_CLASS}`)) {
      // The card fills in after the root is appended; report once it has text.
      if (element.textContent?.trim()) report(element);
    }
  };
  new MutationObserver(scan).observe(document.body, { childList: true, subtree: true });
  scan();
}
