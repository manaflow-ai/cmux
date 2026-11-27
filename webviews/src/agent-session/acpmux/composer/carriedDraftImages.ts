import type { ComposerAttachment } from "../attachments";
import { AcpmuxRpcError } from "../handoff/protocol";
import { pageSurface } from "../surfaces/promptSurface";

/// A chat's unsent composer images, kept in acpmux as well as by this Mac's host (RFD 0138,
/// "Attachments pending in the composer"; acpmux hub/composers.rs, cmux#53752). The host keeps a
/// chat's chips on this Mac only (AgentPaneDraftAttachments.swift). acpmux keeps them with the chat,
/// so a chat moved to Cloud or another machine, or opened on another Mac, still has the images
/// that were waiting in its composer: they travel in the move's bundle, checked by hash.
///
/// Only image chips with their bytes go: acpmux keeps images by content hash, as a sent prompt's.
/// A file, link or pasted-text chip is the host's alone, as before.
///
/// A chat's images live in one draft: its id (the draft's surface id) persists with the host's chips
/// and in acpmux, so a reopened page, a second pane and the move's bundle all name the same draft.
/// Each image carries its chip id as `key`, and a write names the keys it last saw (`base`): a pane
/// removes only its own chips, never one another pane added, and equal bytes in two chips stay two.
/// A sent prompt names its draft and keys, so acpmux drops exactly what was sent.

type Request = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Most images acpmux keeps in one surface's draft (composers.rs MAX_DRAFT_IMAGES).
export const MAX_CARRIED_IMAGES = 32;

/// Longest chip id acpmux keeps as an image's key (composers.rs MAX_DRAFT_KEY_CHARS).
const MAX_KEY_CHARS = 128;

/// A character acpmux refuses in a key or surface id (composers.rs `hidden`).
const hidden = (code: number) =>
  code < 0x20 ||
  (code >= 0x7f && code <= 0x9f) ||
  [0xad, 0x61c, 0x180e, 0xfeff].includes(code) ||
  (code >= 0x200b && code <= 0x200f) ||
  (code >= 0x202a && code <= 0x202e) ||
  (code >= 0x2060 && code <= 0x206f) ||
  (code >= 0xfff9 && code <= 0xfffb);
const shown = (text: string, most: number) => {
  // Code points, as acpmux counts `char`s.
  const chars = Array.from(text);
  return text.trim() !== "" && chars.length <= most && !chars.some((c) => hidden(c.codePointAt(0)!));
};

/// A chip id acpmux takes as a key, so a write or prompt is never refused for it.
export const validKey = (key: string) => shown(key, MAX_KEY_CHARS);

/// Longest draft id: a surface id (acpmux field limit).
const MAX_DRAFT_ID_CHARS = 64;
export const validDraftId = (id: unknown): id is string =>
  typeof id === "string" && id === id.trim() && shown(id, MAX_DRAFT_ID_CHARS);

/// Each chat's draft as this page knows it: its id, the keys this page last saw in it (the next
/// write's `base`), and whether its images came from an older build without keys (`replace`: the
/// next write names no base, so the adopted images can be removed).
type DraftState = { id: string; base: string[]; replace?: boolean };
const drafts = new Map<string, DraftState>();

/// Chat `sessionId`'s draft id: the one adopted or written before, else a new one.
export function draftIdOf(sessionId: string): string {
  let draft = drafts.get(sessionId);
  if (!draft) {
    draft = { id: crypto.randomUUID(), base: [] };
    drafts.set(sessionId, draft);
  }
  return draft.id;
}

/// Takes `id` as chat `sessionId`'s draft, holding the image chips `chips` (a restore): the next
/// write's base is their ids, so removing one there removes it from acpmux.
export function adoptDraft(sessionId: string, id: string, chips: readonly ComposerAttachment[], replace = false): void {
  const had = drafts.get(sessionId);
  if (had && had.id !== id) heldIds.delete(had.id);
  drafts.set(sessionId, {
    id,
    base: chips.filter((chip) => chip.kind === "image" && validKey(chip.id)).map((chip) => chip.id),
    ...(replace ? { replace } : {}),
  });
}

/// The `_meta.acpmux.draft` of a prompt sending `attachments` from chat `sessionId`'s composer: the
/// draft and the keys of its image chips, so acpmux drops exactly those once it takes the prompt.
export function sentDraft(
  sessionId: string,
  attachments: readonly ComposerAttachment[] | undefined,
): { id: string; keys: string[] } | undefined {
  const draft = drafts.get(sessionId);
  if (!draft || !attachments) return undefined;
  const keys = [
    ...new Set(attachments.filter((chip) => chip.kind === "image" && validKey(chip.id)).map((chip) => chip.id)),
  ];
  if (!keys.length) return undefined;
  return { id: draft.id, keys: keys.slice(0, MAX_CARRIED_IMAGES) };
}

