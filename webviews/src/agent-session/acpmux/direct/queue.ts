import type { SubagentRetryNotice } from "../subagents/retryState";
import { queuedAuthor, type Participant } from "../multiplayer/participants";
import type {
  AcpmuxRow,
  PromptImage,
  PromptContentPart,
  QueuedPrompt,
  QueuedPromptImage,
  PromptDelivery,
  PromptDeliveryHop,
} from "../model";
import {
  attachmentSource,
  promptBlocks,
  promptText,
  type AttachmentSource,
  type ComposerAttachment,
} from "../attachments";
import { inlinePrompt, recordedPromptParts, stripFileDisplay } from "../inlinePrompt";
import { knownImageSize } from "../conversation/imageEntries";
import { shownPrompt } from "../pastedText";
import { frameTextOf, imageNames } from "../composer/videoPrompt";
import { incomingPrompt, type IncomingContext, type IncomingMessage } from "../conversation/incomingMessage";
import type { InboxNotice } from "../conversation/inboxNotice";
import { withoutRelayEnvelope, withoutRelayLabel, withoutRelayLabelOfMessage } from "../conversation/relayEnvelope";
import { bareSender, provenanceAuthenticated } from "../conversation/senderIdentity";

/// A queue row's entry. acpmux's ask to resume a failed subagent (`retry`) comes from its `queued`
/// record (`subagentRetryNotice`) or a listing (`listedRetry`); every rebuild of the entry passes it on.
export function queuedEntry(
  id: string,
  prompt: string,
  next: boolean,
  sending = false,
  images?: readonly QueuedPromptImage[],
  message?: IncomingMessage,
  author?: Participant,
  inlineParts?: PromptContentPart[],
  retry?: SubagentRetryNotice,
  hold: Hold = {},
  inbox?: InboxNotice,
): QueuedPrompt {
  return {
    id,
    prompt,
    ...(next ? { next } : {}),
    ...(sending ? { sending } : {}),
    ...(images?.length ? { images: [...images] } : {}),
    ...(message ? { message } : {}),
    ...(inbox && !message ? { inbox } : {}),
    ...(author ? { author } : {}),
    ...(inlineParts?.length ? { inlineParts } : {}),
    ...(retry && !message && !inbox && !author ? { retry } : {}),
    ...(hold.awaitingOwner ? { awaitingOwner: true } : {}),
    ...(hold.revision !== undefined ? { revision: hold.revision } : {}),
    ...(hold.awaitingOwner && hold.updating ? { updating: true } : {}),
    ...(hold.awaitingOwner && hold.listedRevision !== undefined ? { listedRevision: hold.listedRevision } : {}),
    ...(hold.awaitingOwner && hold.turnId ? { turnId: hold.turnId } : {}),
  };
}

/// `entry` with `from`'s Stop hold (`heldByStop`): an entry rebuilt from a record or a list keeps it
/// while it is still another agent's message. An edit makes it the person's (hub/queue_edit.rs), and
/// a person's Stop holds only other agents' messages.
export function keepStopHold(entry: QueuedPrompt, from: QueuedPrompt | undefined): QueuedPrompt {
  return from?.heldByStop && !entry.heldByStop && entry.message ? { ...entry, heldByStop: true } : entry;
}

