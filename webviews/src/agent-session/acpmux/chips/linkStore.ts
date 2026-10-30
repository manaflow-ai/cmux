// What the host says about a reply's paths and links (`link.inspect`, decision D4): where each
// path is (inside the session's folders, outside, on the deny list, missing) and the favicon and
// title cmux already has for each URL. Requests from one render are batched into one call; the
// answers are kept for the page's life. The host never fetches anything for this.
import { useSyncExternalStore } from "react";
import { callChipHost } from "./host";
import { isNameOnlyPath } from "./paths";

export type PathPlace = "root" | "outside" | "denied" | "missing";
export type PathInfo = { place: PathPlace; folder: boolean };
export type SiteInfo = { icon?: string; title?: string };
export type ReplyPolicy = {
  outsideRoots: "confirm" | "text" | "open";
  remoteImages: "click" | "never" | "always";
  /// Sites whose web images load without a click under `click` (the host's declared list,
  /// `AgentPaneSafeFetch.clickFreeImageHosts`); an older host names none.
  clickFreeImageHosts: readonly string[];
};

type Inspect = {
  paths?: Record<string, PathInfo>;
  sites?: Record<string, SiteInfo>;
  policy?: Partial<ReplyPolicy>;
};

const MAX_BATCH = 64;
const MAX_KEPT = 2000;

const paths = new Map<string, PathInfo | null>();
const sites = new Map<string, SiteInfo | null>();
/// Paths sent to the host and not answered yet.
const asking = new Set<string>();
let policy: ReplyPolicy = { outsideRoots: "confirm", remoteImages: "click", clickFreeImageHosts: [] };
let queuedPaths: string[] = [];
let queuedUrls: string[] = [];
/// Bare file names (`next-sync.py`): asked in their own batches, because the host may search the
/// chat's folders for them, and that must never hold up the other paths, links and the policy.
let queuedNames: string[] = [];
let scheduled = false;
let inFlight = false;
let namesInFlight = false;
/// Bumped by ``resetLinkStore``: an answer to a call made before the reset changes nothing.
let epoch = 0;
/// The policy is asked once, with the first chip or image (an empty inspect when there is none).
let policyAsked = false;
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
  flushNames();
  if (inFlight) return;
  const first = !policyAsked;
  if (!first && !queuedPaths.length && !queuedUrls.length) return;
  policyAsked = true;
  const batchPaths = queuedPaths.splice(0, MAX_BATCH);
  const batchUrls = queuedUrls.splice(0, MAX_BATCH);
  inFlight = true;
  const asked = epoch;
  void callChipHost("link.inspect", { paths: batchPaths, urls: batchUrls })
    .then((reply) => {
      if (asked !== epoch) return;
      const value = (reply ?? {}) as Inspect;
      for (const path of batchPaths) {
        paths.set(path, value.paths?.[path] ?? null);
        asking.delete(path);
      }
      for (const url of batchUrls) sites.set(url, value.sites?.[url] ?? null);
      if (value.policy) policy = { ...policy, ...value.policy };
    })
    .finally(() => {
      if (asked !== epoch) return;
      inFlight = false;
      changed();
      if (queuedPaths.length || queuedUrls.length) {
        scheduleFlush();
      }
    });
}

function flushNames() {
  if (namesInFlight || !queuedNames.length) return;
  const batch = queuedNames.splice(0, MAX_BATCH);
  namesInFlight = true;
  const asked = epoch;
  void callChipHost("link.inspect", { paths: batch, urls: [] })
    .then((reply) => {
      if (asked !== epoch) return;
      const value = (reply ?? {}) as Inspect;
      for (const name of batch) {
        paths.set(name, value.paths?.[name] ?? null);
        asking.delete(name);
      }
    })
    .finally(() => {
      if (asked !== epoch) return;
      namesInFlight = false;
      changed();
      if (queuedNames.length) scheduleFlush();
    });
}

function ask(path?: string, url?: string, bare = false) {
  if (paths.size + sites.size > MAX_KEPT) {
    paths.clear();
    asking.clear();
    sites.clear();
    // Hooks that read a forgotten key re-render and ask for it again.
    changed();
  }
  if (path !== undefined && !paths.has(path)) {
    paths.set(path, null);
    asking.add(path);
    // A name with no folder (`next-sync.py`, `Foo.swift:42` once its line is split off, a link to
    // one) may need the host's search of the chat's folders: it never rides the main batch.
    (bare || isNameOnlyPath(path) ? queuedNames : queuedPaths).push(path);
  }
  if (url !== undefined && !sites.has(url)) {
    sites.set(url, null);
    queuedUrls.push(url);
  }
  if (!scheduled && (!policyAsked || queuedPaths.length || queuedUrls.length || queuedNames.length)) {
    scheduleFlush();
  }
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// Each hook reads the store through its snapshots, never beside them: the React Compiler caches a
/// plain read of these maps by its arguments, so a host answer that only notified the listeners never
/// reached the image (a local image stayed its alt text).
const useStore = <T>(read: () => T): T => useSyncExternalStore(subscribe, read, read);

/// The host's answer for `path` (undefined while it is asked, or when the host had none), whether
/// the host has answered, and the policy.
/// `bare`: a bare file name, asked in the name batches (``flushNames``).
export function usePathInfo(
  path: string,
  bare = false,
): { info: PathInfo | undefined; answered: boolean; policy: ReplyPolicy } {
  ask(path, undefined, bare);
  const info = useStore(() => paths.get(path) ?? undefined);
  const answered = useStore(() => !asking.has(path));
  return { info, answered, policy: useStore(() => policy) };
}

/// What cmux already has for `url` (nothing while it is asked, or when it has nothing).
export function useSiteInfo(url: string | undefined): SiteInfo | undefined {
  if (url) ask(undefined, url);
  return useStore(() => (url ? (sites.get(url) ?? undefined) : undefined));
}

/// `agentPane.images.remote` and `agentPane.links.outsideRoots` as the host last said.
export function useReplyPolicy(): ReplyPolicy {
  ask();
  return useStore(() => policy);
}

/// Tests start from nothing.
export function resetLinkStore(): void {
  paths.clear();
  asking.clear();
  sites.clear();
  queuedPaths = [];
  queuedUrls = [];
  queuedNames = [];
  scheduled = false;
  inFlight = false;
  namesInFlight = false;
  epoch += 1;
  policy = { outsideRoots: "confirm", remoteImages: "click", clickFreeImageHosts: [] };
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