/// Each draft's images acpmux already holds, by key: the id acpmux answered for its bytes. A later
/// write names it by that id, so an image's bytes go once. By draft and key, never by bytes alone:
/// two chips of equal bytes are two images.
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
/// bytes when the page has them: those acpmux already holds go by id, the rest need them. A chip
/// whose id is no valid key stays the host's alone.
export function carriedChips(sessionId: string, attachments: readonly ComposerAttachment[]): ComposerAttachment[] {
  const draft = drafts.get(sessionId);
  const held = draft ? heldIds.get(draft.id) : undefined;
  return attachments
    .flatMap((chip) => {
      if (chip.kind !== "image" || !validKey(chip.id)) return [];
      const data = bytesOf(sessionId, chip);
      if (data) return [data === chip.data ? chip : { ...chip, data }];
      return held?.has(chip.id) ? [chip] : [];
    })
    .slice(0, MAX_CARRIED_IMAGES);
}

/// The `images` of `_acpmux/composer_set` for `chips` in draft `draftId`: an ACP image block for a
/// chip acpmux does not hold yet, `{id}` for one it does; each with its chip id as `key`.
export function draftImages(draftId: string, chips: readonly ComposerAttachment[]): Record<string, unknown>[] {
  const held = heldIds.get(draftId);
  return chips.map((chip) => {
    const id = held?.get(chip.id);
    if (id) return { id, key: chip.id };
    return {
      type: "image",
      mimeType: chip.mimeType || "image/png",
      data: chip.data,
      key: chip.id,
      ...(chip.name ? { name: chip.name } : {}),
    };
  });
}

/// Records which acpmux id each chip's bytes got in draft `draftId`, from composer_set's answer
/// (`images`, in order).
export function noteHeld(draftId: string, chips: readonly ComposerAttachment[], answer: unknown): void {
  const images = answer && typeof answer === "object" ? (answer as { images?: unknown }).images : undefined;
  if (!Array.isArray(images) || images.length !== chips.length) {
    heldIds.delete(draftId);
    return;
  }
  const held = new Map<string, string>();
  chips.forEach((chip, index) => {
    const id = (images[index] as { id?: unknown } | undefined)?.id;
    if (typeof id === "string") held.set(chip.id, id);
  });
  heldIds.set(draftId, held);
}

/// Forgets what acpmux holds for every chat (a new connection may reach another daemon). The draft
/// ids stay: they are the chats', kept by the host too.
export function forgetHeld(): void {
  heldIds.clear();
  seenBytes = undefined;
}

/// Forgets every chat's draft too (tests: a fresh page).
export function forgetDrafts(): void {
  forgetHeld();
  drafts.clear();
}

/// Tells acpmux chat `sessionId`'s unsent images from this page, in the chat's draft (`draftId`), or
/// that this page holds none. The draft's text stays the shared draft's (`_acpmux/draft_set`): this
/// surface's text is sent empty, so nothing is said twice. The write names the keys this page last
/// saw (`base`): acpmux drops those missing now and keeps any another pane added. A write refused
/// because acpmux lost an image it was named by id goes again with the bytes; one refused mid-move is
/// dropped (the next change writes again).
export async function writeCarriedImages(
  request: Request,
  sessionId: string,
  draftId: string,
  attachments: readonly ComposerAttachment[],
): Promise<void> {
  if (!validDraftId(draftId)) return;
  noteBytes(sessionId, attachments);
  const had = drafts.get(sessionId);
  const draft: DraftState = had?.id === draftId ? had : { id: draftId, base: [] };
  drafts.set(sessionId, draft);
  let chips = carriedChips(sessionId, attachments);
  const keys = chips.map((chip) => chip.id);
  const base = draft.replace ? undefined : draft.base;
  const surface = { ...pageSurface(), id: draftId };
  const send = () =>
    request("_acpmux/composer_set", {
      sessionId,
      surface,
      text: "",
      images: draftImages(draftId, chips),
      ...(base ? { base } : {}),
    });
  // What this page holds now is the next write's base, whatever the answer: a refused write's keys
  // are not in acpmux, so naming them as removed is harmless.
  draft.base = keys;
  draft.replace = undefined;
  let answer: unknown;
  try {
    answer = await send();
  } catch (error) {
    if (!(error instanceof AcpmuxRpcError) || error.reason !== "composer.image.unknown") throw error;
    // acpmux lost what it held: the chips with their bytes go again; one whose bytes the page no
    // longer has is left out (the host still keeps it on this Mac).
    heldIds.delete(draftId);
    chips = carriedChips(sessionId, attachments);
    answer = await send();
  }
  noteHeld(draftId, chips, answer);
}

