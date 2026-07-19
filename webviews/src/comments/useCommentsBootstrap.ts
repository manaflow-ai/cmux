import { useEffect } from "react";
import { listComments } from "./bridge";
import type { DiffCommentRecord } from "./types";

/**
 * Loads persisted comments for the active repository. Cleanup invalidates an
 * older load so a slow response cannot overwrite comments after a repo switch.
 */
export function useCommentsBootstrap(
  repoRoot: string | null,
  onLoaded: (comments: DiffCommentRecord[]) => void,
): void {
  useEffect(() => {
    onLoaded([]);
    if (repoRoot == null) {
      return;
    }
    let active = true;
    listComments(repoRoot)
      .then((comments) => {
        if (active) {
          onLoaded(comments);
        }
      })
      .catch((error) => {
        if (active) {
          console.warn("cmux diff comments load failed", error);
        }
      });
    return () => {
      active = false;
    };
  }, [onLoaded, repoRoot]);
}
