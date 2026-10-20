// What the host says about a reply's paths and links (`link.inspect`, decision D4): where each
// path is (inside the session's folders, outside, on the deny list, missing) and the favicon and
// title cmux already has for each URL. Requests from one render are batched into one call; the
// answers are kept for the page's life. The host never fetches anything for this; the one
// exception is an opted-in reply or Thread details source icon (`link.favicon`, labs
// `sourceIcons`), fetched through the host's guarded queue, without cookies.
import { useEffect, useSyncExternalStore } from "react";
import { callChipHost } from "./host";

export type PathPlace = "root" | "outside" | "denied" | "missing";
export type PathInfo = { place: PathPlace; folder: boolean };
export type SiteInfo = { icon?: string; title?: string };
export type ReplyPolicy = {
  outsideRoots: "confirm" | "text" | "open";
  remoteImages: "click" | "never" | "always";
};

type Inspect = {
  paths?: Record<string, PathInfo>;
  sites?: Record<string, SiteInfo>;
  policy?: Partial<ReplyPolicy>;
};

const MAX_BATCH = 64;
const MAX_KEPT = 2000;
const MAX_FAVICONS = 64;
const MAX_CHAT_ORIGINS = 32;
type IconScope = "source" | "chat";
// Cache expiry and reader cancellation must not restore the tracking budget. Thread details
// and chat share 64 distinct origins per pane lifetime; chat can use at most 32 of them.
const requestedIconOrigins = new Set<string>();
const chatIconOrigins = new Set<string>();
const NEGATIVE_ICON_MS = 10 * 60_000;