/// One image a draft of the chat holds, as `_acpmux/composers` names it.
export type CarriedImage = { id: string; mimeType: string; name?: string; key?: string };

/// The one app draft of the chat that holds images, from `_acpmux/composers`' answer (a phone or the
/// CLI keeps its own): its id and images. None when no app draft holds images, or when several do
/// (drafts an older build left, one per page): which are still wanted is unknown, so none is taken
/// and all stay as they are. Images never merge across drafts.
export function carriedDraft(answer: unknown): { id: string; images: CarriedImage[] } | undefined {
  const composers = answer && typeof answer === "object" ? (answer as { composers?: unknown }).composers : undefined;
  if (!Array.isArray(composers)) return undefined;
  const found = composers.flatMap((composer) => {
    if (!composer || typeof composer !== "object") return [];
    const { kind, images, surfaceId: id } = composer as { kind?: unknown; images?: unknown; surfaceId?: unknown };
    if (kind !== undefined && kind !== "app") return [];
    if (!Array.isArray(images) || !images.length || !validDraftId(id)) return [];
    return [{ id, images }];
  });
  if (found.length !== 1) return undefined;
  const seen = new Set<string>();
  const images: CarriedImage[] = [];
  for (const image of found[0].images) {
    const { id, mimeType, name, key } = (image ?? {}) as {
      id?: unknown;
      mimeType?: unknown;
      name?: unknown;
      key?: unknown;
    };
    if (typeof id !== "string" || !id) continue;
    const named = typeof key === "string" && validKey(key) ? key : undefined;
    // A keyless image (an older build's) is told apart by its bytes alone.
    const which = named ?? `carried-${id}`;
    if (seen.has(which)) continue;
    seen.add(which);
    images.push({
      id,
      mimeType: typeof mimeType === "string" && mimeType ? mimeType : "image/png",
      ...(typeof name === "string" && name ? { name } : {}),
      ...(named ? { key: named } : {}),
    });
  }
  return { id: found[0].id, images: images.slice(0, MAX_CARRIED_IMAGES) };
}

/// The chip of an image acpmux kept for the chat, with its bytes (`_acpmux/attachment`): its id is
/// the image's key, so removing or sending it names that image.
export function carriedChip(image: CarriedImage, data: string, mimeType: string): ComposerAttachment {
  return {
    id: image.key ?? `carried-${image.id}`,
    kind: "image",
    // l10n-allow: a file name, shown as the chip's name when the image came without one.
    name: image.name ?? "image",
    mimeType,
    size: Math.floor((data.length * 3) / 4),
    data,
  };
}

/// The draft chat `sessionId` holds in acpmux and its chips: what a composer whose host keeps none
/// for the chat (a moved chat, another Mac, a page reopened empty) gets back, and the draft it then
/// writes. Nothing when the chat's drafts are ambiguous (carriedDraft). An image whose bytes cannot
/// be read is left out; nothing is thrown.
export async function readCarriedImages(
  request: Request,
  sessionId: string,
): Promise<{ draftId?: string; attachments: ComposerAttachment[] }> {
  const draft = carriedDraft(await request("_acpmux/composers", { sessionId }).catch(() => undefined));
  if (!draft) return { attachments: [] };
  const chips = await Promise.all(
    draft.images.map(async (image) => {
      const reply = (await request("_acpmux/attachment", { sessionId, id: image.id }).catch(() => undefined)) as
        | { data?: unknown; mimeType?: unknown }
        | undefined;
      if (typeof reply?.data !== "string" || !reply.data) return undefined;
      return carriedChip(image, reply.data, typeof reply.mimeType === "string" ? reply.mimeType : image.mimeType);
    }),
  );
  const attachments = chips.filter((chip): chip is ComposerAttachment => chip !== undefined);
  // An older build's images carry no key: the first write replaces the draft, so they can go.
  adoptDraft(
    sessionId,
    draft.id,
    attachments,
    draft.images.some((image) => !image.key),
  );
  return { draftId: draft.id, attachments };
}
