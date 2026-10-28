import { postNative } from "./native";
import { pageHostClient } from "./pageHost";
import type { QueuedPrompt } from "./model";
import { holdWebSwap } from "../../pages/shared/webSwap";

/** Client view state only. The daemon still owns the queued prompt and its attachment bytes. */
export type QueuedEditDraft = {
  revision: string;
  originalPrompt: string;
  originalImages: string[];
  text: string;
  droppedImages: string[];
};

type Write = { sessionId: string; promptId: string } & ({ draft: QueuedEditDraft } | { revision: string });
const pending = new Map<string, Write>();
let drain: Promise<void> | undefined;
holdWebSwap(() => (pending.size || drain ? "composer.queue-edit-unsaved" : null));

function enqueue(write: Write): void {
  // Browser galleries have no native store and must never hold a web update for one.
  if (!pageHostClient() && !globalThis.window?.webkit?.messageHandlers?.agentSession) return;
  const key = JSON.stringify([write.sessionId, write.promptId]);
  const queued = pending.get(key);
  // An old RPC's acknowledgement cannot replace a newer keystroke waiting for the host.
  if (!("draft" in write) && queued && "draft" in queued && queued.draft.revision !== write.revision) return;
  pending.set(key, write);
  void settleQueuedEditWrites();
}

/** Native requests are ordered, coalescing keystrokes while an earlier write is in flight. Failed
 * writes stay pending for the quit/web-swap flush, and never let a web update silently lose them. */
export function settleQueuedEditWrites(): Promise<void> {
  if (drain) return drain;
  drain = Promise.resolve().then(async () => {
    try {
      while (pending.size) {
        const [key, write] = pending.entries().next().value!;
        try {
          await postNative("draft" in write ? "chat.queuedEditDrafts.set" : "chat.queuedEditDrafts.clear", write);
        } catch {
          break;
        }
        if (pending.get(key) === write) pending.delete(key);
      }
    } finally {
      drain = undefined;
    }
  });
  return drain;
}

export function keepQueuedEdit(sessionId: string | undefined, promptId: string, draft: QueuedEditDraft): void {
  if (sessionId) enqueue({ sessionId, promptId, draft });
}

export function clearQueuedEdit(sessionId: string | undefined, promptId: string, revision: string): void {
  if (sessionId) enqueue({ sessionId, promptId, revision });
}

export async function readQueuedEdits(sessionId: string): Promise<Record<string, QueuedEditDraft>> {
  await settleQueuedEditWrites();
  try {
    const saved = await postNative<unknown>("chat.queuedEditDrafts.get", { sessionId });
    if (!saved || typeof saved !== "object" || Array.isArray(saved)) return {};
    return Object.fromEntries(Object.entries(saved).filter(([, draft]) => valid(draft)));
  } catch {
    return {};
  }
}

function valid(value: unknown): value is QueuedEditDraft {
  if (!value || typeof value !== "object") return false;
  const draft = value as QueuedEditDraft;
  const strings = (list: unknown): list is string[] =>
    Array.isArray(list) && list.every((id) => typeof id === "string");
  return (
    typeof draft.revision === "string" &&
    typeof draft.originalPrompt === "string" &&
    typeof draft.text === "string" &&
    strings(draft.originalImages) &&
    strings(draft.droppedImages)
  );
}

export function newQueuedEdit(entry: QueuedPrompt, text = entry.prompt, droppedImages: string[] = []): QueuedEditDraft {
  return {
    revision: crypto.randomUUID(),
    originalPrompt: entry.prompt,
    originalImages: (entry.images ?? []).map((image) => image.id),
    text,
    droppedImages,
  };
}

/** Never apply a recovered edit over a newer daemon edit, a resend, or another author's prompt. */
export function queuedEditMatches(draft: QueuedEditDraft, entry: QueuedPrompt): boolean {
  return (
    entry.author === undefined &&
    !entry.message &&
    !entry.next &&
    !entry.sending &&
    entry.prompt === draft.originalPrompt &&
    JSON.stringify((entry.images ?? []).map((image) => image.id)) === JSON.stringify(draft.originalImages)
  );
}
