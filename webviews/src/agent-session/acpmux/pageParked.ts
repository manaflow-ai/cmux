// A page the app keeps out of sight while Chromium still draws it: the prewarmed New Tab spare and a
// closed chat kept for Reopen wait in an off-screen parking view (PageOffscreenParking.swift), and the
// native side reports them visible on purpose, so each has painted when it is taken. Their
// `visibilityState` reads visible, so a page's data work treated them as shown: every change of any chat
// drew them in the renderer the shown chat scrolls in (bench/session-scale-scroll.bench.ts; Leo,
// 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?").
//
// The host sets `window.__cmuxParked` as the document commits (AgentPaneNavigation) and dispatches
// PAGE_PARKED_EVENT when it parks or takes the page (AgentPaneView.setParked). Paint keeps reading
// `visibilityState`; only data work also reads this (direct.ts `pageShown`).

/// `{detail: {parked: boolean}}`, dispatched on window by the host.
export const PAGE_PARKED_EVENT = "acpmux-parked";

type ParkedWindow = { __cmuxParked?: unknown };

/// Whether the host parked this page: it draws, and nobody sees it.
export function pageParked(): boolean {
  return typeof window !== "undefined" && (window as ParkedWindow).__cmuxParked === true;
}

/// Calls `changed` after each park or take, once the flag reads the new state. Returns the unsubscribe.
export function onPageParkedChange(changed: () => void): () => void {
  if (typeof window === "undefined") return () => {};
  const handle = (event: Event) => {
    const parked = (event as CustomEvent<{ parked?: unknown }>).detail?.parked === true;
    (window as ParkedWindow).__cmuxParked = parked;
    changed();
  };
  window.addEventListener(PAGE_PARKED_EVENT, handle);
  return () => window.removeEventListener(PAGE_PARKED_EVENT, handle);
}
