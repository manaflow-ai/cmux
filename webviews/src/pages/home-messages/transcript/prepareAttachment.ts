// A photo's or video's bytes go through the app's own preparation before they upload
// (`cmux.home.messages.attachments.prepare.*`, HomeAttachmentPreparer.swift), as the native
// composer's did: its location metadata is removed unless Settings > Home keeps it, and a type the
// owner refuses is converted. Other files upload as they are. Fails closed: a file the host could
// not prepare does not upload (its tray item shows the failure).
//
// Cost: a photo or video crosses to the app once in ~1 MB frames, and back only when the app
// changed it; a file with nothing to remove (or the setting on) uploads its original bytes.
import { attachmentClass, attachmentType } from "../../home-channels/attachmentService";
import type { PageClient } from "../../shared/pageClient";

const PREFIX = "cmux.home.messages.attachments.prepare.";
const CHUNK_BYTES = 1024 * 1024;
const READ_BYTES = 3 * 1024 * 1024;

/** Turns a picked or dropped file into the one to upload. */
export type PrepareFile = (file: File, signal: AbortSignal) => Promise<File>;

/** Whether `file` may carry location (a photo or a video, or a type only its bytes tell). */
export function mayCarryLocation(file: File): boolean {
  const type = attachmentType(file);
  if (!type) return true;
  const kind = attachmentClass(type);
  return kind === "image" || kind === "video";
}

/** The host's preparation over `client`. */
export function hostPrepareFile(client: PageClient): PrepareFile {
  return async (file, signal) => {
    if (!mayCarryLocation(file)) return file;
    const call = <T>(op: string, params: Record<string, unknown>) => {
      if (signal.aborted) throw new DOMException("aborted", "AbortError");
      return client.call<T>(PREFIX + op, params);
    };
    const begun = await call<{ keep?: boolean; id?: string }>("begin", {
      name: file.name,
      mimeType: file.type,
      byteCount: file.size,
    });
    if (begun.keep) return file;
    const id = begun.id;
    if (!id) throw new Error("the host prepared nothing");
    try {
      for (let offset = 0; offset < file.size; offset += CHUNK_BYTES) {
        const bytes = new Uint8Array(await file.slice(offset, offset + CHUNK_BYTES).arrayBuffer());
        await call("chunk", { id, offset, data: toBase64(bytes) });
      }
      const done = await call<{ changed?: boolean; name?: string; mimeType?: string; byteCount?: number }>("finish", {
        id,
      });
      if (!done.changed) return file;
      const size = done.byteCount ?? 0;
      const parts: Uint8Array[] = [];
      for (let offset = 0; offset < size; offset += READ_BYTES) {
        const piece = await call<{ data?: string }>("read", {
          id,
          offset,
          length: Math.min(READ_BYTES, size - offset),
        });
        parts.push(fromBase64(piece.data ?? ""));
      }
      const read = parts.reduce((total, piece) => total + piece.length, 0);
      if (read !== size) throw new Error("the host's prepared file came back short");
      return new File(parts as BlobPart[], done.name ?? file.name, { type: done.mimeType ?? file.type });
    } finally {
      void client.call(PREFIX + "end", { id }).catch(() => undefined);
    }
  };
}

function toBase64(bytes: Uint8Array): string {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
}

function fromBase64(data: string): Uint8Array {
  const text = atob(data);
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
  return bytes;
}
