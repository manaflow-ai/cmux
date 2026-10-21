// What the user's GitHub CLI says about a pull request a hover card shows (`pr.inspect`, Leo
// 2026-10-20): its title, state, author and checks. A card asks once it opens; the answer is kept
// a minute, as the host keeps it, so the next hover of the same link asks nothing. `null` means
// the host could not say (no gh, no network), and the card shows what the chat already knows.
import { useEffect, useSyncExternalStore } from "react";
import type { HeaderPullRequest } from "../header/headerState";
import { callChipHost } from "./host";

/// The header's pull request with its author's login.
export type LinkedPullRequest = HeaderPullRequest & { readonly author?: string };

const FRESH_MS = 60_000;
const MAX_KEPT = 200;

const answers = new Map<string, { value: LinkedPullRequest | null; at: number }>();
const asking = new Set<string>();
const listeners = new Set<() => void>();
let version = 0;

function changed() {
  version += 1;
  for (const listener of listeners) listener();
}

function ask(url: string) {
  const known = answers.get(url);
  if (asking.has(url) || (known && Date.now() - known.at < FRESH_MS)) return;
  asking.add(url);
  void callChipHost("pr.inspect", { url }).then((reply) => {
    asking.delete(url);
    const value = (reply as { pullRequest?: LinkedPullRequest | null } | undefined)?.pullRequest ?? null;
    if (answers.size >= MAX_KEPT) answers.delete(answers.keys().next().value!);
    answers.set(url, { value: value && typeof value.number === "number" ? value : null, at: Date.now() });
    changed();
  });
}

const snapshot = () => version;

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// The pull request at `url` as gh last read it; asks while `open` (a shown card). Undefined
/// until the host answers, null when it could not say.
export function usePullRequestInfo(url: string | undefined, open: boolean): LinkedPullRequest | null | undefined {
  useSyncExternalStore(subscribe, snapshot, snapshot);
  useEffect(() => {
    if (url && open) ask(url);
  }, [url, open]);
  return url ? answers.get(url)?.value : undefined;
}

/// Tests start from nothing.
export function resetPullRequestStore(): void {
  answers.clear();
  asking.clear();
  changed();
}
