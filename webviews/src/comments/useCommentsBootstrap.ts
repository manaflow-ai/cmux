import { useEffect, useRef } from "react";
import { listComments } from "./bridge";
import type { DiffCommentRecord } from "./types";

/**
 * Loads persisted comments once on mount when the native bridge is available
 * (repoRoot is null otherwise). Mirrors the started-ref pattern used by
 * `useRenderDiff`/`usePendingReplacement` in App.tsx.
 */
export function useCommentsBootstrap(
  repoRoot: string | null,
  onLoaded: (comments: DiffCommentRecord[]) => void,
): void {
  const started = useRef(false);
  useEffect(() => {
    if (started.current || repoRoot == null) {
      return;
    }
    started.current = true;
    listComments(repoRoot)
      .then((comments) => onLoaded(comments))
      .catch((error) => console.warn("cmux diff comments load failed", error));
  }, [onLoaded, repoRoot]);
}