/// A guest's prompt's hold (acpmux `awaitingOwner`, `revision`). THE RULE: a held prompt is
/// approvable only when the pane holds its authoritative record (a `queued` / `queue_updated`
/// record, or a read of one) for its current revision. `revision` is set only from such a record,
/// with that record's text, images and parts; a listing (acpmux's queue list, a 200-character
/// preview) never sets it, whatever its preview looks like. `listedRevision` is the newest revision
/// acpmux named anywhere; `updating` (not approvable) holds while the record the pane has is older
/// than it, or there is none.
type Hold = {
  awaitingOwner?: boolean;
  revision?: number;
  updating?: boolean;
  listedRevision?: number;
  turnId?: string;
};
const heldHold = (
  awaitingOwner: boolean | undefined,
  revision: number | undefined,
  listedRevision: number,
  turnId: string | undefined,
): Hold => ({
  awaitingOwner,
  revision,
  ...(listedRevision >= 0 ? { listedRevision } : {}),
  ...(turnId ? { turnId } : {}),
  updating: awaitingOwner === true && (revision === undefined || listedRevision > revision),
});
/// The hold an authoritative record carries (`queued`, `queue_updated`): its revision is the text's.
export const holdOf = (msg: any, had?: Hold): Hold => {
  const revision = typeof msg?.revision === "number" ? msg.revision : had?.revision;
  const awaitingOwner = typeof msg?.awaitingOwner === "boolean" ? msg.awaitingOwner : had?.awaitingOwner;
  const turnId = typeof msg?.turnId === "string" && msg.turnId ? msg.turnId : had?.turnId;
  return heldHold(awaitingOwner, revision, Math.max(revision ?? -1, had?.listedRevision ?? -1), turnId);
};
/// The hold a listing names: never a record. It only says which revision is current (a list older
/// than the record the pane holds names a lower one, which changes nothing).
function listedHold(entry: any, had: QueuedPrompt | undefined): Hold {
  const awaitingOwner = typeof entry?.awaitingOwner === "boolean" ? entry.awaitingOwner : had?.awaitingOwner;
  const listed = typeof entry?.revision === "number" ? entry.revision : -1;
  const turnId = typeof entry?.turnId === "string" && entry.turnId ? entry.turnId : had?.turnId;
  return heldHold(
    awaitingOwner,
    had?.revision,
    Math.max(listed, had?.listedRevision ?? -1, had?.revision ?? -1),
    turnId,
  );
}

/// A `queued` record that is another agent's message, as its received line reads it once it runs
/// (conversation/incomingMessage.ts), else as acpmux's `fromAgent` names it (`acpmux send --from`),
/// its text without a leading "[name]" or "From name:" that only repeats the sender. Undefined for
/// the person's own prompt. `preview`: the text is a queue list's one-line preview, which acpmux may
/// cut inside the broker's label; a record's text is the whole message.
export function queuedMessage(msg: any, context?: IncomingContext, preview = false): IncomingMessage | undefined {
  const text = String(msg?.text ?? "");
  const incoming = incomingPrompt(text, msg, context, preview);
  if (incoming?.kind === "message") return incoming.message;
  // The list's `fromAgent` is the name acpmux shows the agent, an unverified one with its suffix
  // (conversation/senderIdentity.ts): the line names it bare and marks it.
  const sender = bareSender(typeof msg?.fromAgent === "string" ? msg.fromAgent : "");
  const name = sender.name;
  if (!name) return undefined;
  const lead = queuedText(text, msg, preview).trimStart();
  const named = [`[${name}]`, `From ${name}:`].find((prefix) => lead.toLowerCase().startsWith(prefix.toLowerCase()));
  const harness = typeof msg?.fromHarness === "string" && msg.fromHarness.trim() ? msg.fromHarness.trim() : undefined;
  return {
    name,
    ...(harness ? { harness } : {}),
    ...(sender.declared ? { unverified: true as const } : {}),
    text: (named ? lead.slice(named.length) : lead).trim(),
    raw: text,
  };
}

/// A queued message's text without the broker's label (conversation/relayEnvelope.ts): a preview
/// cut inside it reads as none of it; a whole message keeps words that only start like one, and
/// loses a head with no closing line only when acpmux proved its sender (a relay record or a stamped
/// session, senderIdentity.ts `provenanceAuthenticated`). Anyone can type a head, so a sender named
/// in `fromAgent` alone gets only a whole closed label left out.
function queuedText(text: string, msg: any, preview: boolean): string {
  if (preview) return withoutRelayLabel(text);
  const provenance = msg?._meta?.provenance;
  const relayed = provenanceAuthenticated(
    provenance && typeof provenance === "object"
      ? provenance
      : msg?.fromRelay
        ? { fromRelay: msg.fromRelay }
        : undefined,
  );
  return relayed ? withoutRelayLabelOfMessage(text) : withoutRelayEnvelope(text);
}

/// A `queued` record that is acpmux's inbox notice (provenance `inbox_notice`), as its threads.
/// Undefined for any other prompt. acpmux's queue list names no provenance, so a notice the pane
/// has only that list of shows as a queue row until its record is read.
export function queuedInbox(msg: any, context?: IncomingContext): InboxNotice | undefined {
  const incoming = incomingPrompt(String(msg?.text ?? ""), msg, context);
  return incoming?.kind === "inbox" ? incoming.notice : undefined;
}

