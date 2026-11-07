// The favicon of each web site a reply, a prompt or a fetch tool links to (`link.favicons`). The
// page loads no image from the network (CSP `img-src data:`), so the host answers each site's icon
// as a small PNG data URL: one cmux already has from its browser, else the favicon service's icon
// for the host name, fetched by the host under its network rules (AgentPaneSiteIcons.swift). A local or
// private address is never asked about: it keeps the globe. Requests from one render are batched
// into one call, one call at a time; a site without an icon is remembered for the page's life, so
// it is asked once.
import { useCallback, useSyncExternalStore } from "react";
import { callChipHost } from "./host";
import { isPrivateUrl } from "./linkDisplay";

/// Most sites in one `link.favicons` (the host's bound per request, AgentPaneReplyRequest.swift).
const MAX_BATCH = 32;
/// Most sites kept that no drawn link shows; past it the oldest of those are forgotten.
const MAX_KEPT = 512;
/// A host name as the host takes it (AgentPaneReplyRequest.swift `isHostName`): one it refuses
/// would fail the whole batch it rides in.
const HOST_NAME = /^[a-z0-9.-]{1,253}$/;

/// The only icon the host sends: a base64 PNG data URL. Anything else is no icon, so no answer
/// can carry other text into the `url("...")` the mark draws it with (SiteIcon.tsx).
const PNG_DATA_URL = /^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/;

/// `icon` when it is an inline PNG (the only icon the page draws), else undefined.
export function pngIcon(icon: string | undefined): string | undefined {
  return icon && PNG_DATA_URL.test(icon) ? icon : undefined;
}

/// A site's icon: a data URL, `null` once the host had none, absent until asked.
const icons = new Map<string, string | null>();
/// Sites queued or in flight: kept through a reset of the store, so each still gets its answer.
const pending = new Set<string>();
/// How many drawn links show each site: their icons are never forgotten, so a full store does not
/// make them ask again.
const shown = new Map<string, number>();
let queued: string[] = [];
let scheduled = false;
let inFlight = false;
let notificationScheduled = false;
const listeners = new Set<() => void>();
/// Sites the host answered `later` (its rate window was full): asked again once, together, after
/// the delay it named, by one timer that runs only while such sites wait.
const retry = new Set<string>();
let retryTimer: ReturnType<typeof setTimeout> | undefined;
/// Bounds on the host's `retryAfterMs`.
const MIN_RETRY_MS = 10;
const MAX_RETRY_MS = 120_000;

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
      const answer = (reply ?? {}) as { icons?: Record<string, unknown>; later?: unknown; retryAfterMs?: unknown };
      const answered = answer.icons ?? {};
      const later = new Set(Array.isArray(answer.later) ? answer.later : []);
      for (const host of batch) {
        if (later.has(host)) {
          // Still marked as none, so a render does not ask again before the retry.
          pending.delete(host);
          retry.add(host);
          continue;
        }
        const icon = answered[host];
        // Only an inline raster image: anything else is no icon (the CSP would refuse it anyway).
        icons.set(host, typeof icon === "string" && PNG_DATA_URL.test(icon) ? icon : null);
        pending.delete(host);
      }
      if (later.size) scheduleRetry(answer.retryAfterMs);
    })
    .finally(() => {
      inFlight = false;
      changed();
      if (queued.length) scheduleFlush();
    });
}

function scheduleRetry(after: unknown) {
  if (retryTimer !== undefined || !retry.size) return;
  const delay = Math.min(MAX_RETRY_MS, Math.max(MIN_RETRY_MS, typeof after === "number" ? after : 30_000));
  retryTimer = setTimeout(() => {
    retryTimer = undefined;
    for (const host of retry) {
      // A site forgotten meanwhile is asked by its link's next render instead.
      if (icons.get(host) !== null || pending.has(host)) continue;
      pending.add(host);
      queued.push(host);
    }
    retry.clear();
    scheduleFlush();
  }, delay);
}

function ask(host: string) {
  if (icons.has(host)) return;
  if (icons.size >= MAX_KEPT) {
    // The oldest answered sites no link shows are forgotten, an eighth at a time. Sites still
    // asked stay, so their answers land; sites a link shows stay, so it never asks again.
    let drop = MAX_KEPT / 8;
    for (const kept of icons.keys()) {
      if (drop === 0) break;
      if (pending.has(kept) || shown.has(kept)) continue;
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

function subscribe(listener: () => void, host: string | undefined) {
  listeners.add(listener);
  if (host) shown.set(host, (shown.get(host) ?? 0) + 1);
  return () => {
    listeners.delete(listener);
    if (!host) return;
    const left = (shown.get(host) ?? 1) - 1;
    if (left > 0) shown.set(host, left);
    else shown.delete(host);
  };
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
  if (!HOST_NAME.test(host) || isPrivateUrl(href)) return undefined;
  return host;
}

/// The favicon of `host` as a data URL, or undefined while it is asked and when it has none (the
/// caller draws the globe). No host asks nothing.
export function useSiteIcon(host: string | undefined): string | undefined {
  if (host) ask(host);
  const watch = useCallback((listener: () => void) => subscribe(listener, host), [host]);
  return useSyncExternalStore(
    watch,
    () => (host ? (icons.get(host) ?? undefined) : undefined),
    () => undefined,
  );
}

/// Tests and the gallery start from nothing.
export function resetSiteIcons(): void {
  if (retryTimer !== undefined) clearTimeout(retryTimer);
  retryTimer = undefined;
  retry.clear();
  icons.clear();
  pending.clear();
  queued = [];
  scheduled = false;
  inFlight = false;
  changed();
}
