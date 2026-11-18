// A page the app keeps out of sight while Chromium still draws it: the prewarmed New Tab spare and a
// closed chat kept for Reopen wait in an off-screen parking view (PageOffscreenParking.swift), and the
// native side reports them visible on purpose, so each has painted when it is taken. Their
// `visibilityState` reads visible, so a page's data work treated them as shown: every change of any chat
// drew them in the renderer the shown chat scrolls in (bench/session-scale-scroll.bench.ts; Leo,
// 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?").
//
// The host dispatches PAGE_PARKED_EVENT when it parks or takes the page (AgentPaneView.setParked), and
// again once a document that loads while parked finished loading (AgentPaneView.pageLoadedAgain). One
// window listener, installed with this module, keeps the flag: an event between two clients (a
// reconnect's backoff) still lands, so a taken page never reads parked. Paint keeps reading
// `visibilityState`; only data work also reads this (direct.ts `pageShown`).

/// `{detail: {parked: boolean}}`, dispatched on window by the host.
export const PAGE_PARKED_EVENT = "acpmux-parked";

type ParkedWindow = { __cmuxParked?: unknown };

const subscribers = new Set<() => void>();
let listening: Window | undefined;

/// Installs the one listener on this window (a test may swap the global window after import).
function listen(): void {
  if (typeof window === "undefined" || listening === window) return;
  listening = window;
  window.addEventListener(PAGE_PARKED_EVENT, (event: Event) => {
    (window as ParkedWindow).__cmuxParked = (event as CustomEvent<{ parked?: unknown }>).detail?.parked === true;
    for (const changed of subscribers) changed();
  });
}

listen();

/// Whether the host parked this page: it draws, and nobody sees it.
export function pageParked(): boolean {
  return typeof window !== "undefined" && (window as ParkedWindow).__cmuxParked === true;
}

/// Calls `changed` after each park or take, once the flag reads the new state. Returns the unsubscribe.
export function onPageParkedChange(changed: () => void): () => void {
  listen();
  subscribers.add(changed);
  return () => subscribers.delete(changed);
}
