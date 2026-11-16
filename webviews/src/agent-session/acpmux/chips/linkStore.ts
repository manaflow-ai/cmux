// What the host says about a reply's paths and links (`link.inspect`, decision D4): where each
// path is (inside the session's folders, outside, on the deny list, missing) and the favicon and
// title cmux already has for each URL. Requests from one render are batched into one call; the
// answers are kept for the page's life. The host never fetches anything for this.
import { useMemo, useSyncExternalStore } from "react";
import { callChipHost } from "./host";
import { useTranscriptReadOnly } from "../conversation/readOnly";

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
/// The host's limits for one `link.inspect` entry, in UTF-8 bytes (AgentPaneReplyRequest.swift
/// `maximumURL`, AgentPaneReplyPaths.swift `maximumLength`). It refuses the whole call when any
/// entry is past them, empty or holds a NUL, so such an entry is answered here, as one the host
/// has nothing for, and never sent: one oversized link would leave every other one unanswered.
const MAX_URL_BYTES = 2048;
const MAX_PATH_BYTES = 4096;
const utf8 = new TextEncoder();
const sendable = (value: string, limit: number) =>
  value.length > 0 && !value.includes("\u0000") && utf8.encode(value).length <= limit;

const paths = new Map<string, PathInfo | null>();
const sites = new Map<string, SiteInfo | null>();
/// Paths sent to the host and not answered yet.
const asking = new Set<string>();
let policy: ReplyPolicy = { outsideRoots: "confirm", remoteImages: "click", clickFreeImageHosts: [] };
let queuedPaths: string[] = [];
let queuedUrls: string[] = [];
let scheduled = false;
let inFlight = false;
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
  if (inFlight) return;
  const first = !policyAsked;
  if (!first && !queuedPaths.length && !queuedUrls.length) return;
  policyAsked = true;
  const batchPaths = queuedPaths.splice(0, MAX_BATCH);
  const batchUrls = queuedUrls.splice(0, MAX_BATCH);
  inFlight = true;
  void callChipHost("link.inspect", { paths: batchPaths, urls: batchUrls })
    .then((reply) => {
      const value = (reply ?? {}) as Inspect;
      for (const path of batchPaths) {
        paths.set(path, value.paths?.[path] ?? null);
        asking.delete(path);
      }
      for (const url of batchUrls) sites.set(url, value.sites?.[url] ?? null);
      if (value.policy) policy = { ...policy, ...value.policy };
    })
    .finally(() => {
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
    // Hooks that read a forgotten key re-render and ask for it again.
    changed();
  }
  if (path !== undefined && !paths.has(path)) {
    paths.set(path, null);
    if (sendable(path, MAX_PATH_BYTES)) {
      asking.add(path);
      queuedPaths.push(path);
    }
  }
  if (url !== undefined && !sites.has(url)) {
    sites.set(url, null);
    if (sendable(url, MAX_URL_BYTES)) queuedUrls.push(url);
  }
  if (!scheduled && (!policyAsked || queuedPaths.length || queuedUrls.length)) {
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
export function usePathInfo(path: string): { info: PathInfo | undefined; answered: boolean; policy: ReplyPolicy } {
  // Read only (a guest), the owner's host is never asked; the path stays unanswered.
  const readOnly = useTranscriptReadOnly();
  if (!readOnly) ask(path);
  const info = useStore(() => paths.get(path) ?? undefined);
  const answered = useStore(() => !readOnly && !asking.has(path));
  return { info, answered, policy: useStore(() => policy) };
}

/// Which of `list` the host says are gone (a file the agent made, then deleted): asked as a path chip
/// asks (one batched `link.inspect`), and the same set while the answer is the same.
export function useMissingPaths(list: readonly string[]): ReadonlySet<string> {
  const readOnly = useTranscriptReadOnly();
  if (!readOnly) for (const path of list) ask(path);
  const key = useStore(() => list.filter((path) => paths.get(path)?.place === "missing").join("\u0000"));
  return useMemo(() => new Set(key ? key.split("\u0000") : []), [key]);
}

/// What cmux already has for `url` (nothing while it is asked, or when it has nothing).
export function useSiteInfo(url: string | undefined): SiteInfo | undefined {
  const readOnly = useTranscriptReadOnly();
  if (url && !readOnly) ask(undefined, url);
  return useStore(() => (url ? (sites.get(url) ?? undefined) : undefined));
}

/// `agentPane.images.remote` and `agentPane.links.outsideRoots` as the host last said.
export function useReplyPolicy(): ReplyPolicy {
  const readOnly = useTranscriptReadOnly();
  if (!readOnly) ask();
  return useStore(() => policy);
}

/// Tests start from nothing.
export function resetLinkStore(): void {
  paths.clear();
  asking.clear();
  sites.clear();
  queuedPaths = [];
  queuedUrls = [];
  scheduled = false;
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
