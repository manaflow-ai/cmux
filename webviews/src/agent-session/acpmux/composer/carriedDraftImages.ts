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
  heldIds.set(sessionId, held);
}

/// Forgets what acpmux holds for every chat (a new connection may reach another daemon).
export function forgetHeld(): void {
  heldIds.clear();
  seenBytes = undefined;
}

/// Tells acpmux chat `sessionId`'s unsent images from this page (`surface`), or that it holds
/// none. The draft's text stays the shared draft's (`_acpmux/draft_set`): this surface's text is
/// sent empty, so nothing is said twice. A write refused because acpmux lost an image it was named
/// by id goes again with the bytes; one refused mid-move is dropped (the next change writes again).
export async function writeCarriedImages(
  request: Request,
  sessionId: string,
  surface: PromptSurface,
  attachments: readonly ComposerAttachment[],
): Promise<void> {
  noteBytes(sessionId, attachments);
  let chips = carriedChips(sessionId, attachments);
  const send = () =>
    request("_acpmux/composer_set", { sessionId, surface, text: "", images: draftImages(sessionId, chips) });
  let answer: unknown;
  try {
    answer = await send();
  } catch (error) {
    if (!(error instanceof AcpmuxRpcError) || error.reason !== "composer.image.unknown") throw error;
    // acpmux lost what it held: the chips with their bytes go again; one whose bytes the page no
    // longer has is left out (the host still keeps it on this Mac).
    heldIds.delete(sessionId);
    chips = carriedChips(sessionId, attachments);
    answer = await send();
  }
  noteHeld(sessionId, chips, answer);
}

/// One image a draft of the chat holds, as `_acpmux/composers` names it.
export type CarriedImage = { id: string; mimeType: string; name?: string };

/// The images the chat's drafts hold in acpmux, from `_acpmux/composers`' answer: the app's surfaces
/// only (a phone or the CLI keeps its own), newest draft first, each id once.
export function carriedImages(answer: unknown): CarriedImage[] {
  const composers = answer && typeof answer === "object" ? (answer as { composers?: unknown }).composers : undefined;
  if (!Array.isArray(composers)) return [];
  const seen = new Set<string>();
  const out: CarriedImage[] = [];
  for (const composer of composers) {
    if (!composer || typeof composer !== "object") continue;
    const { kind, images } = composer as { kind?: unknown; images?: unknown };
    if (kind !== undefined && kind !== "app") continue;
    if (!Array.isArray(images)) continue;
    for (const image of images) {
      const { id, mimeType, name } = (image ?? {}) as { id?: unknown; mimeType?: unknown; name?: unknown };
      if (typeof id !== "string" || !id || seen.has(id)) continue;
      seen.add(id);
      out.push({
        id,
        mimeType: typeof mimeType === "string" && mimeType ? mimeType : "image/png",
        ...(typeof name === "string" && name ? { name } : {}),
      });
    }
  }
  return out.slice(0, MAX_CARRIED_IMAGES);
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

/// The chips of the images chat `sessionId`'s drafts hold in acpmux: what a composer whose host
/// keeps none for the chat (a moved chat, another Mac) gets back. An image whose bytes cannot be
/// read is left out; nothing is thrown.
export async function readCarriedImages(request: Request, sessionId: string): Promise<ComposerAttachment[]> {
  const images = carriedImages(await request("_acpmux/composers", { sessionId }).catch(() => undefined));
  const chips = await Promise.all(
    images.map(async (image) => {
      const reply = (await request("_acpmux/attachment", { sessionId, id: image.id }).catch(() => undefined)) as
        | { data?: unknown; mimeType?: unknown }
        | undefined;
      if (typeof reply?.data !== "string" || !reply.data) return undefined;
      return carriedChip(image, reply.data, typeof reply.mimeType === "string" ? reply.mimeType : image.mimeType);
    }),
  );
  return chips.filter((chip): chip is ComposerAttachment => chip !== undefined);
}
