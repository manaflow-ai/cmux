// The diff tab's Plain English toggle (PlainEnglishView.tsx): whether a harness here can write
// the sentences (`cmux.diff.summaryCheck`, asked once per page), the tab's sentence store, and
// the files it reads. A host that serves no summary op keeps the toggle off with its reason.
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { DiffItem } from "../diff-stream";
import { diffPageClient, diffPageServes, type DiffPageConfig } from "../diff/page";
import { PLAIN_ENGLISH_MENU_ONLY, type PlainEnglishPill } from "../toolbar-model";
import {
  availabilityFromCheck,
  DIFF_PAGE_SUMMARY_CHECK_OP,
  DIFF_PAGE_SUMMARY_OP,
  type HunkRef,
  type PlainEnglishAvailability,
  SummaryStore,
  summaryText,
} from "./hunkSummaries";
import type { PlainEnglishFile } from "./PlainEnglishView";

export function usePlainEnglish({
  config,
  items,
  onOpenInDiff,
}: {
  config: DiffPageConfig;
  items: readonly DiffItem[];
  /** Back to the code at a hunk's first changed line. */
  onOpenInDiff: (itemId: string, lineNumber: number, side: "additions" | "deletions") => void;
}) {
  const serves = diffPageServes(config, DIFF_PAGE_SUMMARY_OP) && diffPageServes(config, DIFF_PAGE_SUMMARY_CHECK_OP);
  const [availability, setAvailability] = useState<PlainEnglishAvailability>(
    serves ? { kind: "checking" } : { kind: "unavailable", reasonKey: "plainEnglishNeedsHost" },
  );
  const [on, setOn] = useState(false);
  useEffect(() => {
    const page = diffPageClient();
    if (!serves || !page) {
      setAvailability({ kind: "unavailable", reasonKey: "plainEnglishNeedsHost" });
      return;
    }
    let current = true;
    setAvailability({ kind: "checking" });
    page.call<unknown>(DIFF_PAGE_SUMMARY_CHECK_OP, {}).then(
      (answer) => current && setAvailability(availabilityFromCheck(answer)),
      () => current && setAvailability({ kind: "unavailable", reasonKey: "plainEnglishUnavailable" }),
    );
    return () => {
      current = false;
    };
  }, [serves]);
  // One store per tab: the sentences it was told stay while the toggle goes off and on.
  const store = useMemo(
    () =>
      new SummaryStore(async (path, patch) => {
        const page = diffPageClient();
        if (!page) throw new Error("no host");
        const text = summaryText(await page.call<unknown>(DIFF_PAGE_SUMMARY_OP, { path, patch }));
        if (text == null) throw new Error("no sentence");
        return text;
      }),
    [],
  );
  useEffect(() => () => store.close(), [store]);
  const ready = availability.kind === "ready";
  const shown = on && ready;
  // Off: nothing on screen wants a sentence, so the queue empties.
  useEffect(() => {
    if (!shown) store.want([]);
  }, [shown, store]);
  const files = useMemo<PlainEnglishFile[]>(
    () =>
      shown
        ? items.flatMap((item) => (item.fileDiff?.hunks ? [{ itemId: item.id, fileDiff: item.fileDiff }] : []))
        : [],
    [items, shown],
  );
  const toggle = useCallback(() => {
    if (ready) setOn((value) => !value);
  }, [ready]);
  const openRef = useRef(onOpenInDiff);
  openRef.current = onOpenInDiff;
  const openInDiff = useCallback(
    (ref: HunkRef) => {
      const item = items.find((candidate) => candidate.id === ref.itemId);
      const hunk = item?.fileDiff?.hunks?.[ref.index];
      setOn(false);
      if (!hunk) return;
      if (hunk.additionCount > 0) openRef.current(ref.itemId, hunk.additionStart, "additions");
      else openRef.current(ref.itemId, hunk.deletionStart, "deletions");
    },
    [items],
  );
  const menuOnly = useSyncExternalStore(subscribeMenuOnly, menuOnlyNow, () => false);
  const pill = useMemo<PlainEnglishPill>(
    () => ({ on: shown, availability, menuOnly }),
    [shown, availability, menuOnly],
  );
  return { on: shown, pill, toggle, store, files, openInDiff };
}

const menuOnlyQuery = () => (typeof window === "undefined" ? undefined : window.matchMedia?.(PLAIN_ENGLISH_MENU_ONLY));
const menuOnlyNow = () => menuOnlyQuery()?.matches ?? false;
function subscribeMenuOnly(changed: () => void): () => void {
  const query = menuOnlyQuery();
  query?.addEventListener("change", changed);
  return () => query?.removeEventListener("change", changed);
}