/// The images a `queued` or `queue_updated` record names (`images`, in its prompt's order), each
/// with its bytes as a data URL when the record's `prompt` carries them, so its row draws them
/// without reading them back. acpmux names only the images it could keep: the bytes go with the
/// names only when the two lists match.
export function recordImages(msg: any): QueuedPromptImage[] {
  const named = promptImages(msg?.images);
  const blocks = (Array.isArray(msg?.prompt) ? msg.prompt : []).filter(
    (block: any) => block?.type === "image" && typeof block.data === "string",
  );
  if (blocks.length !== named.length) return named;
  return named.map((image, index) => ({
    ...image,
    src: `data:${image.mimeType};base64,${blocks[index].data}`,
  }));
}

/// The images of a prompt this pane sends, from the composer's attachments: its queue row shows
/// them from the send on, before acpmux names them.
export function attachedImages(attachments: readonly ComposerAttachment[]): QueuedPromptImage[] {
  return attachments.flatMap((attachment) => {
    if (attachment.kind !== "image" || !attachment.data) return [];
    const src = `data:${attachment.mimeType};base64,${attachment.data}`;
    // Its size from its header, so the row is laid out at the thumbnail's shape from the send
    // (inlinePrompt.ts does the same for a placed image).
    const size = knownImageSize(src);
    return [
      {
        id: attachment.id,
        mimeType: attachment.mimeType,
        name: attachment.name,
        src,
        ...(size ? { width: size.width, height: size.height } : {}),
        local: true,
        ...(attachment.source ? { source: attachment.source } : {}),
      },
    ];
  });
}

/// `images` named by acpmux, each keeping the bytes the pane already had for it.
function withKnownBytes(images: QueuedPromptImage[], known: readonly QueuedPromptImage[] | undefined) {
  const bytes = new Map((known ?? []).flatMap((image) => (image.src ? [[image.id, image.src] as const] : [])));
  // The source each image's `queued` record named, which acpmux's list does not carry: by
  // occurrence, since byte-identical images share an id but not a source.
  const sources = new Map<string, (AttachmentSource | undefined)[]>();
  for (const image of known ?? []) sources.set(image.id, [...(sources.get(image.id) ?? []), image.source]);
  const seen = new Map<string, number>();
  return images.map((image) => {
    const at = seen.get(image.id) ?? 0;
    seen.set(image.id, at + 1);
    const src = bytes.get(image.id);
    const source = image.source ?? sources.get(image.id)?.[at];
    return src || source ? { ...image, ...(src ? { src } : {}), ...(source ? { source } : {}) } : image;
  });
}

/// How long a send waits for acpmux before its row says it is still sending, and before it fails
/// (plans/cmux-next/composer-delivery-DESIGN.md): `failMs` on a connection with no native relay
/// journal, `localFailMs` on one to this Mac's acpmux (a busy session's acknowledgement may be slow,
/// and the page cannot see whether the journal kept the prompt). Tests shorten them.
/// `hostWaitMs`: how long a prompt waits for an acpmux that is starting or reconnecting
/// (sendWhenReady.ts): with no end, as long as its chat is shown and its client open. A machine
/// that rebooted comes back in minutes, and the prompt goes then by itself, never "Not sent" and
/// Retry (Leo, 2026-11-12: "try what? no, it should just automatically do stuff"). Tests shorten it.
/// `resendShowMs`: how long a connection waits with no word at all of a prompt the host's outbox
/// sends again on it before its row says "Not sent" again (direct.ts `awaitResent`): a quiet
/// window each outbox word (`_cmux/prompt_resend`) opens again, never a deadline on a send that
/// progresses; one on the wire waits up to `localFailMs`.
export const deliveryTiming = {
  slowMs: 10_000,
  failMs: 60_000,
  localFailMs: 300_000,
  hostWaitMs: Number.POSITIVE_INFINITY,
  resendShowMs: 30_000,
};

export const DELIVERY_RANK: Record<PromptDelivery["state"], number> = {
  sending: 0,
  delivered: 1,
  read: 2,
  failed: 3,
};

