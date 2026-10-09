import { useEffect, useRef, useState } from "react";
import { MAX_ATTACHMENTS, MAX_IMAGE_BYTES, readAttachments, type AttachmentError, type ComposerAttachment } from "../attachments";

type Pending = { id: string; file: File; preview?: string };

/** Paste, drop and the file chooser share reservations and cancellation. Blob previews don't
 * wait for base64 encoding; pending entries never reach the transport. */
export function useAttachmentReads(
  held: number,
  allowImages: boolean,
  accept: (attachment: ComposerAttachment) => void,
  report: (error?: AttachmentError) => void,
) {
  const [pending, setPending] = useState<Pending[]>([]);
  const reads = useRef(new Map<string, Pending>());
  const latest = useRef({ held, allowImages, accept, report });
  latest.current = { held, allowImages, accept, report };
  const live = useRef(true);
  useEffect(() => {
    live.current = true;
    const active = reads.current;
    return () => {
      live.current = false;
      for (const entry of active.values()) if (entry.preview) URL.revokeObjectURL(entry.preview);
      active.clear();
    };
  }, []);
  const remove = (id: string) => {
    const entry = reads.current.get(id);
    if (!entry) return;
    reads.current.delete(id);
    if (entry.preview) URL.revokeObjectURL(entry.preview);
    if (live.current) setPending([...reads.current.values()]);
  };
  const add = async (files: File[]) => {
    if (!files.length) return;
    latest.current.report();
    const batch: Pending[] = [];
    for (const file of files) {
      if (latest.current.held + reads.current.size >= MAX_ATTACHMENTS) {
        latest.current.report({ name: file.name, reason: "tooMany" });
        continue;
      }
      let preview: string | undefined;
      if (latest.current.allowImages && file.size <= MAX_IMAGE_BYTES && /^image\/(png|jpeg|gif|webp)$/.test(file.type)) {
        try { preview = URL.createObjectURL(file); } catch { /* Some embedded hosts have no blob URL support. */ }
      }
      const entry = { id: crypto.randomUUID(), file, preview };
      reads.current.set(entry.id, entry);
      batch.push(entry);
    }
    setPending([...reads.current.values()]);
    // Read in selection order, while every preview is already visible.
    for (const entry of batch) {
      if (!reads.current.has(entry.id)) continue;
      const result = await readAttachments([entry.file], 0, latest.current.allowImages);
      if (!live.current || !reads.current.has(entry.id)) continue;
      if (result.attachments[0]) {
        latest.current.held += 1;
        latest.current.accept(result.attachments[0]);
      }
      if (result.errors[0]) latest.current.report(result.errors[0]);
      remove(entry.id);
    }
  };
  return { pending, add, remove, busy: () => reads.current.size > 0 };
}
