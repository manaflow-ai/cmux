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
import { stageComposerCopy } from "./composerCopyStage";

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

/// The pasteboard item of `attachment`; none for one with nothing to hand over (a shell run not yet run).
export function copyItem(attachment: ComposerAttachment): CopyItem | undefined {
  const { name, mimeType } = attachment;
  if (attachment.path) return { name, mimeType, path: attachment.path };
  if (attachment.data) return { name, mimeType, data: attachment.data };
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
let pendingCopy: AbortController | undefined;

/// What a copy left on the pasteboard, as the host answered: each attachment item's file name, by
/// item, or null for one it left out (refused, unreadable). Undefined until it answers.
type Written = (string | null)[] | undefined;

type Remembered = {
  revision: string;
  text: string;
  parts: ComposerCopy["parts"];
  files?: (string | null)[];
  copyID?: string;
};

function globalStorage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

/// The order of the copy just made, kept for a paste of it into any composer of this origin, with
/// the files the host wrote once it says (`files`).
export function rememberCopy(
  copy: ComposerCopy,
  files?: Written,
  storage: Storage | undefined = globalStorage(),
  copyID?: string,
) {
  const revision = crypto.randomUUID();
  try {
    const kept: Remembered = {
      revision,
      text: copy.text,
      parts: copy.parts,
      ...(files ? { files } : {}),
      ...(copyID ? { copyID } : {}),
    };
    storage?.setItem(STORE_KEY, JSON.stringify(kept));
  } catch {
    // Storage full or off: a paste of the copy puts its files in as any paste does.
  }
  return revision;
}

/// A copy of text alone (the field's own): the last attachment copy is no longer on the pasteboard.
export function forgetCopy(storage: Storage | undefined = globalStorage()) {
  pendingCopy?.abort();
  pendingCopy = undefined;
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
    if (typeof value.revision !== "string" || typeof value.text !== "string" || !Array.isArray(value.parts))
      return undefined;
    const parts = value.parts.filter(
      (part): part is Remembered["parts"][number] =>
        Boolean(part) &&
        (typeof (part as { text?: unknown }).text === "string" ||
          (typeof (part as { item?: unknown }).item === "number" && typeof (part as { id?: unknown }).id === "string")),
    );
    const files = Array.isArray(value.files)
      ? value.files.map((name) => (typeof name === "string" ? name : null))
      : undefined;
    return {
      revision: value.revision,
      text: value.text,
      parts,
      ...(files ? { files } : {}),
      ...(typeof value.copyID === "string" ? { copyID: value.copyID } : {}),
    };
  } catch {
    return undefined;
  }
}

/// Large copies keep their compact order on the clipboard itself: browser storage quotas cannot
/// discard the prompt text when WebKit supplies file URLs without text/plain.
function clipboardCopy(rawHTML: string, copyID: string): Remembered | undefined {
  try {
    const html = document.createElement("template");
    html.innerHTML = rawHTML;
    const selection = html.content.querySelector("[data-cmux-composer-copy]");
    if (selection?.getAttribute("data-cmux-composer-copy") !== copyID) return undefined;
    const text = selection.textContent ?? "";
    const metadata = html.content.querySelector("[data-cmux-composer-order]");
    const order: unknown = JSON.parse(metadata?.getAttribute("data-cmux-composer-order") ?? "null");
    const files: unknown = JSON.parse(metadata?.getAttribute("data-cmux-composer-files") ?? "null");
    if (
      !Array.isArray(order) ||
      !Array.isArray(files) ||
      !files.every((name) => name === null || typeof name === "string")
    )
      return undefined;
    const parts: ComposerCopy["parts"] = [];
    for (const part of order) {
      if (!part || typeof part !== "object") return undefined;
      if (Array.isArray(part.range)) {
        const [start, end] = part.range as unknown[];
        if (
          !Number.isSafeInteger(start) ||
          !Number.isSafeInteger(end) ||
          Number(start) < 0 ||
          Number(end) < Number(start) ||
          Number(end) > text.length
        )
          return undefined;
        parts.push({ text: text.slice(Number(start), Number(end)) });
      } else {
        if (
          !Number.isSafeInteger(part.item) ||
          part.item < 0 ||
          part.item >= files.length ||
          typeof part.id !== "string"
        )
          return undefined;
        parts.push({ item: part.item, id: part.id });
      }
    }
    return { revision: copyID, copyID, text, parts, files };
  } catch {
    return undefined;
  }
}

