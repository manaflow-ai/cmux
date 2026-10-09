import { useEffect, useRef, useState } from "react";
import {
  MAX_ATTACHMENTS,
  MAX_IMAGE_BYTES,
  readAttachments,
  type AttachmentError,
  type ComposerAttachment,
} from "../attachments";

type Pending = { id: string; file: File; preview?: string; reader?: FileReader };

/** Paste, drop and the file chooser share reservations and cancellation. Data URL previews use the
 * pane's existing image policy; pending entries never reach the transport. */
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
      for (const entry of active.values()) entry.reader?.abort();
      active.clear();
    };
  }, []);
  const remove = (id: string) => {
    const entry = reads.current.get(id);
    if (!entry) return;
    reads.current.delete(id);
    entry.reader?.abort();
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
      const entry: Pending = { id: crypto.randomUUID(), file };
      reads.current.set(entry.id, entry);
      batch.push(entry);
      if (
        latest.current.allowImages &&
        file.size <= MAX_IMAGE_BYTES &&
        /^image\/(png|jpeg|gif|webp)$/.test(file.type)
      ) {
        // FileReader produces a CSP-compatible preview independently of the transport read.
        // Only this small pending rail updates when the preview arrives; no polling.
        const Reader = globalThis.FileReader ?? globalThis.window?.FileReader;
        if (Reader) {
          const reader = new Reader();
          entry.reader = reader;
          reader.onload = () => {
            if (!live.current || !reads.current.has(entry.id) || typeof reader.result !== "string") return;
            entry.preview = reader.result;
            setPending([...reads.current.values()]);
          };
          try {
            reader.readAsDataURL(file);
          } catch {
            /* The normal read still reports unsupported files. */
          }
        }
      }
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
