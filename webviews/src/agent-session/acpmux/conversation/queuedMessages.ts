// Another agent's message that waits in the chat's queue is not the person's prompt (Leo,
// 2026-10-25: "I don't know why these things are queued up. It's kind of strange."). It never
// draws as a composer-queue row: the transcript shows it at once as the message it is (its
// received line, IncomingMessageCard.tsx), in the one group of messages that wait
// (pendingMessages.ts), never under a "Read after this turn" (Leo, 2026-10-29: "why the fuck do you
// guys keep doing this fucking bullshit with the red after this turn?"). Its ⋯ menu is a message's,
// not the person's queue row's: Deliver now, Copy, Dismiss (QueuedMessageCard.tsx). Once acpmux
// starts it, the queue drops it and the prompt's own row is its card, delivered. The composer's queue, its fold and its count, are the person's own
// prompts alone (ComposerQueue.tsx).
// acpmux's inbox notice (provenance `inbox_notice`) is no prompt of the person's either (Leo,
// 2026-11-03, on one drawn as a queued prompt with Steer, × and a trash can: "have it be rendered
// differently than just a regular queued message. we don't really wanna be cancelling agent back and
// forth messages 99% of the time"): it joins the same group as its threads, each its sender's line
// (laneNoticeBatches.ts `flattenInboxRows`), and goes in when the turn ends as the queue drains.
// A guest's prompt is not the owner's either (design/chat-multiplayer.md, "Held message card"): it
// draws here as a message from that person, held with Approve and Decline while it waits for the
// owner (acpmux `awaitingOwner`), then with the queue's label once approved.
import { TRANSIENT_SHOW_MS, useSettledItems } from "../afterDelay";
import type { ComposerAttachment } from "../attachments";
import { isGuest } from "../multiplayer/participants";
import { inboxText } from "./inboxNotice";
import { QUEUED_MESSAGE, type AcpmuxRow, type AcpmuxSnapshot, type QueuedPromptImage } from "../model";

type QueuedEntry = AcpmuxSnapshot["queue"][number];

/// Whether a queue entry is another agent's message (direct.ts `queuedMessage` named its sender),
/// or acpmux's inbox notice of such messages (direct.ts `queuedInbox`).
export const isAgentEntry = (entry: QueuedEntry) => entry.message !== undefined || entry.inbox !== undefined;

/// Whether a queue entry is a guest's prompt: held for the owner, or a guest's the owner approved.
/// A teammate's prompt stays a composer-queue row under their name (ComposerQueue.tsx).
export const isHeldEntry = (entry: QueuedEntry) => entry.awaitingOwner === true || isGuest(entry.author);

/// Whether a queue entry draws in the transcript rather than as a composer-queue row.
const inTranscript = (entry: QueuedEntry) => isAgentEntry(entry) || isHeldEntry(entry);

/// The person's own queued prompts, in the queue's order: the composer's queue rows.
export function ownQueue(queue: AcpmuxSnapshot["queue"]): AcpmuxSnapshot["queue"] {
  return queue.some(inTranscript) ? queue.filter((entry) => !inTranscript(entry)) : queue;
}

/// Whether a queue entry shows at once. A person's prompt does: one the person just sent is a whole
/// queued row in the frame the composer clears (Leo, 2026-11-11; test/agent-pane-queue-collapse),
/// and a held one waits on someone (the folder's trust, a waking machine, the owner), never on the
/// turn. So does another agent's message a Stop holds: it waits for the person, not for a batch.
const showsAtOnce = (entry: QueuedEntry) => !isAgentEntry(entry) || entry.heldByStop === true;

const entryKey = (entry: QueuedEntry) => entry.id;

/// The queue as the pane draws it, the composer's queue rows and the transcript's waiting card
/// alike (App.tsx): another agent's message or acpmux's inbox notice that comes and goes within
/// TRANSIENT_SHOW_MS (queued at a turn's end and started in the next batch) never paints (Leo,
/// 2026-11-17: "i also dont like seeing the flicker flash of the Queued blah blah blah something").
/// The queue there when chat `scope` first draws shows at once; the same array comes back while
/// nothing shown changed.
export function useShownQueue(
  queue: AcpmuxSnapshot["queue"],
  scope: unknown,
  ms: number = TRANSIENT_SHOW_MS,
): AcpmuxSnapshot["queue"] {
  return useSettledItems(queue, entryKey, scope, ms, showsAtOnce) as AcpmuxSnapshot["queue"];
}

/// The transcript row id of queued message `promptId`.
export const queuedMessageRowId = (promptId: string) => `queued-message-${promptId}`;

// One row object per queue entry object: a memoized row draws again only when its entry changed
// (acpmux replaced it: an edit, its images named). The version counts those changes.
const rowsByEntry = new WeakMap<QueuedEntry, AcpmuxRow>();
let version = 0;

/// The queue's agent messages and guests' prompts as transcript rows (kind `QUEUED_MESSAGE`), in the
/// queue's order. The same entries give the same array back, so the transcript's rows keep their identity.
export function queuedMessageRows(queue: AcpmuxSnapshot["queue"], last?: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  for (const entry of queue) {
    const person = isHeldEntry(entry) ? entry.author : undefined;
    const message = isHeldEntry(entry)
      ? { name: person?.name ?? "", text: entry.prompt, raw: entry.prompt, fromPerson: true as const }
      : entry.message;
    // An inbox notice draws as its threads, each another agent's line, never its text for the agent.
    // One that names no thread (direct.ts `mergeQueue`) has nothing to draw.
    const notice = !message && !isHeldEntry(entry) && entry.inbox?.threads.length ? entry.inbox : undefined;
    if (!message && !notice) continue;
    // The first message may explain a Stop hold, once for the run.
    const lead = rows.length === 0;
    let row = rowsByEntry.get(entry);
    if (!row || Boolean(row.queuedMessage?.lead) !== lead) {
      row = {
        id: queuedMessageRowId(entry.id),
        version: ++version,
        at: 0,
        kind: QUEUED_MESSAGE,
        text: message ? message.text : inboxText(notice!),
        incoming: message ? { kind: "message", message } : { kind: "inbox", notice: notice! },
        queuedMessage: {
          promptId: entry.id,
          ...(entry.next ? { next: true } : {}),
          ...(lead ? { lead: true } : {}),
          ...(entry.heldByStop ? { heldByStop: true } : {}),
          ...(person ? { person } : {}),
          ...(entry.awaitingOwner ? { held: true } : {}),
          ...(entry.awaitingOwner && entry.revision !== undefined ? { revision: entry.revision } : {}),
          // Approvable only with its record at the current revision (direct.ts Hold): the one place
          // the card learns it may offer Approve.
          ...(entry.awaitingOwner && (entry.updating || entry.revision === undefined) ? { updating: true } : {}),
        },
        untyped: true,
        ...(entry.images?.length ? { images: entry.images } : {}),
        // A held prompt's other attachments (documents, audio, links), drawn on its card.
        ...(isHeldEntry(entry) && entry.inlineParts?.length ? { inlineParts: entry.inlineParts } : {}),
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
