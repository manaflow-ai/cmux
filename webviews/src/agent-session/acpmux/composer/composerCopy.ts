// A copy of the composer's selection with attachments in it (Leo, 2026-11-01: "i wanna be able to
// select all in composer which also selects all the attachments as the copy as well"). The
// pasteboard gets the text and each attachment as its own item, as Claude and ChatGPT desktop put
// them: a file each, an image's data with it (the host's `composer.copy`, AgentPaneComposerCopy.swift),
// so any app takes them. Where the text and the attachments sat between each other is kept beside
// it in this origin's storage: a paste of that same copy into a cmux composer puts each back in
// its place, the text, an image, more text, as copied (`pastePlan`).
import type { ComposerAttachment } from "../attachments";
import type { SelectionPart } from "./inlineNode";
import { postNative } from "../native";

/// One attachment as the host writes it to the pasteboard: its bytes (base64), its text, or the
/// file it links.
export type CopyItem = { name: string; mimeType: string } & ({ data: string } | { text: string } | { path: string });

/// What a copy carries: its text as any app pastes it, each attachment's item in order, and the order
/// of both (a run of text, or the attachment at `item` with the composer's id it was copied from).
export type ComposerCopy = {
  text: string;
  items: CopyItem[];
  parts: ({ text: string } | { item: number; id: string })[];
};

/// The base64 of the largest file the host writes for a copy (32 MiB).
const MAX_DATA_BASE64 = Math.ceil((32 << 20) / 3) * 4;

/// The pasteboard item of `attachment`; none for one with nothing to hand over (a shell run not yet run).
export function copyItem(attachment: ComposerAttachment): CopyItem | undefined {
  const { name, mimeType } = attachment;
  if (attachment.path) return { name, mimeType, path: attachment.path };
  // Past what the host takes in one item (AgentPaneImageCopies.maximumBytes): left out, never
  // refusing the copy's other attachments with it.
  if (attachment.data)
    return attachment.data.length <= MAX_DATA_BASE64 ? { name, mimeType, data: attachment.data } : undefined;
  if (attachment.text !== undefined && attachment.text !== "")
    return { name, mimeType: mimeType || "text/plain", text: attachment.text };
  return undefined;
}

/// The copy of a selection's `parts`, with `staged` the composer's attachments: those placed in the
/// selected text in their places, and with a `whole` selection (Select All) the ones shown only in
/// the strip too, first, as the strip shows them above the text. None when it holds no attachment:
/// the field's own copy of text stays as it is.
export function composerCopy(
  parts: readonly SelectionPart[],
  whole: boolean,
  staged: readonly ComposerAttachment[],
): ComposerCopy | undefined {
  const byId = new Map(staged.map((attachment) => [attachment.id, attachment]));
  const inText = new Set(parts.flatMap((part) => ("id" in part ? [part.id] : [])));
  const copy: ComposerCopy = { text: "", items: [], parts: [] };
  const add = (attachment: ComposerAttachment | undefined) => {
    const item = attachment && copyItem(attachment);
    if (!attachment || !item) return;
    copy.parts.push({ item: copy.items.length, id: attachment.id });
    copy.items.push(item);
  };
  if (whole) for (const attachment of staged) if (!inText.has(attachment.id)) add(attachment);
  for (const part of parts) {
    if ("id" in part) add(byId.get(part.id));
    else {
      copy.text += part.text;
      copy.parts.push({ text: part.text });
    }
  }
  return copy.items.length ? copy : undefined;
}

const STORE_KEY = "cmux.composer.copy.v1";

/// What a copy left on the pasteboard, as the host answered: each attachment item's file name, by
/// item, or null for one it left out (refused, unreadable). Undefined until it answers.
type Written = (string | null)[] | undefined;

type Remembered = { text: string; parts: ComposerCopy["parts"]; files?: (string | null)[] };

function globalStorage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

/// The order of the copy just made, kept for a paste of it into any composer of this origin, with
/// the files the host wrote once it says (`files`).
export function rememberCopy(copy: ComposerCopy, files?: Written, storage: Storage | undefined = globalStorage()) {
  try {
    const kept: Remembered = { text: copy.text, parts: copy.parts, ...(files ? { files } : {}) };
    storage?.setItem(STORE_KEY, JSON.stringify(kept));
  } catch {
    // Storage full or off: a paste of the copy puts its files in as any paste does.
  }
}