/// The hop a refused or failed send stopped at: a transport error is the pane's connection to
/// acpmux (a missing gesture is the host's refusal, so acpmux's hop), a failure after acpmux took
/// the prompt is the agent's turn, anything else is acpmux's answer.
export function deliveryHop(code: string | undefined, taken: boolean): PromptDeliveryHop {
  if (taken) return "agent";
  if (code?.startsWith("transport.") && code !== "transport.gesture_required") return "connection";
  return "acpmux";
}

const oneLine = (text: string) => text.split(/\s+/).filter(Boolean).join(" ");

/// acpmux's queue (a session's `queue`, in order) over the one the pane has. acpmux lists each
/// prompt's preview (its first 200 characters on one line), so a prompt the pane read whole from
/// its `queued` record keeps its whole text, and one sent now stays next. A prompt's author is the
/// one acpmux lists, else the one its newest `queued` or `queue_updated` record named (`authors`, by
/// prompt id: null when that record named none), else the one the pane had: an attach's page can
/// hold a teammate's edit without the `queued` record before it.
/// A queue list's `subagentRetry` (acpmux `QueuedSubagentRetry`) as a row's resume.
function listedRetry(raw: unknown): SubagentRetryNotice | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const { agentId, name, error } = raw as Record<string, unknown>;
  const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
  const [a, n, e] = [text(agentId), text(name), text(error)];
  if (!a && !n) return undefined;
  return { ...(n ? { name: n } : {}), ...(a ? { agentId: a } : {}), ...(e ? { error: e } : {}) };
}

/// The listing's resume, keeping the name and error the pane recovered for the same agent (from the
/// `queued` record's words) where the listing names none: a resume queued before acpmux put them
/// in its provenance lists only the agent id.
function withRecovered(
  listed: SubagentRetryNotice | undefined,
  had: SubagentRetryNotice | undefined,
): SubagentRetryNotice | undefined {
  if (!listed || !had || !listed.agentId || listed.agentId !== had.agentId) return listed;
  const name = listed.name ?? had.name;
  const error = listed.error ?? had.error;
  return { ...listed, ...(name ? { name } : {}), ...(error ? { error } : {}) };
}

