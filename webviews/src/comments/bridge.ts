import { makeClientId } from "../agent-session/shared/ids";
import { DIFF_PAGE_COMMENTS_OP } from "../diff/page";
import { isPageError, type PageClient } from "../pages/shared/pageClient";
import type { DiffCommentRecord, DiffCommentSaveInput } from "./types";

type NativeReply<T> = { ok: true; value: T } | { ok: false; error?: { code?: string; userMessage?: string } };

type DiffCommentsMessageHandler = {
  postMessage(message: unknown): Promise<NativeReply<unknown>>;
};

export class DiffCommentsBridgeError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "DiffCommentsBridgeError";
    this.code = code;
  }
}

function diffCommentsHandler(): DiffCommentsMessageHandler | null {
  if (typeof window === "undefined") {
    return null;
  }
  const handler = (window as any).webkit?.messageHandlers?.cmuxDiffComments;
  return handler != null && typeof handler.postMessage === "function" ? handler : null;
}

// On the shared page host the same messages go to the op `cmux.diff.comments {method, params}`,
// installed at boot only when the host's config lists that op. Without it (and without the
// classic handler) the viewer hides comments, and viewed files and prefs stay local.
let pageComments: PageClient | null = null;

/** Routes comments, viewed files and viewer prefs through the page host (null removes it). */
export function installPageDiffComments(page: PageClient | null): void {
  pageComments = page;
}

export function diffCommentsBridgeAvailable(): boolean {
  return diffCommentsHandler() != null || pageComments != null;
}

export async function callDiffComments<T>(
  method: string,
  params: Record<string, unknown>,
  options: { opid?: string } = {},
): Promise<T> {
  const handler = diffCommentsHandler();
  if (handler == null) {
    if (pageComments != null) return callPageDiffComments<T>(pageComments, method, params, options.opid);
    throw new DiffCommentsBridgeError("Diff comments bridge is unavailable.");
  }
  const reply = (await handler.postMessage({
    id: makeClientId(),
    method,
    params,
  })) as NativeReply<T>;
  if (!reply.ok) {
    throw new DiffCommentsBridgeError(reply.error?.userMessage || "Diff comments request failed.", reply.error?.code);
  }
  return reply.value;
}

async function callPageDiffComments<T>(
  page: PageClient,
  method: string,
  params: Record<string, unknown>,
  opid?: string,
): Promise<T> {
  try {
    // Decision 31: a write carries its intent's opid, so the host applies a resend once.
    return await page.call<T>(DIFF_PAGE_COMMENTS_OP, { method, params }, opid === undefined ? undefined : { opid });
  } catch (error) {
    if (isPageError(error))
      throw new DiffCommentsBridgeError(error.message || "Diff comments request failed.", error.code);
    throw new DiffCommentsBridgeError(error instanceof Error ? error.message : String(error));
  }
}

export async function listComments(repoRoot: string): Promise<DiffCommentRecord[]> {
  const value = await callDiffComments<{ comments?: DiffCommentRecord[] }>("comments.list", { repoRoot });
  return Array.isArray(value?.comments) ? value.comments : [];
}

export async function saveComment(repoRoot: string, comment: DiffCommentSaveInput): Promise<DiffCommentRecord> {
  const value = await callDiffComments<{ comment?: DiffCommentRecord }>("comments.save", { repoRoot, comment });
  if (value?.comment == null) {
    throw new DiffCommentsBridgeError("Diff comments save returned no comment.");
  }
  return value.comment;
}

export async function deleteComment(repoRoot: string, id: string): Promise<void> {
  await callDiffComments<unknown>("comments.delete", { repoRoot, id });
}
