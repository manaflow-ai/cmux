import { makeClientId } from "../agent-session/shared/ids";
import type { DiffCommentRecord, DiffCommentSaveInput } from "./types";

type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { code?: string; userMessage?: string } };

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

export function diffCommentsBridgeAvailable(): boolean {
  return diffCommentsHandler() != null;
}

async function callDiffComments<T>(method: string, params: Record<string, unknown>): Promise<T> {
  const handler = diffCommentsHandler();
  if (handler == null) {
    throw new DiffCommentsBridgeError("Diff comments bridge is unavailable.");
  }
  const reply = (await handler.postMessage({
    id: makeClientId(),
    method,
    params,
  })) as NativeReply<T>;
  if (!reply.ok) {
    throw new DiffCommentsBridgeError(
      reply.error?.userMessage || "Diff comments request failed.",
      reply.error?.code,
    );
  }
  return reply.value;
}

export async function listComments(repoRoot: string): Promise<DiffCommentRecord[]> {
  const value = await callDiffComments<{ comments?: DiffCommentRecord[] }>("comments.list", { repoRoot });
  return Array.isArray(value?.comments) ? value.comments : [];
}

export async function saveComment(
  repoRoot: string,
  comment: DiffCommentSaveInput,
): Promise<DiffCommentRecord> {
  const value = await callDiffComments<{ comment?: DiffCommentRecord }>("comments.save", { repoRoot, comment });
  if (value?.comment == null) {
    throw new DiffCommentsBridgeError("Diff comments save returned no comment.");
  }
  return value.comment;
}

export async function deleteComment(repoRoot: string, id: string): Promise<void> {
  await callDiffComments<unknown>("comments.delete", { repoRoot, id });
}
