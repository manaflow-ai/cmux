// The viewer notices edits made after it loaded (cx-9ce.34, dogfood run hq #1893): with the
// viewer open on a repository, an agent's edit there left the old diff on screen until the tab
// was reopened. The host fingerprints the shown scope's diff (`cmux.diff.git.fingerprint`, a hash,
// so no diff crosses the bridge); the page takes one per load and compares while it is visible.
// Coming back to the viewer refreshes it when nothing would be lost; while the reader is in it, an
// inline notice offers Refresh, since a refresh starts the diff from the top.
//
// The host has no push for a changed work tree, so a shown viewer compares on each minute of the
// page's one clock (ui/pageClock.ts), and once each time the reader comes back (the page shows
// again, or its window takes focus). A hidden viewer runs no timer, as Chrome
// stops a hidden page's timers (third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc).
import { useEffect, useRef, useState } from "react";
import { useSyncedRef } from "./useSyncedRef";
import type { DiffSource } from "../diff/generated/protocol";
import type { PageClient } from "../pages/shared/pageClient";
import { type PageLifecycle, pageLifecycleFor } from "../pages/shared/pageLifecycle";
import { type ClockGranularity, type PageClock, pageClockFor } from "../ui/pageClock";

export const DIFF_FINGERPRINT_OP = "cmux.diff.git.fingerprint";
/** How often a shown viewer compares: on each minute of the page's clock. */
export const FRESHNESS_GRANULARITY: ClockGranularity = "minute";

/** The page the viewer runs in; a test passes a fake lifecycle and a clock on fake timers. */
export interface DiffFreshnessPage {
  lifecycle?: PageLifecycle;
  clock?: PageClock;
}

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
  page: DiffFreshnessPage = {},
): boolean {
  const [stale, setStale] = useState<number>();
  const baseline = useRef<string | undefined>(undefined);
  const latest = useSyncedRef({ canRefresh, refresh });
  const lifecycle = page.lifecycle ?? pageLifecycleFor();
  const clock = page.clock ?? pageClockFor(lifecycle);
  useEffect(() => {
    baseline.current = undefined;
    if (!read) return;
    let current = true;
    let busy = false;
    // True from a hide until the show: on show the page's clock and the lifecycle both call, in
    // either order, and whichever checks first checks as a return.
    let returning = false;
    const check = async (back: boolean) => {
      if (busy || lifecycle.state() !== "active") return;
      busy = true;
      const comingBack = back || returning;
      returning = false;
      try {
        const now = await read();
        if (!current || now === undefined) return;
        if (baseline.current === undefined) baseline.current = now;
        else if (now !== baseline.current) {
          if (comingBack && latest.current.canRefresh()) latest.current.refresh();
          else setStale(generation);
        }
      } catch {
        // The host could not read the repository now; the next check asks again.
      } finally {
        busy = false;
      }
    };
    void check(false);
    const stopClock = clock.subscribe(FRESHNESS_GRANULARITY, () => void check(false));
    const stopLifecycle = lifecycle.observe((state) => {
      if (state !== "active") returning = true;
      else {
        void check(true);
        returning = false;
      }
    });
    const back = () => void check(true);
    window.addEventListener("focus", back);
    return () => {
      current = false;
      stopClock();
      stopLifecycle();
      window.removeEventListener("focus", back);
    };
  }, [read, generation, latest, lifecycle, clock]);
  return stale === generation;
}
