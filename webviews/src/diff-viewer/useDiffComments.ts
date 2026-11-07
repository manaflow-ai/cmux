// Owns the diff viewer's review comments: saving, deleting and submitting them through the host
// bridge or locally.
import type { SelectedLineRange } from "@pierre/diffs";
import { useCallback, useEffect, useRef, useState } from "react";
import { lineTextFor, type CommentFileDiff } from "../comments/anchor";
import {
  deleteComment as bridgeDeleteComment,
  saveComment as bridgeSaveComment,
  sendComments as bridgeSendComments,
} from "../comments/bridge";
import { commentSubmissionText, commentsPromptText } from "../comments/format";
import type { CommentsSendState, DiffCommentRecord, DiffCommentSide } from "../comments/types";
import { fileName, type DiffItem } from "../diff-stream";
import { type AppAction, type AppState } from "./state";
import { useSyncedRef } from "./useSyncedRef";

/**
 * Bundles the diff comment handlers: loading persisted comments, opening a
 * draft from the gutter utility, and saving/editing/deleting. Saved comments
 * carry a precomputed `submissionText`; native code pools them per workspace
 * and consumes the pool on TextBox submit. A host that sends to the diff's
 * chat (`canSend`) takes every saved comment as one prompt (`send`) and clears
 * them once the chat took it.
 */
/** One Send as it went out: the comments, their versions, the prompt and its id. */
type SendBatch = { ids: string[]; versions: Record<string, string>; text: string; opid: string };

export function useDiffComments({
  bridgeAvailable,
  canSend,
  dispatch,
  latestState,
  repoRoot,
}: {
  bridgeAvailable: boolean;
  canSend: boolean;
  dispatch: React.Dispatch<AppAction>;
  latestState: React.MutableRefObject<AppState>;
  repoRoot: string | null;
}) {
  const activeRepoRoot = useSyncedRef(repoRoot);
  const [sendState, setSendState] = useState<CommentsSendState>("idle");
  // Each repository's last send that did not finish, as sent: the chat may have taken it before
  // the host failed to clear its comments, so the next Send there sends that same batch under the
  // same prompt id (acpmux answers a repeated id with its first delivery) while its comments are
  // listed unchanged; one added or edited since waits for the press after.
  const pendingSends = useRef(new Map<string, SendBatch>());
  // The draft save on its way, by draft and message: pressing Comment again on the same text reuses
  // its opid, so the host stores the comment once.
  const draftSave = useRef<{ draft: unknown; message: string; opid: string } | null>(null);
  // Another repository: its Send starts idle.
  useEffect(() => setSendState("idle"), [repoRoot]);
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
    const prior = draftSave.current;
    const opid =
      prior?.draft === draft && prior.message === message ? prior.opid : `diff-comment-${crypto.randomUUID()}`;
    draftSave.current = { draft, message, opid };
    const save =
      bridgeAvailable && repoRoot != null
        ? bridgeSaveComment(repoRoot, record, opid)
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
      // The comment leaves the page at once; if the host could not delete it, it comes back: it is
      // still stored (and still goes to the agent with the next submit), so the page must not say
      // it is gone.
      bridgeDeleteComment(repoRoot, comment.id).catch((error) => {
        console.warn("cmux diff comment delete failed", error);
        if (activeRepoRoot.current === targetRepoRoot) dispatch({ type: "upsert-comment", comment });
      });
    }
    if (activeRepoRoot.current === targetRepoRoot) {
      dispatch({ type: "remove-comment", id: comment.id });
    }
  };

  const send = () => {
    const comments = latestState.current.comments;
    if (!canSend || !bridgeAvailable || repoRoot == null || comments.length === 0 || sendState === "sending") {
      return;
    }
    const targetRepoRoot = repoRoot;
    const listed = new Map(comments.map((comment) => [comment.id, comment.updatedAt]));
    const pending = pendingSends.current.get(targetRepoRoot);
    const batch: SendBatch =
      pending != null && pending.ids.every((id) => listed.get(id) === pending.versions[id])
        ? pending
        : {
            ids: comments.map((comment) => comment.id),
            versions: Object.fromEntries(comments.map((comment) => [comment.id, comment.updatedAt])),
            text: commentsPromptText(comments),
            opid: `diff-comments-${crypto.randomUUID()}`,
          };
    pendingSends.current.set(targetRepoRoot, batch);
    setSendState("sending");
    bridgeSendComments(targetRepoRoot, batch.ids, batch.versions, batch.text, batch.opid)
      .then((cleared) => {
        pendingSends.current.delete(targetRepoRoot);
        // Another repository is shown now: its button is idle; the sent one lists what the host kept
        // when it is shown again.
        if (activeRepoRoot.current !== targetRepoRoot) return setSendState("idle");
        // Only the comments sent and unchanged since leave, together; one saved or edited while the
        // send was on its way stays for the next send.
        const current = new Map(latestState.current.comments.map((comment) => [comment.id, comment.updatedAt]));
        const ids = cleared.filter((id) => current.get(id) === batch.versions[id]);
        if (ids.length > 0) dispatch({ type: "remove-comments", ids });
        setSendState("idle");
      })
      .catch((error) => {
        console.warn("cmux diff comments send failed", error);
        setSendState(activeRepoRoot.current === targetRepoRoot ? "failed" : "idle");
      });
  };

  return {
    canSend: canSend && bridgeAvailable,
    editMessage,
    onGutterUtilityClick,
    onLoaded,
    remove,
    saveDraft,
    send,
    sendState,
  };
}

function localCommentRecord(input: Omit<DiffCommentRecord, "id" | "createdAt" | "updatedAt">): DiffCommentRecord {
  const now = new Date().toISOString();
  return { ...input, id: crypto.randomUUID(), createdAt: now, updatedAt: now };
}