const paths = new Map<string, PathInfo | null>();
const sites = new Map<string, SiteInfo | null>();
/// Completed icons by origin, including ten-minute misses, in least recently used order.
const favicons = new Map<string, { icon?: string; expires: number }>();
type IconReaders = {
  url: string;
  readers: number;
  pending?: object;
  retry?: ReturnType<typeof setTimeout>;
  retried: boolean;
};
// Reader ownership includes completed misses and their one-shot retry, not just in-flight calls.
const fetchingIcons = new Map<string, IconReaders>();
// The first completed held-icon inspection makes an origin ready. Path changes cannot revoke it.
const inspectedIconOrigins = new Map<string, string>();
const heldIconOrigins = new Map<string, string>();
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
        rememberInspectedOrigin(url);
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
    heldIconOrigins.clear();
    askingUrls.clear();
    // Keep active origins ready across cache compaction, including during path changes.
    for (const origin of inspectedIconOrigins.keys())
      if (!fetchingIcons.has(origin)) inspectedIconOrigins.delete(origin);
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
export function usePathInfo(path: string): {
  info: PathInfo | undefined;
  answered: boolean;
  policy: ReplyPolicy;
} {
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

function rememberInspectedOrigin(url: string) {
  const parsed = sourceURL(url);
  if (!parsed) return;
  const icon = sites.get(url)?.icon;
  if (icon) heldIconOrigins.set(parsed.origin, icon);
  if (parsed.protocol === "https:" && !inspectedIconOrigins.has(parsed.origin))
    inspectedIconOrigins.set(parsed.origin, url);
}

function fetchIcon(url: string, origin: string, scope: IconScope) {
  if (!requestedIconOrigins.has(origin) && requestedIconOrigins.size >= MAX_FAVICONS) return;
  if (scope === "chat" && !chatIconOrigins.has(origin)) {
    if (chatIconOrigins.size >= MAX_CHAT_ORIGINS) return;
    chatIconOrigins.add(origin);
    // A source may already hold this icon. Notify snapshot readers when chat admits it too.
    changed();
  }
  const existing = fetchingIcons.get(origin);
  if (existing) {
    existing.readers += 1;
    return () => releaseIcon(origin, existing);
  }
  requestedIconOrigins.add(origin);
  const readers: IconReaders = { url, readers: 1, retried: false };
  fetchingIcons.set(origin, readers);
  startIcon(origin, readers);
  return () => releaseIcon(origin, readers);
}

function retryIcon(origin: string, readers: IconReaders, at: number) {
  if (readers.retried || readers.retry !== undefined) return;
  readers.retry = setTimeout(
    () => {
      if (fetchingIcons.get(origin) !== readers || readers.readers === 0) return;
      readers.retry = undefined;
      readers.retried = true;
      startIcon(origin, readers);
    },
    Math.max(0, at - Date.now()),
  );
}

function startIcon(origin: string, readers: IconReaders) {
  const entry = cachedIcon(origin);
  if (entry) {
    favicons.delete(origin);
    favicons.set(origin, entry);
    return;
  }
  const pending = {};
  readers.pending = pending;
  const current = generation;
  void callChipHost("link.favicon", { url: readers.url }).then((reply) => {
    if (current !== generation || fetchingIcons.get(origin) !== readers || readers.pending !== pending) return;
    readers.pending = undefined;
    const value = reply as { icon?: unknown; disabled?: boolean; temporary?: boolean } | undefined;
    // A lab refusal is retried only on activation. Overload/cancellation get one short backoff.
    if (!value || value.disabled) return;
    const icon = typeof value?.icon === "string" && value.icon.startsWith("data:image/") ? value.icon : undefined;
    if (!icon && value.temporary) {
      retryIcon(origin, readers, Date.now() + 1000);
      return;
    }
    // Legacy hosts return {} for a miss. Match the app's ten-minute negative cache on remount.
    const expires = icon ? Infinity : Date.now() + NEGATIVE_ICON_MS;
    favicons.set(origin, { icon, expires });
    while (favicons.size > MAX_FAVICONS) {
      const oldest = favicons.keys().next().value;
      if (oldest === undefined) break;
      favicons.delete(oldest);
    }
    changed();
  });
}

function releaseIcon(origin: string, readers: IconReaders) {
  readers.readers -= 1;
  if (readers.readers > 0 || fetchingIcons.get(origin) !== readers) return;
  fetchingIcons.delete(origin);
  if (readers.retry !== undefined) clearTimeout(readers.retry);
  if (readers.pending) void callChipHost("link.cancelFavicon", { url: readers.url });
}

/// A held icon wins before the site's own icon is fetched, with labs `sourceIcons` on.
export function useSourceIcon(
  url: string | undefined,
  fetch: boolean,
  scope: IconScope = "source",
): string | undefined {
  const parsed = sourceURL(url);
  const valid = parsed ? url : undefined;
  if (valid) ask(undefined, valid);
  // Subscribe to the values themselves so the React Compiler sees inspection and icon changes.
  const held = useSyncExternalStore(
    subscribe,
    () => (parsed ? heldIconOrigins.get(parsed.origin) : undefined),
    () => undefined,
  );
  // Passive fetches use TLS only. An HTTP source can still use an icon held by an open tab.
  const origin = parsed?.protocol === "https:" ? parsed.origin : undefined;
  const answered = useSyncExternalStore(
    subscribe,
    () =>
      !!origin &&
      inspectedIconOrigins.has(origin) &&
      // Existing readers keep their ownership while a new path is inspected; no new fetch starts.
      (!askingUrls.has(valid!) || fetchingIcons.has(origin)),
    () => false,
  );
  const icon = useSyncExternalStore(
    subscribe,
    () => (fetch && origin && (scope !== "chat" || chatIconOrigins.has(origin)) ? cachedIcon(origin)?.icon : undefined),
    () => undefined,
  );
  useEffect(() => {
    const inspectedURL = origin ? inspectedIconOrigins.get(origin) : undefined;
    if (inspectedURL && origin && fetch && answered && !held) return fetchIcon(inspectedURL, origin, scope);
  }, [origin, fetch, answered, held, scope]);
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
  requestedIconOrigins.clear();
  chatIconOrigins.clear();
  for (const readers of fetchingIcons.values()) if (readers.retry !== undefined) clearTimeout(readers.retry);
  fetchingIcons.clear();
  inspectedIconOrigins.clear();
  heldIconOrigins.clear();
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
  for (const [url, info] of Object.entries(seed.sites ?? {})) {
    sites.set(url, info);
    rememberInspectedOrigin(url);
  }
  if (seed.policy) policy = { ...policy, ...seed.policy };
  policyAsked = true;
  changed();
}
