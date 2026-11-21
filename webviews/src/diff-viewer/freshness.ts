// The viewer notices edits made after it loaded (cx-9ce.34, dogfood run hq #1893): with the
// viewer open on a repository, an agent's edit there left the old diff on screen until the tab
// was reopened. The session host fingerprints the shown scope's diff (`cmux.diff.git.fingerprint`:
// digits made from the changed files, so no diff is made or crosses the bridge); the page takes one
// per load and compares while it is visible. Coming back to the viewer refreshes it when nothing
// would be lost; while the reader is in it, an inline notice offers Refresh, since a refresh starts
// the diff from the top. A session host older than the read cannot say: the page then wakes no
// timer while that host's machine answers, and each time the reader comes back it asks one time
// more and reloads the diff (FINGERPRINT_UNSUPPORTED).
import { useCallback, useEffect, useRef, useState } from "react";
import { useSyncedRef } from "./useSyncedRef";
import type { DiffSource } from "../diff/generated/protocol";
import { isPageError, type PageClient } from "../pages/shared/pageClient";

export const DIFF_FINGERPRINT_OP = "cmux.diff.git.fingerprint";
/** The host's answer for a session host older than `git.fingerprint`; it sent that host nothing. */
export const FINGERPRINT_UNSUPPORTED = "native.unsupported";
/** How often a focused viewer compares, in ms. */
export const FRESHNESS_INTERVAL = 4000;
/** Keep a visible background window current without running git every four seconds. */
export const UNFOCUSED_FRESHNESS_INTERVAL = 30_000;
/** The baseline of a shown diff that was loaded from a session host without the read: no digits equal it. */
const NO_DIGITS = "";
/** Read at each use: the page can become hidden while a read is in flight. */
const pageHidden = () => document.visibilityState === "hidden";

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
///
/// A session host older than the read (a machine that was not updated) answers
/// `FINGERPRINT_UNSUPPORTED`. Nothing can be compared then, so this page wakes no timer, and while
/// the reader stays in the viewer it gives no notice of a change. Each return to the viewer asks one
/// time more (the host sends such a session host nothing) and runs `refresh` (when `canRefresh`),
/// so the reader does not look at an old diff after coming back. One return is one `refresh`: the
/// page was away before it (it lost the focus or was hidden, or the window has no focus yet). When
/// the session host has the read at a return (it was replaced), that return runs `refresh` one time
/// (or, when `canRefresh` is false, the result is true: the shown diff can be an old one) and each
/// later return compares again; the timer starts again with that load, or when the page next loses
/// or gets the focus. Until that load the shown diff has no digits of its own: after the draft is
/// closed, the next return runs `refresh`. Refresh in the toolbar works as before.
///
/// One timer does live for such a session host: when its machine does not answer at a return (a
/// Cloud machine that is not connected), the page asks again at the interval of the checks until the
/// machine answers, so the reason of `onUnavailable` does not stay after the machine is connected
/// again. That answer ends the timer, and it is the return's answer (it runs the `refresh` that the
/// return could not). The timer also ends when the page is hidden, and none starts in a hidden page.
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
  // Set by a FINGERPRINT_UNSUPPORTED answer, until the session host answers with digits: a page
  // shows one machine's repository, and the host answers that code for the whole session host.
  const unsupported = useRef(false);
  // An older session host: the page was away since the last `refresh` that a return ran.
  const away = useRef(true);
  // An older session host whose machine did not answer at a return: the interval at which the page
  // asks again, until the machine answers. The timer is an effect of its own, so its cleanup ends it.
  const [retryEvery, setRetryEvery] = useState<number>();
  const retry = useRef<(() => void) | undefined>(undefined);
  useEffect(() => {
    if (retryEvery === undefined || !read) return;
    const timer = setInterval(() => retry.current?.(), retryEvery);
    return () => clearInterval(timer);
  }, [retryEvery, read]);
  useEffect(() => {
    let first = precomputedKey !== undefined && consumed.current !== precomputedKey;
    baseline.current = first || reconcileFailed ? precomputedFingerprint : undefined;
    if (reconcileFailed) first = false;
    latest.current.onUnavailable?.(undefined);
    if (!read) return;
    let current = true;
    let busy = false;
    let timer: ReturnType<typeof setInterval> | undefined;
    const check = async (returning: boolean) => {
      if (busy || document.visibilityState === "hidden") return;
      // An older session host is asked again only when the reader comes back.
      if (unsupported.current && !returning) return;
      busy = true;
      try {
        const now = await read();
        if (!current || now === undefined) return;
        latest.current.onUnavailable?.(undefined);
        setRetryEvery(undefined);
        if (unsupported.current) {
          // The session host has the read now. The shown diff has no digits of its own, so it is
          // loaded one time more, and `now` is the baseline of the next checks. When a load would
          // lose a draft, the notice says that the shown diff can be an old one, and no digits
          // are its baseline: the first return after the draft is closed loads it. No timer starts
          // here: the load's new generation starts it, or the next `schedule` (the page loses or
          // gets the focus, or is shown).
          unsupported.current = false;
          if (first) consumed.current = precomputedKey;
          first = false;
          if (latest.current.canRefresh()) {
            baseline.current = now;
            latest.current.refresh();
          } else {
            baseline.current = NO_DIGITS;
            setStale({ generation, read });
          }
          return;
        }
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
        if (!current) return;
        if (!isPageError(error)) return;
        if (error.code === FINGERPRINT_UNSUPPORTED) {
          // The machine is connected (its session host is only older than the read): a reason
          // from a time when it was not connected is no longer true.
          latest.current.onUnavailable?.(undefined);
          setRetryEvery(undefined);
          // Nothing was sent: stop the timer, and reload when this is a return from time away.
          unsupported.current = true;
          clearInterval(timer);
          timer = undefined;
          if (returning && away.current && latest.current.canRefresh()) {
            away.current = !document.hasFocus();
            latest.current.refresh();
          }
          return;
        }
        // Keep the patch and drafts while the machine is unavailable; a successful read clears
        // the host's localized reason, even when its fingerprint has not changed.
        if (error.code.startsWith("cmux.diff.machine_")) {
          latest.current.onUnavailable?.(error.message);
          // An older session host has no timer that asks again: one runs until its machine answers.
          // Not in a page that was hidden while this read was in flight: the return asks again.
          if (unsupported.current && !pageHidden())
            setRetryEvery(document.hasFocus() ? FRESHNESS_INTERVAL : UNFOCUSED_FRESHNESS_INTERVAL);
        }
        // Other repository failures retry on the next check as before.
      } finally {
        busy = false;
      }
    };
    void check(false);
    retry.current = () => void check(true);
    const schedule = (focused: boolean) => {
      clearInterval(timer);
      timer = undefined;
      if (unsupported.current || document.visibilityState === "hidden") return;
      timer = setInterval(() => void check(false), focused ? FRESHNESS_INTERVAL : UNFOCUSED_FRESHNESS_INTERVAL);
    };
    schedule(document.hasFocus());
    const back = () => {
      schedule(true);
      setRetryEvery((every) => (every === undefined ? undefined : FRESHNESS_INTERVAL));
      void check(true);
    };
    const blur = () => {
      away.current = true;
      schedule(false);
      setRetryEvery((every) => (every === undefined ? undefined : UNFOCUSED_FRESHNESS_INTERVAL));
    };
    const visible = () => {
      schedule(document.hasFocus());
      if (document.visibilityState === "visible") void check(true);
      else {
        away.current = true;
        // A hidden page wakes nothing (a late machine error starts no timer in it); the return
        // asks again.
        setRetryEvery(undefined);
      }
    };
    window.addEventListener("focus", back);
    window.addEventListener("blur", blur);
    document.addEventListener("visibilitychange", visible);
    return () => {
      current = false;
      retry.current = undefined;
      clearInterval(timer);
      window.removeEventListener("focus", back);
      window.removeEventListener("blur", blur);
      document.removeEventListener("visibilitychange", visible);
    };
  }, [read, generation, latest, precomputedFingerprint, precomputedKey, reconcileFailed]);
  return stale?.generation === generation && stale.read === read;
}
