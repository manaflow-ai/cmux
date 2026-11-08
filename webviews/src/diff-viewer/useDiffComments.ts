// Owns the diff viewer's review comments: saving, deleting and submitting them through the host
// bridge or locally, and posting a review worktree's drafts to its pull request.
import type { SelectedLineRange } from "@pierre/diffs";
import { useCallback, useEffect, useRef, useState } from "react";
import { lineTextFor, type CommentFileDiff } from "../comments/anchor";
import {
  DiffCommentsBridgeError,
  deleteComment as bridgeDeleteComment,
  postComments as bridgePostComments,
  saveComment as bridgeSaveComment,
  sendComments as bridgeSendComments,
} from "../comments/bridge";
import { commentSubmissionText, commentsPromptText } from "../comments/format";
import type {
  CommentsPostState,
  CommentsSendState,
  DiffCommentRecord,
  DiffCommentSide,
  DiffReviewPosted,
  DiffReviewTarget,
} from "../comments/types";
import { fileName, type DiffItem } from "../diff-stream";
import { type AppAction, type AppState } from "./state";
import { useSyncedRef } from "./useSyncedRef";

/**
 * Bundles the diff comment handlers: loading persisted comments, opening a
 * draft from the gutter utility, and saving/editing/deleting. Saved comments
 * carry a precomputed `submissionText`; native code pools them per workspace
 * and consumes the pool on TextBox submit. A host that sends to the diff's
 * chat (`canSend`) takes every saved comment as one prompt (`send`) and clears
 * them once the chat took it. A review worktree's (`review`, from the host's list) posts them to
 * its pull request as one GitHub review (`post`) and clears them once GitHub took it.
 */
/** One Send as it went out: the comments, their versions, the prompt and its id. */
type SendBatch = { ids: string[]; versions: Record<string, string>; text: string; opid: string };
/** One Post as it went out: the comments, their versions and its id. */
type PostBatch = { ids: string[]; versions: Record<string, string>; opid: string };

/**
 * The batch a press sends: the repository's unfinished one while every comment in it is listed
 * unchanged (its id then makes the host apply it once), else a fresh one of every listed comment.
 */
function nextBatch<Batch extends { ids: string[]; versions: Record<string, string> }>(
  pending: Batch | undefined,
  comments: readonly DiffCommentRecord[],
  fresh: (ids: string[], versions: Record<string, string>) => Batch,
): Batch {
  const listed = new Map(comments.map((comment) => [comment.id, comment.updatedAt]));
  if (pending != null && pending.ids.every((id) => listed.get(id) === pending.versions[id])) return pending;
  return fresh(
    comments.map((comment) => comment.id),
    Object.fromEntries(comments.map((comment) => [comment.id, comment.updatedAt])),
  );
}

