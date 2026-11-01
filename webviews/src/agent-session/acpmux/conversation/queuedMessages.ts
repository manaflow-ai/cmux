// Another agent's message that waits in the chat's queue is not the person's prompt (Leo,
// 2026-10-25: "I don't know why these things are queued up. It's kind of strange."). It never
// draws as a composer-queue row: the transcript shows it at once as the message it is (its
// received line, IncomingMessageCard.tsx), in the one group of messages that wait
// (pendingMessages.ts), never under a "Read after this turn" (Leo, 2026-10-29: "why the fuck do you
// guys keep doing this fucking bullshit with the red after this turn?"). Its ⋯ menu is a message's,
// not the person's queue row's: Deliver now, Copy, Dismiss (QueuedMessageCard.tsx). Once acpmux
// starts it, the queue drops it and the prompt's own row is its card, delivered. The composer's queue, its fold and its count, are the person's own
// prompts alone (ComposerQueue.tsx).
import type { ComposerAttachment } from "../attachments";
import { QUEUED_MESSAGE, type AcpmuxRow, type AcpmuxSnapshot, type QueuedPromptImage } from "../model";

type QueuedEntry = AcpmuxSnapshot["queue"][number];

/// Whether a queue entry is another agent's message (direct.ts `queuedMessage` named its sender).
export const isAgentEntry = (entry: QueuedEntry) => entry.message !== undefined;

/// The person's own queued prompts, in the queue's order: the composer's queue rows.
export function ownQueue(queue: AcpmuxSnapshot["queue"]): AcpmuxSnapshot["queue"] {
  return queue.some(isAgentEntry) ? queue.filter((entry) => !isAgentEntry(entry)) : queue;
}

/// The transcript row id of queued message `promptId`.
export const queuedMessageRowId = (promptId: string) => `queued-message-${promptId}`;

// One row object per queue entry object: a memoized row draws again only when its entry changed
// (acpmux replaced it: an edit, its images named). The version counts those changes.
const rowsByEntry = new WeakMap<QueuedEntry, AcpmuxRow>();
let version = 0;

/// The queue's agent messages as transcript rows (kind `QUEUED_MESSAGE`), in the queue's order.
/// The same entries give the same array back, so the transcript's rows keep their identity.
export function queuedMessageRows(queue: AcpmuxSnapshot["queue"], last?: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  for (const entry of queue) {
    const message = entry.message;
    if (!message) continue;
    // The first message may explain a Stop hold, once for the run.
    const lead = rows.length === 0;
    let row = rowsByEntry.get(entry);
    if (!row || Boolean(row.queuedMessage?.lead) !== lead) {
      row = {
        id: queuedMessageRowId(entry.id),
        version: ++version,
        at: 0,
        kind: QUEUED_MESSAGE,
        text: message.text,
        incoming: { kind: "message", message },
        queuedMessage: {
          promptId: entry.id,
          ...(entry.next ? { next: true } : {}),
          ...(lead ? { lead: true } : {}),
          ...(entry.heldByStop ? { heldByStop: true } : {}),
        },
        untyped: true,
        ...(entry.images?.length ? { images: entry.images } : {}),
      };
      rowsByEntry.set(entry, row);
    }
    rows.push(row);
  }
  if (last && last.length === rows.length && last.every((row, index) => row === rows[index])) return last;
  return rows;
}

/// A queued prompt's images as the composer's attachments, each with its bytes (the entry's own, else
/// read by its acpmux id), for Edit message, which takes the prompt back into the composer whole.
export function queuedAttachments(
  images: readonly QueuedPromptImage[] | undefined,
  readImage?: (id: string) => Promise<string | undefined>,
): Promise<ComposerAttachment[]> {
  return Promise.all(
    (images ?? []).map(async (image): Promise<ComposerAttachment> => {
      const src = image.src ?? (readImage ? await readImage(image.id) : undefined);
      return {
        id: image.id,
        kind: "image",
        name: image.name ?? "image",
        mimeType: image.mimeType,
        size: 0,
        ...(src?.startsWith("data:") ? { data: src.slice(src.indexOf(",") + 1) } : {}),
        ...(image.source ? { source: image.source } : {}),
      };
    }),
  );
}

/// Whether an image of the prompt could not be read back (no local copy, and the read failed): taking
/// the prompt into the composer then would lose it, so Edit message leaves it in the queue.
export function lacksImageBytes(attachments: readonly ComposerAttachment[]): boolean {
  return attachments.some((attachment) => attachment.kind === "image" && !attachment.data);
}
