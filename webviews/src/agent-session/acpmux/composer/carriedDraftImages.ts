import type { ComposerAttachment } from "../attachments";
import { AcpmuxRpcError } from "../handoff/protocol";
import type { PromptSurface } from "../surfaces/promptSurface";

/// A chat's unsent composer images, kept in acpmux as well as by this Mac's host (RFD 0138,
/// "Attachments pending in the composer"; acpmux hub/composers.rs, cmux#53752). The host keeps a
/// chat's chips on this Mac only (AgentPaneDraftAttachments.swift). acpmux keeps them with the chat,
/// so a chat moved to Cloud or another machine, or opened on another Mac, still has the images
/// that were waiting in its composer: they travel in the move's bundle, checked by hash.
///
/// Only image chips with their bytes go: acpmux keeps images by content hash, as a sent prompt's.
/// A file, link or pasted-text chip is the host's alone, as before.

type Request = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Most images acpmux keeps in one surface's draft (composers.rs MAX_DRAFT_IMAGES).
export const MAX_CARRIED_IMAGES = 32;

/// Each chat's chips acpmux already holds, by chip id: the id acpmux answered for its bytes. A
/// later write names it by that id, so an image's bytes go once.
const heldIds = new Map<string, Map<string, string>>();

/// The bytes of the image chips last seen of the shown chat, by chip id: the host's later writes
/// leave a chip's bytes out once it holds them (keptAttachments.ts), and a page reloaded since
/// acpmux took them knows no id for them, so they come from here. One chat's only: a composer
/// shows one chat.
let seenBytes: { sessionId: string; data: Map<string, string> } | undefined;

/// Notes the bytes of chat `sessionId`'s image chips (a host read or write), forgetting the
/// chips no longer there.
export function noteBytes(sessionId: string, attachments: readonly ComposerAttachment[]): void {
  const had = seenBytes?.sessionId === sessionId ? seenBytes.data : new Map<string, string>();
  const data = new Map<string, string>();
  for (const chip of attachments) {
    if (chip.kind !== "image") continue;
    const bytes = typeof chip.data === "string" && chip.data ? chip.data : had.get(chip.id);
    if (bytes) data.set(chip.id, bytes);
  }
  seenBytes = { sessionId, data };
}

const bytesOf = (sessionId: string, chip: ComposerAttachment) =>
  typeof chip.data === "string" && chip.data
    ? chip.data
    : seenBytes?.sessionId === sessionId
      ? seenBytes.data.get(chip.id)
      : undefined;

/// The image chips of chat `sessionId`'s draft that go to acpmux, in order, at most 32, each with its
/// bytes when the page has them: those acpmux already holds go by id, the rest need them.
export function carriedChips(sessionId: string, attachments: readonly ComposerAttachment[]): ComposerAttachment[] {
  const held = heldIds.get(sessionId);
  return attachments
    .flatMap((chip) => {
      if (chip.kind !== "image") return [];
      const data = bytesOf(sessionId, chip);
      if (data) return [data === chip.data ? chip : { ...chip, data }];
      return held?.has(chip.id) ? [chip] : [];
    })
    .slice(0, MAX_CARRIED_IMAGES);
}

/// The `images` of `_acpmux/composer_set` for `chips`: an ACP image block for a chip acpmux does not
/// hold yet, `{id}` for one it does.
export function draftImages(sessionId: string, chips: readonly ComposerAttachment[]): Record<string, unknown>[] {
  const held = heldIds.get(sessionId);
  return chips.map((chip) => {
    const id = held?.get(chip.id);
    if (id) return { id };
    return {
      type: "image",
      mimeType: chip.mimeType || "image/png",
      data: chip.data,
      ...(chip.name ? { name: chip.name } : {}),
    };
  });
}

