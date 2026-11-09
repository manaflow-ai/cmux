// The viewer notices edits made after it loaded (cx-9ce.34, dogfood run hq #1893): with the
// viewer open on a repository, an agent's edit there left the old diff on screen until the tab
// was reopened. The host fingerprints the shown scope's diff (`cmux.diff.git.fingerprint`, a hash,
// so no diff crosses the bridge); the page takes one per load and compares while it is visible.
// Coming back to the viewer refreshes it when nothing would be lost; while the reader is in it, an
// inline notice offers Refresh, since a refresh starts the diff from the top.
import { useCallback, useEffect, useRef, useState } from "react";
import { useSyncedRef } from "./useSyncedRef";
import type { DiffSource } from "../diff/generated/protocol";
import { isPageError, type PageClient } from "../pages/shared/pageClient";

export const DIFF_FINGERPRINT_OP = "cmux.diff.git.fingerprint";
/** How often a focused viewer compares, in ms. */
export const FRESHNESS_INTERVAL = 4000;
/** Keep a visible background window current without running git every four seconds. */
export const UNFOCUSED_FRESHNESS_INTERVAL = 30_000;

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

/// The fingerprint of the diff the host precomputed (`prepared`, from the render), with an id that only
/// grows: a render with none clears it but never restarts the count, so two precomputes of the same
/// tree are two ids and each gets its own first check in `useDiffFreshness`.
export function usePrecomputedFingerprint(): [
  { fingerprint: string; id: number } | undefined,
  (fingerprint: string | undefined) => void,
] {
  const [precomputed, setPrecomputed] = useState<{ fingerprint: string; id: number }>();
  const count = useRef(0);
  const prepared = useCallback((fingerprint: string | undefined) => {
    setPrecomputed(fingerprint === undefined ? undefined : { fingerprint, id: (count.current += 1) });
  }, []);
  return [precomputed, prepared];
}

/// True once the files changed since load `generation` while the reader was in the viewer. A
/// change found on coming back runs `refresh` instead, when `canRefresh` (no comment draft, no
/// commit form). Pass a stable `read` (memoized on the shown source).
///
/// `precomputed`: the fingerprint of a diff the host computed before the page asked (an agent's turn
/// ended; DiffPageRuntime+Warm.swift), the baseline instead of the first read. When the files changed
/// since, the first check runs `reconcile` (when `canRefresh`), which swaps the new diff in without
/// moving the reader, instead of showing the notice. `failedGeneration`: the generation whose
/// reconcile failed; the precomputed diff is still shown, so it is the baseline again (no second
/// reconcile), and a tree that differs shows the notice. `id` tells one precompute from the next: two
/// with the same fingerprint (the tree came back to it) each get their first comparison.
export function useDiffFreshness(
  read: (() => Promise<string | undefined>) | undefined,
  generation: number,
  canRefresh: () => boolean,
  refresh: () => void,
  onUnavailable?: (reason: string | undefined) => void,
  precomputed?: {
    fingerprint: string | undefined;
    id?: number;
    reconcile: () => void;
    failedGeneration?: number | null;
  },
): boolean {
  // The generation found stale, and the reader (one per shown source) that found it: another source
  // keeps the generation (reset-diff), so the reader tells its notice from the last source's.
  const [stale, setStale] = useState<{ generation: number; read: typeof read }>();
  const baseline = useRef<string | undefined>(undefined);
  // A precomputed fingerprint is the baseline of one check only: a later load (the reconcile's own,
  // a Refresh) starts from what it read, so a generation change never reconciles again.
  const consumed = useRef<string | undefined>(undefined);
  const precomputedKey =
    precomputed?.fingerprint === undefined ? undefined : `${precomputed.id ?? 0}:${precomputed.fingerprint}`;
  const latest = useSyncedRef({ canRefresh, refresh, onUnavailable, reconcile: precomputed?.reconcile });
  const precomputedFingerprint = precomputed?.fingerprint;
  const reconcileFailed = precomputed?.failedGeneration === generation;
  useEffect(() => {
    let first = precomputedKey !== undefined && consumed.current !== precomputedKey;
    baseline.current = first || reconcileFailed ? precomputedFingerprint : undefined;
    if (reconcileFailed) first = false;
    latest.current.onUnavailable?.(undefined);
    if (!read) return;
    let current = true;
    let busy = false;
    const check = async (returning: boolean) => {
      if (busy || document.visibilityState === "hidden") return;
      busy = true;
      try {
        const now = await read();
        if (!current || now === undefined) return;
        latest.current.onUnavailable?.(undefined);
        const reconcile = first ? latest.current.reconcile : undefined;
        if (first) consumed.current = precomputedKey;
        first = false;
        if (baseline.current === undefined) baseline.current = now;
        else if (now !== baseline.current) {
          if (reconcile && latest.current.canRefresh()) {
            // The reconcile's render is a new generation, whose first read is its baseline.
            reconcile();
          } else if (returning && latest.current.canRefresh()) latest.current.refresh();
          else setStale({ generation, read });
        }
      } catch (error) {
        // Keep the patch and drafts while the machine is unavailable; a successful read clears
        // the host's localized reason, even when its fingerprint has not changed.
        if (current && isPageError(error) && error.code.startsWith("cmux.diff.machine_")) {
          latest.current.onUnavailable?.(error.message);
        }
        // Other repository failures retry on the next check as before.
      } finally {
        busy = false;
      }
    };
    void check(false);
    let timer: ReturnType<typeof setInterval> | undefined;
    const schedule = (focused: boolean) => {
      clearInterval(timer);
      timer = undefined;
      if (document.visibilityState === "hidden") return;
      timer = setInterval(() => void check(false), focused ? FRESHNESS_INTERVAL : UNFOCUSED_FRESHNESS_INTERVAL);
    };
    schedule(document.hasFocus());
    const back = () => {
      schedule(true);
      void check(true);
    };
    const blur = () => schedule(false);
    const visible = () => {
      schedule(document.hasFocus());
      if (document.visibilityState === "visible") void check(true);
    };
    window.addEventListener("focus", back);
    window.addEventListener("blur", blur);
    document.addEventListener("visibilitychange", visible);
    return () => {
      current = false;
      clearInterval(timer);
      window.removeEventListener("focus", back);
      window.removeEventListener("blur", blur);
      document.removeEventListener("visibilitychange", visible);
    };
  }, [read, generation, latest, precomputedFingerprint, precomputedKey, reconcileFailed]);
  return stale?.generation === generation && stale.read === read;
}
