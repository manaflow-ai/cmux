import { useEffect } from "react";
import { listCommentsAndReview } from "./bridge";
import type { DiffCommentRecord, DiffReviewTarget } from "./types";

/**
 * Loads persisted comments for the active repository, with the pull request it reviews when it is
 * a review worktree. Cleanup invalidates an older load so a slow response cannot overwrite comments
 * after a repo switch; a switch first empties both, so no other worktree's pull request shows.
 */
export function useCommentsBootstrap(
  repoRoot: string | null,
  onLoaded: (comments: DiffCommentRecord[], review?: DiffReviewTarget) => void,
): void {
  useEffect(() => {
    onLoaded([]);
    if (repoRoot == null) {
      return;
    }
    let active = true;
    listCommentsAndReview(repoRoot)
      .then(({ comments, review }) => {
        if (active) {
          onLoaded(comments, review);
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
