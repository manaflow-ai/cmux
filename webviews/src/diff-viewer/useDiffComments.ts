// Owns the diff viewer's review comments: saving, deleting and submitting them through the host
// bridge or locally.
import type { SelectedLineRange } from "@pierre/diffs";
import { useCallback } from "react";
import { lineTextFor, type CommentFileDiff } from "../comments/anchor";
import { deleteComment as bridgeDeleteComment, saveComment as bridgeSaveComment } from "../comments/bridge";
import { commentSubmissionText } from "../comments/format";
import type { DiffCommentRecord, DiffCommentSide } from "../comments/types";
import { fileName, type DiffItem } from "../diff-stream";
import { type AppAction, type AppState } from "./state";
import { useSyncedRef } from "./useSyncedRef";

/**
 * Bundles the diff comment handlers: loading persisted comments, opening a
 * draft from the gutter utility, and saving/editing/deleting. Saved comments
 * carry a precomputed `submissionText`; native code pools them per workspace
 * and consumes the pool on TextBox submit.
 */
export function useDiffComments({
  bridgeAvailable,
  dispatch,
  latestState,
  repoRoot,
}: {
  bridgeAvailable: boolean;
  dispatch: React.Dispatch<AppAction>;
  latestState: React.MutableRefObject<AppState>;
  repoRoot: string | null;
}) {
  const activeRepoRoot = useSyncedRef(repoRoot);
  const onLoaded = useCallback(
    (comments: DiffCommentRecord[]) => dispatch({ type: "replace-comments", comments }),
    [dispatch],
  );

  const onGutterUtilityClick = (range: SelectedLineRange, context: { item: DiffItem }) => {
    const side: DiffCommentSide = range.side === "deletions" ? "deletions" : "additions";
    dispatch({
      type: "set-draft",
      draft: {
        itemId: context.item.id,
        side,
        startLine: Math.min(range.start, range.end),
        endLine: Math.max(range.start, range.end),
      },
    });
  };

  const saveDraft = (item: DiffItem, message: string) => {
    const draft = latestState.current.draft;
    if (draft == null || draft.itemId !== item.id || message.trim() === "") {
      return;
    }
    const input = {
      filePath: fileName(item.fileDiff, ""),
      side: draft.side,
      startLine: draft.startLine,
      endLine: draft.endLine,
      lineText: lineTextFor(item.fileDiff, draft.side, draft.endLine) ?? "",
      message,
    };
    const record = { ...input, submissionText: commentSubmissionText(input, item.fileDiff) };
    const save =
      bridgeAvailable && repoRoot != null
        ? bridgeSaveComment(repoRoot, record)
        : Promise.resolve(localCommentRecord(record));
    save
      .then((saved) => {
        if (activeRepoRoot.current !== repoRoot) {
          return;
        }
        dispatch({ type: "upsert-comment", comment: saved });
        dispatch({ type: "set-draft", draft: null });
      })
      .catch((error) => console.warn("cmux diff comment save failed", error));
  };

  const editMessage = (comment: DiffCommentRecord, message: string, fileDiff: CommentFileDiff | null | undefined) => {
    if (message.trim() === "") {
      return;
    }
    const edited = { ...comment, message, updatedAt: new Date().toISOString() };
    const updated = { ...edited, submissionText: commentSubmissionText(edited, fileDiff) };
    const save = bridgeAvailable && repoRoot != null ? bridgeSaveComment(repoRoot, updated) : Promise.resolve(updated);
    save
      .then((saved) => {
        if (activeRepoRoot.current === repoRoot) {
          dispatch({ type: "upsert-comment", comment: saved });
        }
      })
      .catch((error) => console.warn("cmux diff comment edit failed", error));
  };

  const remove = (comment: DiffCommentRecord) => {
    const targetRepoRoot = repoRoot;
    if (bridgeAvailable && repoRoot != null) {
      bridgeDeleteComment(repoRoot, comment.id).catch((error) =>
        console.warn("cmux diff comment delete failed", error),
      );
    }
    if (activeRepoRoot.current === targetRepoRoot) {
      dispatch({ type: "remove-comment", id: comment.id });
    }
  };

  return { editMessage, onGutterUtilityClick, onLoaded, remove, saveDraft };
}

function localCommentRecord(input: Omit<DiffCommentRecord, "id" | "createdAt" | "updatedAt">): DiffCommentRecord {
  const now = new Date().toISOString();
  return { ...input, id: crypto.randomUUID(), createdAt: now, updatedAt: now };
}