export function mergeQueue(
  current: readonly QueuedPrompt[],
  listed: readonly any[],
  authors?: ReadonlyMap<string, Participant | null>,
  edited?: ReadonlySet<string>,
): QueuedPrompt[] {
  const known = new Map(current.map((entry) => [entry.id, entry]));
  // A background finish waiting for its turn is never a queued card (bgDoneNotice.ts), whichever
  // listing brings it back (an attach, a reload, a session change).
  const merged = listed
    .filter((entry) => !String(entry?.promptId ?? "").startsWith("bg-done-"))
    .map((entry) => {
      const id = String(entry?.promptId ?? "");
      const preview = String(entry?.prompt ?? entry?.preview ?? "");
      const had = known.get(id);
      // A held prompt keeps its record's content whatever the list's preview says (THE RULE, Hold).
      const heldRecord = had?.awaitingOwner === true && had.revision !== undefined && entry?.awaitingOwner !== false;
      const whole = had !== undefined && (heldRecord || oneLine(had.prompt).startsWith(preview.replace(/…$/, "")));
      // acpmux lists its images (after a reload or a restart too); one that lists none (an older
      // acpmux) keeps those the pane had.
      const listedImages = Array.isArray(entry?.images)
        ? withKnownBytes(promptImages(entry.images), had?.images)
        : had?.images;
      // The `queued` record the pane read names the sender, while its text is still the one listed
      // (an edit the pane missed makes it the person's, as acpmux does). The list's `fromAgent`
      // says so too: null is the person's (an edit past the preview's cut leaves its head the
      // same), and a name is an agent's, also for a row the pane never read the record of (a
      // reload). An older acpmux lists none.
      const listed = entry?.fromAgent;
      // Keep the complete queue record here: when `fromAgent` is absent, the
      // sender lives in `_meta.provenance` and `queuedMessage` must see it.
      // Override only the text with acpmux's current preview; a stale full
      // prompt would make the provenance branch look like an edit.
      // An agent's message the person edited, or a prompt acpmux could not attribute, lists null
      // but its provenance (acpmux `QueuedPromptSummary.provenance`): its card names that sender.
      const listedProvenance =
        entry?.provenance && typeof entry.provenance === "object" ? (entry.provenance as unknown) : undefined;
      const listedMessage = queuedMessage(
        {
          ...entry,
          text: preview,
          fromAgent: listed,
          fromHarness: entry?.fromHarness,
          ...(listedProvenance ? { _meta: { ...entry?._meta, provenance: listedProvenance } } : {}),
        },
        undefined,
        true,
      );
      const kept = whole ? had.message : undefined;
      // A queue listing may carry the full provenance even when its compatibility `fromAgent`
      // field is absent. Preserve that parsed agent message; only an explicit null says that the
      // prompt is the person's own. Without this, a queued agent_message was rendered as a plain
      // user prompt until it left the queue, so its received card (and reply actions) disappeared.
      const message = listed === null ? (listedProvenance ? listedMessage : undefined) : (kept ?? listedMessage);
      // acpmux's inbox notice: the threads acpmux lists (`inboxNotice`, its provenance), else those its
      // `queued` record named while the text is the same. An edit makes it the person's (hub/queue.rs
      // drops the provenance), so it keeps none. A notice whose record the pane never read (a chat
      // reopened on a recent page) drew as the person's queued prompt under "Paused after an error"
      // (Leo, 2026-11-05: "Why is the thing still queued? ... don't show these kinds of things").
      // One that names no thread, or from an acpmux that lists none (its `[inbox]` text from acpmux),
      // is still no prompt of the person's: no thread to draw, and no queue row.
      const listedInbox =
        entry?.inboxNotice && typeof entry.inboxNotice === "object"
          ? (queuedInbox({ text: preview, _meta: { provenance: entry.inboxNotice } }) ?? { threads: [] })
          : !("inboxNotice" in (entry ?? {})) && entry?.client === "acpmux" && preview.startsWith("[inbox] ")
            ? (had?.inbox ?? { threads: [] })
            : undefined;
      const inbox =
        message || edited?.has(id)
          ? undefined
          : (listedInbox ?? (whole && !("inboxNotice" in (entry ?? {})) ? had.inbox : undefined));
      // A list that names the field says whose it is, null the owner's (acpmux lists it for every
      // prompt once it serves authors); an older acpmux lists none, and the records read decide.
      const hold = listedHold(entry, had);
      // Text, images and parts of a held prompt are its record's, together (never a list's images
      // under a record's text).
      const heldKeepsRecord = heldRecord && hold.awaitingOwner === true;
      const author =
        entry && typeof entry === "object" && "author" in entry
          ? queuedAuthor(entry.author)
          : authors?.has(id)
            ? (authors.get(id) ?? undefined)
            : had?.author;
      const built = queuedEntry(
        id,
        whole ? had.prompt : preview,
        had?.next === true,
        false,
        // A held prompt's images are its text's: the record the pane holds while it keeps that text.
        heldKeepsRecord ? had?.images : listedImages,
        message,
        author,
        heldKeepsRecord ? had?.inlineParts : (recordedPromptParts(entry, had?.inlineParts) ?? had?.inlineParts),
        // A resume comes from acpmux's word only: the listing's `subagentRetry` (from the prompt's
        // `subagent_retry` provenance, which an edit drops), else, from an acpmux that lists none,
        // the one its `queued` record gave while the text is the same (the preview that text or cut
        // from it). An edit, seen or missed, drops it; a null listing removes it.
        message || inbox || author || edited?.has(id)
          ? undefined
          : "subagentRetry" in (entry ?? {})
            ? withRecovered(listedRetry(entry.subagentRetry), had?.retry)
            : whole && (preview.endsWith("…") || oneLine(had.prompt) === preview)
              ? had.retry
              : undefined,
        // A guest's prompt that waits for the owner (acpmux lists `awaitingOwner`; an older one, none).
        hold,
        inbox,
      );
      // Whether a person's Stop holds it, as acpmux lists it (`heldByStop`); listed unheld, it was
      // let go. A list without the field (an older acpmux) keeps what the records said.
      const next =
        entry?.heldByStop === true && entry?.held !== false
          ? { ...built, heldByStop: true as const }
          : entry?.held === false || entry?.heldByStop === false
            ? built
            : keepStopHold(built, had);
      // An entry the list left as it was stays the same object: the transcript keys a waiting message's
      // card by its entry (queuedMessages.ts), so an unchanged one draws nothing again.
      return had && sameQueuedEntry(had, next) ? had : next;
    });
  // The chat's own change carries its whole queue each time (a step, its usage): the same entries
  // give the same list back, so nothing that reads the queue sees a change.
  return merged.length === current.length && merged.every((entry, index) => entry === current[index])
    ? (current as QueuedPrompt[])
    : merged;
}

