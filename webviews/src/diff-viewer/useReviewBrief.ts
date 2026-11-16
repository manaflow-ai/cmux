// The diff tab's review brief (review-brief/): asked of the host (`cmux.diff.brief`, which relays
// to acpmux) once per repository and diff generation. acpmux keeps the brief beside the chat's log,
// so an ask after a refresh reads only what the chat logged since. A host that serves no brief, or
// a tab no chat owns, asks nothing.
import { useEffect, useRef, useState } from "react";
import { diffPageClient } from "../diff/page";
import { parseReviewBrief } from "../review-brief/model";
import type { ReviewBriefState } from "../review-brief/ReviewBrief";

export const DIFF_PAGE_BRIEF_OP = "cmux.diff.brief";

export function useReviewBrief({
  enabled,
  repoRoot,
  generation,
}: {
  enabled: boolean;
  repoRoot: string | null | undefined;
  /** The diff's render generation: a refresh asks again. */
  generation: number;
}): ReviewBriefState | null {
  const [state, setState] = useState<ReviewBriefState | null>(enabled && repoRoot ? { kind: "loading" } : null);
  const shownRoot = useRef(repoRoot);
  useEffect(() => {
    const page = diffPageClient();
    if (!enabled || !repoRoot || !page) {
      setState(null);
      return;
    }
    let current = true;
    // A refresh keeps the brief it shows until the new one arrives: no flash back to loading. Another
    // repository's brief is not kept.
    const sameRoot = shownRoot.current === repoRoot;
    shownRoot.current = repoRoot;
    setState((shown) => (sameRoot && shown?.kind === "ready" ? shown : { kind: "loading" }));
    page.call<unknown>(DIFF_PAGE_BRIEF_OP, { repoRoot }).then(
      (answer) => {
        if (!current) return;
        const brief = parseReviewBrief(answer);
        setState(brief ? { kind: "ready", brief } : { kind: "failed" });
      },
      () => {
        if (current) setState((shown) => (shown?.kind === "ready" ? shown : { kind: "failed" }));
      },
    );
    return () => {
      current = false;
    };
  }, [enabled, repoRoot, generation]);
  return state;
}
