// What the host says about a reply's paths and links (`link.inspect`, decision D4): where each
// path is (inside the session's folders, outside, on the deny list, missing) and the favicon and
// title cmux already has for each URL. Requests from one render are batched into one call; the
// answers are kept for the page's life. The host never fetches anything for this; the one
// exception is a Thread details source's site icon (`link.favicon`, labs `sourceIcons`), fetched
// through the host's guarded queue, without cookies.
import { useEffect, useSyncExternalStore } from "react";
import { callChipHost } from "./host";

export type PathPlace = "root" | "outside" | "denied" | "missing";
export type PathInfo = { place: PathPlace; folder: boolean };
export type SiteInfo = { icon?: string; title?: string };
export type ReplyPolicy = { outsideRoots: "confirm" | "text" | "open"; remoteImages: "click" | "never" | "always" };

type Inspect = {
  paths?: Record<string, PathInfo>;
  sites?: Record<string, SiteInfo>;
  policy?: Partial<ReplyPolicy>;
};

const MAX_BATCH = 64;
const MAX_KEPT = 2000;
const MAX_FAVICONS = 128;
const NEGATIVE_ICON_MS = 30_000;

const paths = new Map<string, PathInfo | null>();
const sites = new Map<string, SiteInfo | null>();
/// Completed icons by origin, including short-lived misses, in least recently used order.
const favicons = new Map<string, { icon?: string; expires: number }>();
const fetchingIcons = new Map<string, { url: string; readers: number }>();
const askingUrls = new Set<string>();
let generation = 0;
/// Paths sent to the host and not answered yet.
const asking = new Set<string>();
let policy: ReplyPolicy = { outsideRoots: "confirm", remoteImages: "click" };
let queuedPaths: string[] = [];
let queuedUrls: string[] = [];
let scheduled = false;
let inFlight = false;
/// The policy is asked once, with the first chip or image (an empty inspect when there is none).
let policyAsked = false;
let version = 0;
let notificationScheduled = false;
const listeners = new Set<() => void>();

function changed() {
  version += 1;
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
  if (inFlight) return;
  const first = !policyAsked;
  if (!first && !queuedPaths.length && !queuedUrls.length) return;
  policyAsked = true;
  const batchPaths = queuedPaths.splice(0, MAX_BATCH);
  const batchUrls = queuedUrls.splice(0, MAX_BATCH);
  inFlight = true;
  const current = generation;
  void callChipHost("link.inspect", { paths: batchPaths, urls: batchUrls })
    .then((reply) => {
      if (current !== generation) return;
      const value = (reply ?? {}) as Inspect;
      for (const path of batchPaths) {
        paths.set(path, value.paths?.[path] ?? null);
        asking.delete(path);
      }
      for (const url of batchUrls) {
        sites.set(url, value.sites?.[url] ?? null);
        askingUrls.delete(url);
      }
      if (value.policy) policy = { ...policy, ...value.policy };
    })
    .finally(() => {
      if (current !== generation) return;
      inFlight = false;
      changed();
      if (queuedPaths.length || queuedUrls.length) {
        scheduleFlush();
      }
    });
}

function ask(path?: string, url?: string) {
  if (paths.size + sites.size > MAX_KEPT) {
    paths.clear();
    asking.clear();
    sites.clear();
    askingUrls.clear();
  }
  if (path !== undefined && !paths.has(path)) {
    paths.set(path, null);
    asking.add(path);
    queuedPaths.push(path);
  }
  if (url !== undefined && !sites.has(url)) {
    sites.set(url, null);
    askingUrls.add(url);
    queuedUrls.push(url);
  }
  if (!scheduled && (!policyAsked || queuedPaths.length || queuedUrls.length)) {
    scheduleFlush();
  }
}

const snapshot = () => version;

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// The host's answer for `path` (undefined while it is asked, or when the host had none), whether
/// the host has answered, and the policy.
export function usePathInfo(path: string): { info: PathInfo | undefined; answered: boolean; policy: ReplyPolicy } {
  useSyncExternalStore(subscribe, snapshot, snapshot);
  ask(path);
  return { info: paths.get(path) ?? undefined, answered: !asking.has(path), policy };
}

/// What cmux already has for `url` (nothing while it is asked, or when it has nothing).
export function useSiteInfo(url: string | undefined): SiteInfo | undefined {
  useSyncExternalStore(subscribe, snapshot, snapshot);
  if (url) ask(undefined, url);
  return url ? (sites.get(url) ?? undefined) : undefined;
}