export function useDiffComments({
  bridgeAvailable,
  canPostReview = true,
  canSend,
  dispatch,
  latestState,
  repoRoot,
}: {
  bridgeAvailable: boolean;
  /** The host can post a review as the person (`payload.reviewPost`); false on another machine. */
  canPostReview?: boolean;
  canSend: boolean;
  dispatch: React.Dispatch<AppAction>;
  latestState: React.MutableRefObject<AppState>;
  repoRoot: string | null;
}) {
  const activeRepoRoot = useSyncedRef(repoRoot);
  const [sendState, setSendState] = useState<CommentsSendState>("idle");
  // The pull request this worktree reviews (absent for an ordinary one), and its last post.
  const [review, setReview] = useState<DiffReviewTarget | undefined>(undefined);
  const [postState, setPostState] = useState<CommentsPostState>("idle");
  const [posted, setPosted] = useState<DiffReviewPosted | undefined>(undefined);
  const [postError, setPostError] = useState<string | undefined>(undefined);
  // Each repository's last send that did not finish, as sent: the chat may have taken it before
  // the host failed to clear its comments, so the next Send there sends that same batch under the
  // same prompt id (acpmux answers a repeated id with its first delivery) while its comments are
  // listed unchanged; one added or edited since waits for the press after.
  const pendingSends = useRef(new Map<string, SendBatch>());
  // The same for Post: a post GitHub took whose reply was lost is posted again under its opid, which
  // the host answers with the first post's review instead of a second review on the pull request.
  // A reopened page has no batch, but makes the same opid from the same drafts (`postOpid`).
  const pendingPosts = useRef(new Map<string, PostBatch>());
  // The draft save on its way, by draft and message: pressing Comment again on the same text reuses
  // its opid, so the host stores the comment once.
  const draftSave = useRef<{ draft: unknown; message: string; opid: string } | null>(null);
  // Saves on their way to the host: a post waits for them, so it never overtakes an edit the
  // person saved just before clicking Post (the post goes on a connection of its own).
  const saving = useRef(new Set<Promise<unknown>>());
  const tracked = <T,>(save: Promise<T>): Promise<T> => {
    saving.current.add(save);
    const settle = () => saving.current.delete(save);
    save.then(settle, settle);
    return save;
  };
  // Another repository: its Send and Post start idle.
  useEffect(() => {
    setSendState("idle");
    setPostState("idle");
    setPosted(undefined);
    setPostError(undefined);
  }, [repoRoot]);
  const onLoaded = useCallback(
    (comments: DiffCommentRecord[], loadedReview?: DiffReviewTarget) => {
      dispatch({ type: "replace-comments", comments });
      setReview(loadedReview);
    },
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

  // A draft saved or edited after a post is not on GitHub yet: the header stops saying "Posted".
  const drafted = () => {
    setPostState((state) => (state === "posted" ? "idle" : state));
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
    const save = tracked(
      bridgeAvailable && repoRoot != null
        ? bridgeSaveComment(repoRoot, record, opid)
        : Promise.resolve(localCommentRecord(record)),
    );
    save
      .then((saved) => {
        if (activeRepoRoot.current !== repoRoot) {
          return;
        }
        dispatch({ type: "upsert-comment", comment: saved });
        dispatch({ type: "set-draft", draft: null });
        drafted();
      })
      .catch((error) => console.warn("cmux diff comment save failed", error));
  };

  const editMessage = (comment: DiffCommentRecord, message: string, fileDiff: CommentFileDiff | null | undefined) => {
    if (message.trim() === "") {
      return;
    }
    const edited = { ...comment, message, updatedAt: new Date().toISOString() };
    const updated = { ...edited, submissionText: commentSubmissionText(edited, fileDiff) };
    const save = tracked(
      bridgeAvailable && repoRoot != null ? bridgeSaveComment(repoRoot, updated) : Promise.resolve(updated),
    );
    save
      .then((saved) => {
        if (activeRepoRoot.current === repoRoot) {
          dispatch({ type: "upsert-comment", comment: saved });
          drafted();
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
    const batch = nextBatch(pendingSends.current.get(targetRepoRoot), comments, (ids, versions) => ({
      ids,
      versions,
      text: commentsPromptText(comments),
      opid: `diff-comments-${crypto.randomUUID()}`,
    }));
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
        removeUnchanged(cleared, batch.versions);
        setSendState("idle");
      })
      .catch((error) => {
        console.warn("cmux diff comments send failed", error);
        setSendState(activeRepoRoot.current === targetRepoRoot ? "failed" : "idle");
      });
  };

  const removeUnchanged = (cleared: readonly string[], versions: Record<string, string>) => {
    const current = new Map(latestState.current.comments.map((comment) => [comment.id, comment.updatedAt]));
    const ids = cleared.filter((id) => current.get(id) === versions[id]);
    if (ids.length > 0) dispatch({ type: "remove-comments", ids });
  };

  /** Posts every saved comment to the worktree's pull request as one review, as `send` sends; after
   * any save still on its way, so the review has the wording the person saved. */
  const post = () => {
    const saves = [...saving.current];
    if (saves.length === 0) return postBatch(false);
    if (postState === "posting") return;
    setPostState("posting");
    void Promise.allSettled(saves).then(() => {
      setPostState("idle");
      postBatch(false);
    });
  };

  /** `post`; `fresh` skips the unfinished batch, which the host said never reached GitHub. */
  const postBatch = (fresh: boolean): void => {
    const comments = latestState.current.comments;
    if (review == null || !bridgeAvailable || repoRoot == null || comments.length === 0 || postState === "posting") {
      return;
    }
    const targetRepoRoot = repoRoot;
    // A post that may have reached GitHub is retried under its own opid while any of its drafts is
    // still listed, edited or not: the host finds the review that opid posted (its marker) instead of
    // posting the same drafts again under a new one; a draft edited since stays for the next post.
    const pending = fresh ? undefined : (pendingPosts.current.get(targetRepoRoot) ?? storedPost(targetRepoRoot));
    const listed = new Set(comments.map((comment) => comment.id));
    const batch =
      pending != null && pending.ids.some((id) => listed.has(id))
        ? pending
        : nextBatch(undefined, comments, (ids, versions) => ({
            ids,
            versions,
            opid: postOpid(targetRepoRoot, ids, versions),
          }));
    pendingPosts.current.set(targetRepoRoot, batch);
    storePost(targetRepoRoot, batch);
    setPostState("posting");
    setPostError(undefined);
    bridgePostComments(targetRepoRoot, batch.ids, batch.versions, batch.opid)
      .then(({ cleared, ...result }) => {
        pendingPosts.current.delete(targetRepoRoot);
        storePost(targetRepoRoot, undefined);
        if (activeRepoRoot.current !== targetRepoRoot) return setPostState("idle");
        // As with a send: a draft edited while the review was on its way stays, with its edit.
        removeUnchanged(cleared, batch.versions);
        setPosted(result);
        setPostState("posted");
      })
      .catch((error: unknown) => {
        console.warn("cmux diff review post failed", error);
        if (activeRepoRoot.current !== targetRepoRoot) return setPostState("idle");
        // The host found no review under this opid and none of its drafts unchanged: nothing of it
        // reached GitHub, so the drafts as they are now go as a new review.
        if (
          !fresh &&
          batch === pending &&
          error instanceof DiffCommentsBridgeError &&
          error.reason === "nothing_to_post"
        ) {
          pendingPosts.current.delete(targetRepoRoot);
          storePost(targetRepoRoot, undefined);
          setPostState("idle");
          postBatch(true);
          return;
        }
        // gh's own words say what to fix (a login, a moved head); the drafts stay for the retry.
        setPostError(error instanceof Error && error.message !== "" ? error.message : undefined);
        setPostState("failed");
      });
  };

  return {
    canPost: review != null && bridgeAvailable && canPostReview,
    canSend: canSend && bridgeAvailable,
    editMessage,
    onGutterUtilityClick,
    onLoaded,
    post,
    postError,
    posted,
    postState,
    remove,
    review,
    saveDraft,
    send,
    sendState,
  };
}

/**
 * A post that may have reached GitHub outlives the page: kept in the page's storage until its
 * answer comes, so a page reopened after a lost reply retries that batch under its opid before
 * any draft added since goes out, and the host finds the review it may have posted.
 */
const POST_STORAGE_PREFIX = "cmux.diff.reviewPost:";

function storedPost(repoRoot: string): PostBatch | undefined {
  try {
    const text = globalThis.localStorage?.getItem(POST_STORAGE_PREFIX + repoRoot);
    const batch = text == null ? undefined : (JSON.parse(text) as Partial<PostBatch>);
    if (batch == null || !Array.isArray(batch.ids) || typeof batch.opid !== "string") return undefined;
    return { ids: batch.ids.map(String), versions: { ...batch.versions }, opid: batch.opid };
  } catch {
    return undefined;
  }
}

function storePost(repoRoot: string, batch: PostBatch | undefined) {
  try {
    if (batch == null) globalThis.localStorage?.removeItem(POST_STORAGE_PREFIX + repoRoot);
    else globalThis.localStorage?.setItem(POST_STORAGE_PREFIX + repoRoot, JSON.stringify(batch));
  } catch {
    // No storage (a private page): the batch lives as long as the page.
  }
}

/**
 * A post's opid, from what it posts: the same drafts at the same versions get the same one, so a
 * page reopened after a post whose reply was lost retries under its key, and the host finds the
 * review it may have posted instead of posting it again. Drafts posted are cleared, so the same
 * drafts never go out as a second review on purpose.
 */
function postOpid(repoRoot: string, ids: readonly string[], versions: Record<string, string>): string {
  const text = [repoRoot, ...[...ids].sort().map((id) => `${id}@${versions[id] ?? ""}`)].join("\n");
  // Two FNV-1a hashes of the text, 64 bits together: a key, not a secret.
  const hash = (seed: number) => {
    let value = seed;
    for (let index = 0; index < text.length; index += 1) {
      value = Math.imul(value ^ text.charCodeAt(index), 16777619) >>> 0;
    }
    return value.toString(16).padStart(8, "0");
  };
  return `diff-review-${hash(2166136261)}${hash(84696351)}`;
}

function localCommentRecord(input: Omit<DiffCommentRecord, "id" | "createdAt" | "updatedAt">): DiffCommentRecord {
  const now = new Date().toISOString();
  return { ...input, id: crypto.randomUUID(), createdAt: now, updatedAt: now };
}