/// Records which acpmux id each chip's bytes got, from composer_set's answer (`images`, in order).
export function noteHeld(sessionId: string, chips: readonly ComposerAttachment[], answer: unknown): void {
  const images = answer && typeof answer === "object" ? (answer as { images?: unknown }).images : undefined;
  if (!Array.isArray(images) || images.length !== chips.length) {
    heldIds.delete(sessionId);
    return;
  }
  const held = new Map<string, string>();
  chips.forEach((chip, index) => {
    const id = (images[index] as { id?: unknown } | undefined)?.id;
    if (typeof id === "string") held.set(chip.id, id);
  });
  if (held.size) heldIds.set(sessionId, held);
  else heldIds.delete(sessionId);
}

/// Forgets what acpmux holds for every chat (a new connection may reach another daemon).
export function forgetHeld(): void {
  heldIds.clear();
  seenBytes = undefined;
}

// A clear must follow every earlier write, including its one retry with bytes.
const pending = new Map<string, Promise<unknown>>();

function inDraftOrder<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
  const previous = pending.get(sessionId);
  const next = previous ? previous.then(operation, operation) : operation();
  pending.set(sessionId, next);
  const settled = () => {
    if (pending.get(sessionId) === next) pending.delete(sessionId);
  };
  void next.then(settled, settled);
  return next;
}

export function writeCarriedImages(
  request: Request,
  sessionId: string,
  surface: PromptSurface,
  attachments: readonly ComposerAttachment[],
): Promise<void> {
  noteBytes(sessionId, attachments);
  // Snapshot bytes before a newer edit or a switch to another chat evicts them.
  const chips = carriedChips(sessionId, attachments);
  return inDraftOrder(sessionId, async () => {
    const send = () =>
      request("_acpmux/composer_set", { sessionId, surface, text: "", images: draftImages(sessionId, chips) });
    let answer: unknown;
    try {
      answer = await send();
    } catch (error) {
      if (!(error instanceof AcpmuxRpcError) || error.reason !== "composer.image.unknown") throw error;
      heldIds.delete(sessionId);
      if (chips.some((chip) => !chip.data)) throw error;
      answer = await send();
    }
    noteHeld(sessionId, chips, answer);
  });
}

type CarriedImage = { id: string; mimeType: string; name?: string };

function carriedImages(answer: unknown): CarriedImage[] {
  const images = answer && typeof answer === "object" ? (answer as { images?: unknown }).images : undefined;
  if (!Array.isArray(images)) return [];
  return images.slice(0, MAX_CARRIED_IMAGES).flatMap((image) => {
    const { id, mimeType, name } = image ?? {};
    if (typeof id !== "string" || !id) return [];
    return [{ id, mimeType: typeof mimeType === "string" ? mimeType : "image/png", ...(typeof name === "string" && name ? { name } : {}) }];
  });
}

/// The chip of an image acpmux kept for the chat, with its bytes (`_acpmux/attachment`).
export function carriedChip(image: CarriedImage, data: string, mimeType: string): ComposerAttachment {
  return {
    id: `carried-${image.id}`,
    kind: "image",
    // l10n-allow: a file name, shown as the chip's name when the image came without one.
    name: image.name ?? "image",
    mimeType,
    size: Math.floor((data.length * 3) / 4),
    data,
  };
}

/// Resume one draft under this page's surface before it edits or sends. An older daemon
/// requires text on composer_set and rejects this request without modifying any draft.
export function readCarriedImages(
  request: Request,
  sessionId: string,
  surface: PromptSurface,
  metadataOnly = false,
): Promise<ComposerAttachment[]> {
  return inDraftOrder(sessionId, async () => {
    const answer = await request("_acpmux/composer_set", { sessionId, surface, resume: true }).catch(() => undefined);
    if (metadataOnly) return [];
    const chips = await Promise.all(
      carriedImages(answer).map(async (image) => {
        const reply = (await request("_acpmux/attachment", { sessionId, id: image.id }).catch(() => undefined)) as
          | { data?: unknown; mimeType?: unknown }
          | undefined;
        if (typeof reply?.data !== "string" || !reply.data) return undefined;
        return carriedChip(image, reply.data, typeof reply.mimeType === "string" ? reply.mimeType : image.mimeType);
      }),
    );
    return chips.filter((chip): chip is ComposerAttachment => chip !== undefined);
  });
}