/// A copy of text alone (the field's own): the last attachment copy is no longer on the pasteboard.
export function forgetCopy(storage: Storage | undefined = globalStorage()) {
  try {
    storage?.removeItem(STORE_KEY);
  } catch {
    // Nothing kept.
  }
}

function remembered(storage: Storage | undefined): Remembered | undefined {
  try {
    const raw = storage?.getItem(STORE_KEY);
    if (!raw) return undefined;
    const value = JSON.parse(raw) as Partial<Remembered>;
    if (typeof value.text !== "string" || !Array.isArray(value.parts)) return undefined;
    const parts = value.parts.filter(
      (part): part is Remembered["parts"][number] =>
        Boolean(part) &&
        (typeof (part as { text?: unknown }).text === "string" ||
          (typeof (part as { item?: unknown }).item === "number" && typeof (part as { id?: unknown }).id === "string")),
    );
    const files = Array.isArray(value.files)
      ? value.files.map((name) => (typeof name === "string" ? name : null))
      : undefined;
    return { text: value.text, parts, ...(files ? { files } : {}) };
  } catch {
    return undefined;
  }
}

/// A piece of a paste put back in order: text, an attachment this composer still has (by the id it
/// was copied from), or a file from the pasteboard.
export type PastePart = { text: string } | { id: string } | { file: File };

const lines = (text: string) => text.replace(/\r\n?/g, "\n");

/// How a paste of a copy made here goes back in, in its order; none for any other paste (the field's
/// and the intake's own paste take it). The paste is that copy when its files are the ones the host
/// wrote for it, by name and in order: while the pasteboard holds file URLs WebKit gives a page the
/// files with no text, so the text comes from the copy kept here, never from the paste. A paste with
/// no files is the copy when its text is (the host wrote nothing, or the files did not come). Each
/// attachment comes back by id where this composer still has every one (`known`), else as its file.
export function pastePlan(
  data: DataTransfer | null,
  known: (id: string) => boolean,
  storage: Storage | undefined = globalStorage(),
): PastePart[] | undefined {
  if (!data) return undefined;
  const copy = remembered(storage);
  if (!copy) return undefined;
  const files = [...data.files];
  const text = lines(data.getData("text/plain"));
  /// Each item's file in the paste, by item.
  const fileOf = new Map<number, File>();
  if (files.length) {
    if (!copy.files) return undefined;
    const kept = copy.files.flatMap((name, item) => (name === null ? [] : [{ item, name }]));
    if (kept.length !== files.length || kept.some((each, index) => files[index]!.name !== each.name)) return undefined;
    // A text WebKit does give is the copy's own.
    if (text && text !== lines(copy.text)) return undefined;
    kept.forEach((each, index) => fileOf.set(each.item, files[index]!));
  } else if (!copy.text || text !== lines(copy.text)) return undefined;
  const ids = copy.parts.flatMap((part) => ("id" in part ? [part.id] : []));
  const byId = ids.length > 0 && ids.every(known);
  if (!byId && !files.length) return undefined;
  return copy.parts.flatMap((part): PastePart[] => {
    if ("text" in part) return [{ text: part.text }];
    if (byId) return [{ id: part.id }];
    const file = fileOf.get(part.item);
    return file ? [{ file }] : [];
  });
}

/// Pastes a composer put in itself (`pastePlan`): the intake's own paste listener leaves them.
export const pastesPlaced = new WeakSet<Event>();

/// Puts `copy` on the pasteboard: its order kept for a paste here, the text and each attachment
/// written by the host as their own items. The field already put the text there, so a host that
/// refuses (no gesture, a page outside the app) leaves the text copied.
export function writeComposerCopy(copy: ComposerCopy) {
  rememberCopy(copy);
  void postNative<{ files?: { item?: unknown; name?: unknown }[] }>("composer.copy", {
    text: copy.text,
    items: copy.items,
  })
    .then((reply) => {
      const files: (string | null)[] = copy.items.map(() => null);
      for (const each of reply?.files ?? [])
        if (typeof each.item === "number" && typeof each.name === "string" && each.item < files.length)
          files[each.item] = each.name;
      rememberCopy(copy, files);
    })
    .catch(() => rememberCopy(copy, []));
}