/// A piece of a paste put back in order: text, an attachment this composer still has (by the id it
/// was copied from), or a file from the pasteboard.
export type PastePart = { text: string } | { id: string } | { file: File };

const lines = (text: string) => text.replace(/\r\n?/g, "\n");

/// How a paste of a copy made here goes back in, in its order; none for any other paste (the field's
/// and the intake's own paste take it). The host puts a unique marker in the clipboard's HTML:
/// WebKit preserves it alongside files even when it hides their plain text. File names alone cannot
/// identify a copy: consecutive screenshots often share a name. Each
/// attachment comes back by id where this composer still has every one (`known`), else as its file.
export function pastePlan(
  data: DataTransfer | null,
  known: (id: string) => boolean,
  storage: Storage | undefined = globalStorage(),
): PastePart[] | undefined {
  if (!data) return undefined;
  let copy = remembered(storage);
  // The host's marker precedes the text. Bound the inert parse even for a very large HTML paste.
  const html = document.createElement("template");
  const rawHTML = data.getData("text/html");
  html.innerHTML = rawHTML.slice(0, 4096);
  const copyID = html.content.querySelector("[data-cmux-composer-copy]")?.getAttribute("data-cmux-composer-copy");
  if (!copyID) return undefined;
  if (copy?.copyID !== copyID) copy = clipboardCopy(rawHTML, copyID);
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

export type ComposerCopyStatus =
  | { phase: "copying"; written: number; total: number; cancel: () => void }
  | { phase: "failed"; retry: () => void }
  | undefined;

/// Puts `copy` on the pasteboard: its order kept for a paste here, the text and each attachment
/// written by the host as their own items. The field already put the text there, so a host that
/// refuses (no gesture, a page outside the app) leaves the text copied.
export function writeComposerCopy(
  copy: ComposerCopy,
  status?: (state: ComposerCopyStatus) => void,
  complete?: () => void,
) {
  pendingCopy?.abort();
  const controller = new AbortController();
  pendingCopy = controller;
  const current = () => pendingCopy === controller;
  const aborted = () => {
    if (current()) status?.(undefined);
  };
  controller.signal.addEventListener("abort", aborted, { once: true });
  const storage = globalStorage();
  const revision = rememberCopy(copy, undefined, storage);
  const cancel = () => controller.abort();
  let staged = false;
  void stageComposerCopy(copy, postNative, {
    signal: controller.signal,
    progress(written, total) {
      staged = true;
      if (!controller.signal.aborted) status?.({ phase: "copying", written, total, cancel });
    },
  })
    .then((reply) => {
      if (staged && current()) status?.(undefined);
      if (current() && !controller.signal.aborted) complete?.();
      if (remembered(storage)?.revision !== revision) return;
      const files: (string | null)[] = copy.items.map(() => null);
      for (const each of reply?.files ?? [])
        if (typeof each.item === "number" && typeof each.name === "string" && each.item < files.length)
          files[each.item] = each.name;
      rememberCopy(copy, files, storage, reply?.copyID);
    })
    .catch(() => {
      if (remembered(storage)?.revision === revision) {
        try {
          storage?.removeItem(STORE_KEY);
        } catch {
          /* Storage is unavailable. */
        }
      }
      if (staged && !controller.signal.aborted)
        status?.({ phase: "failed", retry: () => writeComposerCopy(copy, status, complete) });
    })
    .finally(() => {
      if (pendingCopy === controller) pendingCopy = undefined;
      controller.signal.removeEventListener("abort", aborted);
    });
}
