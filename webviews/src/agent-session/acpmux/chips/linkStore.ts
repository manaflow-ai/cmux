// What the host says about a reply's paths and links (`link.inspect`, decision D4): where each
// path is (inside the session's folders, outside, on the deny list, missing) and the favicon and
// title cmux already has for each URL. Requests from one render are batched into one call; the
// answers are kept for the page's life. The host never fetches anything for this.
import { useSyncExternalStore } from "react";
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

const paths = new Map<string, PathInfo | null>();
const sites = new Map<string, SiteInfo | null>();
/// Paths sent to the host and not answered yet.
const asking = new Set<string>();
let policy: ReplyPolicy = { outsideRoots: "confirm", remoteImages: "click" };
let queuedPaths: string[] = [];
let queuedUrls: string[] = [];
let scheduled = false;
/// The policy is asked once, with the first chip or image (an empty inspect when there is none).
let policyAsked = false;
let version = 0;
const listeners = new Set<() => void>();

function changed() {
  version += 1;
  for (const listener of listeners) listener();
}

function flush() {
  scheduled = false;
  let first = !policyAsked;
  policyAsked = true;
  while (first || queuedPaths.length || queuedUrls.length) {
    first = false;
    const batchPaths = queuedPaths.splice(0, MAX_BATCH);
    const batchUrls = queuedUrls.splice(0, MAX_BATCH);
    void callChipHost("link.inspect", { paths: batchPaths, urls: batchUrls }).then((reply) => {
      const value = (reply ?? {}) as Inspect;
      for (const path of batchPaths) {
        paths.set(path, value.paths?.[path] ?? null);
        asking.delete(path);
      }
      for (const url of batchUrls) sites.set(url, value.sites?.[url] ?? null);
      if (value.policy) policy = { ...policy, ...value.policy };
      changed();
    });
  }
}

function ask(path?: string, url?: string) {
  if (paths.size + sites.size > MAX_KEPT) {
    paths.clear();
    asking.clear();
    sites.clear();
  }
  if (path !== undefined && !paths.has(path)) {
    paths.set(path, null);
    asking.add(path);
    queuedPaths.push(path);
  }
  if (url !== undefined && !sites.has(url)) {
    sites.set(url, null);
    queuedUrls.push(url);
  }
  if (!scheduled && (!policyAsked || queuedPaths.length || queuedUrls.length)) {
    scheduled = true;
    queueMicrotask(flush);
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
  queuedPaths = [];
  queuedUrls = [];
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
