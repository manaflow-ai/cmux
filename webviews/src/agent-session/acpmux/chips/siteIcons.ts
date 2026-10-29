// The favicon of each web site a reply, a prompt or a fetch tool links to (`link.favicons`). The
// page loads no image from the network (CSP `img-src data:`), so the host answers each site's icon
// as a small PNG data URL: one cmux already has from its browser, else the favicon service's icon
// for the host name, fetched by the host under its network rules (AgentPaneSiteIcons.swift). A local or
// private address is never asked about: it keeps the globe. Requests from one render are batched
// into one call, one call at a time; a site without an icon is remembered for the page's life, so
// it is asked once.
import { useSyncExternalStore } from "react";
import { callChipHost } from "./host";
import { isPrivateUrl } from "./linkDisplay";

/// Most sites in one `link.favicons` (the host's bound per request, AgentPaneReplyRequest.swift).
const MAX_BATCH = 32;
/// Most sites kept; past it the store starts again and the drawn links ask again.
const MAX_KEPT = 512;

/// The only icon the host sends: a base64 PNG data URL. Anything else is no icon, so no answer
/// can carry other text into the `url("...")` the mark draws it with (SiteIcon.tsx).
const PNG_DATA_URL = /^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/;

/// A site's icon: a data URL, `null` once the host had none, absent until asked.
const icons = new Map<string, string | null>();
/// Sites queued or in flight: kept through a reset of the store, so each still gets its answer.
const pending = new Set<string>();
let queued: string[] = [];
let scheduled = false;
let inFlight = false;
let notificationScheduled = false;
const listeners = new Set<() => void>();

function changed() {
  if (!listeners.size || notificationScheduled) return;
  notificationScheduled = true;
  queueMicrotask(() => {
    notificationScheduled = false;
    for (const listener of listeners) listener();
  });
}

function scheduleFlush() {
  if (scheduled) return;
  scheduled = true;
  queueMicrotask(flush);
}

function flush() {
  scheduled = false;
  if (inFlight || !queued.length) return;
  const batch = queued.splice(0, MAX_BATCH);
  inFlight = true;
  void callChipHost("link.favicons", { hosts: batch })
    .then((reply) => {
      const answered = ((reply ?? {}) as { icons?: Record<string, unknown> }).icons ?? {};
      for (const host of batch) {
        const icon = answered[host];
        // Only an inline raster image: anything else is no icon (the CSP would refuse it anyway).
        icons.set(host, typeof icon === "string" && PNG_DATA_URL.test(icon) ? icon : null);
        pending.delete(host);
      }
    })
    .finally(() => {
      inFlight = false;
      changed();
      if (queued.length) scheduleFlush();
    });
}

function ask(host: string) {
  if (icons.has(host)) return;
  if (icons.size >= MAX_KEPT) {
    // The oldest answered sites are forgotten, an eighth at a time; links that drew one re-render
    // and ask for it again. Sites still asked stay, so their answers land.
    let drop = MAX_KEPT / 8;
    for (const kept of icons.keys()) {
      if (drop === 0) break;
      if (pending.has(kept)) continue;
      icons.delete(kept);
      drop -= 1;
    }
    changed();
  }
  // Marked as none while asked, so a render before the answer asks no second time.
  icons.set(host, null);
  pending.add(host);
  queued.push(host);
  scheduleFlush();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// The site of `href` whose icon the host may look up: the lowercased host name of an http(s)
/// address that is not on this machine or a private network (linkDisplay.ts `isPrivateUrl`), else
/// undefined (a path, `mailto:`, a dev server, a device).
export function siteIconHost(href: string): string | undefined {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return undefined;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return undefined;
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (!host || host.startsWith("[") || isPrivateUrl(href)) return undefined;
  return host;
}

/// The favicon of `host` as a data URL, or undefined while it is asked and when it has none (the
/// caller draws the globe). No host asks nothing.
export function useSiteIcon(host: string | undefined): string | undefined {
  if (host) ask(host);
  return useSyncExternalStore(
    subscribe,
    () => (host ? (icons.get(host) ?? undefined) : undefined),
    () => undefined,
  );
}

/// Tests and the gallery start from nothing.
export function resetSiteIcons(): void {
  icons.clear();
  pending.clear();
  queued = [];
  scheduled = false;
  inFlight = false;
  changed();
}

/// Gallery host fixtures can prime the same cache the native call would fill (`null`: no icon).
export function seedSiteIcons(seed: Record<string, string | null>): void {
  for (const [host, icon] of Object.entries(seed)) icons.set(host, icon);
  changed();
}