function sourceURL(text: string | undefined): URL | undefined {
  if (!text || new TextEncoder().encode(text).length > 2048) return undefined;
  for (const character of text) if (character.charCodeAt(0) <= 32) return undefined;
  try {
    const authority = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]*)/i.exec(text)?.[1];
    const url = new URL(text);
    if (
      !["http:", "https:"].includes(url.protocol) ||
      !url.hostname ||
      url.username ||
      url.password ||
      authority?.includes("@") ||
      new TextEncoder().encode(url.href).length > 2048
    )
      return undefined;
    return url;
  } catch {
    return undefined;
  }
}

function cachedIcon(origin: string) {
  const entry = favicons.get(origin);
  if (entry && entry.expires <= Date.now()) {
    favicons.delete(origin);
    return undefined;
  }
  return entry;
}

function fetchIcon(url: string, origin: string) {
  const entry = cachedIcon(origin);
  if (entry) {
    favicons.delete(origin);
    favicons.set(origin, entry);
    return;
  }
  const existing = fetchingIcons.get(origin);
  if (existing) {
    existing.readers += 1;
    return () => releaseIcon(origin, existing);
  }
  const pending = { url, readers: 1 };
  fetchingIcons.set(origin, pending);
  const current = generation;
  void callChipHost("link.favicon", { url })
    .then((reply) => {
      if (current !== generation || fetchingIcons.get(origin) !== pending) return;
      const value = reply as { icon?: unknown; disabled?: boolean } | undefined;
      // A lab refusal is not evidence that the site has no icon. Try again on the next activation.
      if (value?.disabled) return;
      const icon = typeof value?.icon === "string" && value.icon.startsWith("data:image/") ? value.icon : undefined;
      favicons.set(origin, { icon, expires: icon ? Infinity : Date.now() + NEGATIVE_ICON_MS });
      while (favicons.size > MAX_FAVICONS) {
        const oldest = favicons.keys().next().value;
        if (oldest === undefined) break;
        favicons.delete(oldest);
      }
      changed();
    })
    .finally(() => {
      if (fetchingIcons.get(origin) === pending) fetchingIcons.delete(origin);
    });
  return () => releaseIcon(origin, pending);
}

function releaseIcon(origin: string, pending: { url: string; readers: number }) {
  pending.readers -= 1;
  if (pending.readers > 0 || fetchingIcons.get(origin) !== pending) return;
  fetchingIcons.delete(origin);
  void callChipHost("link.cancelFavicon", { url: pending.url });
}

/// A held icon wins before the site's own icon is fetched, with labs `sourceIcons` on.
export function useSourceIcon(url: string | undefined, fetch: boolean): string | undefined {
  const parsed = sourceURL(url);
  const valid = parsed ? url : undefined;
  if (valid) ask(undefined, valid);
  // Subscribe to the values themselves so the React Compiler sees inspection and icon changes.
  const held = useSyncExternalStore(
    subscribe,
    () => (valid ? sites.get(valid)?.icon : undefined),
    () => undefined,
  );
  const answered = useSyncExternalStore(subscribe, () => !!valid && !askingUrls.has(valid), () => false);
  // Passive fetches use TLS only. An HTTP source can still use an icon held by an open tab.
  const origin = parsed?.protocol === "https:" ? parsed.origin : undefined;
  const icon = useSyncExternalStore(
    subscribe,
    () => (fetch && origin ? cachedIcon(origin)?.icon : undefined),
    () => undefined,
  );
  useEffect(() => {
    if (valid && origin && fetch && answered && !held) return fetchIcon(valid, origin);
  }, [valid, origin, fetch, answered, held]);
  return held ?? icon;
}

/// `agentPane.images.remote` and `agentPane.links.outsideRoots` as the host last said.
export function useReplyPolicy(): ReplyPolicy {
  useSyncExternalStore(subscribe, snapshot, snapshot);
  ask();
  return policy;
}

/// Tests start from nothing.
export function resetLinkStore(): void {
  paths.clear();
  asking.clear();
  sites.clear();
  favicons.clear();
  fetchingIcons.clear();
  askingUrls.clear();
  generation += 1;
  inFlight = false;
  queuedPaths = [];
  queuedUrls = [];
  scheduled = false;
  policy = { outsideRoots: "confirm", remoteImages: "click" };
  policyAsked = false;
  changed();
}

/** Gallery host fixtures can prime the same cache the native inspect call would fill. */
export function seedLinkStore(seed: {
  paths?: Record<string, PathInfo>;
  sites?: Record<string, SiteInfo>;
  policy?: Partial<ReplyPolicy>;
}): void {
  for (const [path, info] of Object.entries(seed.paths ?? {})) paths.set(path, info);
  for (const [url, info] of Object.entries(seed.sites ?? {})) sites.set(url, info);
  if (seed.policy) policy = { ...policy, ...seed.policy };
  policyAsked = true;
  changed();
}
