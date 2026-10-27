// The viewer notices edits made after it loaded (cx-9ce.34, dogfood run hq #1893): with the
// viewer open on a repository, an agent's edit there left the old diff on screen until the tab
// was reopened. The host fingerprints the shown scope's diff (`cmux.diff.git.fingerprint`, a hash,
// so no diff crosses the bridge); the page takes one per load and compares while it is visible.
// Coming back to the viewer refreshes it when nothing would be lost; while the reader is in it, an
// inline notice offers Refresh, since a refresh starts the diff from the top.
//
// The compare is a page poll (pages/shared/pagePoll.ts, p13-webui-069): a hidden, frozen or parked
// viewer arms no timer and reads nothing, and its show is the one check of coming back.
import { useEffect, useRef, useState } from "react";
import { useSyncedRef } from "./useSyncedRef";
import type { DiffSource } from "../diff/generated/protocol";
import type { PageClient } from "../pages/shared/pageClient";
import { pageIsActive, pageLifecycleFor } from "../pages/shared/pageLifecycle";
import { type PagePollSeams, startPagePoll } from "../pages/shared/pagePoll";

export const DIFF_FINGERPRINT_OP = "cmux.diff.git.fingerprint";
/** How often a visible viewer compares, in ms. */
export const FRESHNESS_INTERVAL = 4000;

/** Reads the fingerprint of the diff `shown` compares; undefined where the host can't say. */
export function diffFingerprintReader(
  page: PageClient | null,
  ops: readonly string[] | undefined,
  shown: DiffSource | null,
): (() => Promise<string | undefined>) | undefined {
  if (!page || !ops?.includes(DIFF_FINGERPRINT_OP) || !shown) return undefined;
  // Branch, as the chat's ± opens it (cx-4ukqc), reads the host's branch scope: any edit to the
  // work tree changes it, as it changes the viewer's.
  const scope =
    shown.kind === "unstaged" || shown.kind === "staged"
      ? shown.kind
      : shown.kind === "branch"
        ? shown.baseRef === "HEAD"
          ? "uncommitted"
          : "branch"
        : undefined;
  if (!scope) return undefined;
  return () =>
    page.call<unknown>(DIFF_FINGERPRINT_OP, { scope }).then((value) => {
      const fingerprint = (value as { fingerprint?: unknown } | null)?.fingerprint;
      return typeof fingerprint === "string" ? fingerprint : undefined;
    });
}

/// True once the files changed since load `generation` while the reader was in the viewer. A
/// change found on coming back runs `refresh` instead, when `canRefresh` (no comment draft, no
/// commit form). Pass a stable `read` (memoized on the shown source).
export function useDiffFreshness(
  read: (() => Promise<string | undefined>) | undefined,
  generation: number,
  canRefresh: () => boolean,
  refresh: () => void,
  seams: PagePollSeams = {},
): boolean {
  const [stale, setStale] = useState<number>();
  const baseline = useRef<string | undefined>(undefined);
  const latest = useSyncedRef({ canRefresh, refresh });
  const { lifecycle = pageLifecycleFor(), timers } = seams;
  useEffect(() => {
    baseline.current = undefined;
    if (!read) return;
    let current = true;
    let busy = false;
    const check = async (returning: boolean) => {
      if (busy || !pageIsActive(lifecycle)) return;
      busy = true;
      try {
        const now = await read();
        if (!current || now === undefined) return;
        if (baseline.current === undefined) baseline.current = now;
        else if (now !== baseline.current) {
          if (returning && latest.current.canRefresh()) latest.current.refresh();
          else setStale(generation);
        }
      } catch {
        // The host could not read the repository now; the next check asks again.
      } finally {
        busy = false;
      }
    };
    const stop = startPagePoll(({ resumed }) => check(resumed), FRESHNESS_INTERVAL, { lifecycle, timers });
    // The window taking focus back is coming back too (a pane focused again in a shown tab).
    const back = () => void check(true);
    window.addEventListener("focus", back);
    return () => {
      current = false;
      stop();
      window.removeEventListener("focus", back);
    };
  }, [read, generation, latest, lifecycle, timers]);
  return stale === generation;
}