/// Whether two queue entries say the same: their fields, and what their images, message, author and
/// inline parts hold (small records, compared whole).
function sameQueuedEntry(a: QueuedPrompt, b: QueuedPrompt): boolean {
  return (
    a.id === b.id &&
    a.prompt === b.prompt &&
    a.next === b.next &&
    a.sending === b.sending &&
    a.heldByStop === b.heldByStop &&
    JSON.stringify(a.images) === JSON.stringify(b.images) &&
    JSON.stringify(a.message) === JSON.stringify(b.message) &&
    JSON.stringify(a.inbox) === JSON.stringify(b.inbox) &&
    JSON.stringify(a.author) === JSON.stringify(b.author) &&
    JSON.stringify(a.inlineParts) === JSON.stringify(b.inlineParts) &&
    JSON.stringify(a.retry) === JSON.stringify(b.retry) &&
    a.awaitingOwner === b.awaitingOwner &&
    a.revision === b.revision &&
    a.updating === b.updating &&
    a.listedRevision === b.listedRevision &&
    a.turnId === b.turnId
  );
}

/// What a sent prompt goes as (its blocks and inline parts) and what its row shows (text and pasted
/// spans): one shape for a send and for the Not sent row a relaunch draws again (unsentPrompts.ts).
export function sentPromptShape(
  input: string,
  carried: ComposerAttachment[],
  options: Parameters<typeof promptBlocks>[2],
) {
  const blocks = promptBlocks(input, carried, options);
  const inline = inlinePrompt(input, carried);
  const isFrame = frameTextOf(imageNames(blocks));
  const fileDisplay = inline?.display ?? stripFileDisplay(blocks, carried);
  const { text, pasted } = inline
    ? blocks.reduce(
        (shown, block) => {
          // A video's frames note is the agent's; the bubble draws the video's tile.
          if (block.type !== "text" || isFrame(block.text)) return shown;
          if (shown.text) shown.text += "\n";
          const start = shown.text.length;
          shown.text += block.text;
          if (block._meta?.cmux.pasted) shown.pasted.push({ start, end: shown.text.length });
          return shown;
        },
        { text: "", pasted: [] as { start: number; end: number }[] },
      )
    : shownPrompt(promptText(input, carried, options), carried);
  return { blocks, inline, fileDisplay, text, pasted };
}

export function settleOptimisticPrompt(
  rows: Map<string, AcpmuxRow>,
  promptRows: Map<string, string>,
  message: any,
  removeRow = true,
): string | undefined {
  const promptId = typeof message?.promptId === "string" ? message.promptId : undefined;
  if (!promptId) return undefined;
  const rowId = promptRows.get(promptId);
  if (removeRow && rowId) rows.delete(rowId);
  promptRows.delete(promptId);
  return rowId;
}

/// The images a `user_message` names (`images: [{id, mimeType, name?, width?, height?}]`),
/// malformed entries left out.
export function promptImages(value: unknown): PromptImage[] {
  if (!Array.isArray(value)) return [];
  const dimension = (n: unknown) => typeof n === "number" && Number.isInteger(n) && n > 0;
  return value.flatMap((image) =>
    image && typeof image.id === "string" && typeof image.mimeType === "string"
      ? [
          {
            id: image.id,
            mimeType: image.mimeType,
            ...(typeof image.name === "string" && { name: image.name }),
            ...(dimension(image.width) && dimension(image.height) && { width: image.width, height: image.height }),
            ...(attachmentSource(image.source) && { source: attachmentSource(image.source) }),
          },
        ]
      : [],
  );
}
