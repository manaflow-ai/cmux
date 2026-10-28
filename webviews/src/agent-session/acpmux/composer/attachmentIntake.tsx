// The prompt's attachments, one implementation for every composer (Leo 2026-10-19: "i cant paste in
// pictures in the new tab area but it works in the existing chats"): a chat's composer (Composer.tsx)
// and the New Tab page's field (newtab/NewTabScreen.tsx) take a pasted or dropped image or file the
// same way, show it as the same chip, and send it with the prompt.
import React, { useCallback, useContext, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import { Dialog } from "../../../ui/Dialog";
import {
  filesFrom,
  isImageFile,
  pastedImageFiles,
  installFileDropLifecycle,
  thumbnail,
  type AttachmentError,
  type ComposerAttachment,
  type DroppedKind,
  type LinkItem,
} from "../attachments";
import type { UploadResult } from "../cloudUploads";
import { ImageViewerContext } from "../conversation/imageViewerContext";
import { Close, FileDoc, ImageIcon, Spinner } from "../conversation/icons";
import { type StringKey, type Translate, usePaneLanguage, useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { pasteLines, pasteName } from "../conversation/promptCollapse";
import { keptThumb } from "./imagePool";
import { useStripReorder } from "./stripReorder";
import { intakeFiles, type IntakeError } from "./intakeFiles";
import { type DropOverlayState, HIDDEN_DROP, landDropOverlay, stepDropOverlay } from "./dropOverlayState";
import { FADE_BAND_PX } from "../MarkdownField";
import { useScrollEdges } from "../summary/scrollEdges";
import { callChipHost } from "../chips/host";
import { isVideoAttachment, useVideoInfo, useVideoReading } from "./videoAttachments";
import { VideoAttachmentTile } from "./VideoAttachmentTile";
import { FileAttachment } from "../FileAttachment";

const ATTACHMENT_LABELS = {
  attachments: "composer.attachments",
  removeAttachment: "composer.removeAttachment",
  openAttachment: "composer.openAttachment",
  sentAsFileForCodex: "composer.sentAsFileForCodex",
  tooLarge: "composer.tooLarge",
  unsupported: "composer.unsupported",
  imagesUnsupported: "composer.imagesUnsupported",
  pastedText: "composer.pastedText",
  pastedLines: "transcript.pastedLines",
  editPasted: "composer.pastedText.edit",
  cancelAttachment: "composer.cancelAttachment",
  retryAttachment: "composer.retryAttachment",
  reorderHint: "composer.reorderAttachmentsHint",
  moved: "composer.attachmentMoved",
} as const satisfies Record<string, StringKey>;

export function attachmentErrorText(error: AttachmentError, t: Translate): string {
  return t(ATTACHMENT_LABELS[error.reason], { name: error.name });
}

function intakeErrorText(error: IntakeError, t: Translate): string {
  return "text" in error ? error.text : attachmentErrorText(error, t);
}

export type AttachmentIntakeOptions = {
  /// The agent takes images (`promptCapabilities.image`); false refuses an image with a note.
  allowImages: boolean;
  /// Whether a paste on `target` is this composer's: undefined is not; `uploads` false keeps its
  /// files for the next prompt and uploads nothing (a chat's shell mode).
  pasteTarget(target: Node): { uploads: boolean } | undefined;
  /// The chat's host saves what the composer can't attach (cloudUploads.ts); its chip sends the path.
  upload?(files: File[], cancelled?: (index: number) => boolean): Promise<UploadResult>;
  /// For a chat on this Mac: where the files of the person's drop or paste are (composer/intakeFiles.ts
  /// droppedPaths), so a folder or a file no block takes goes as a link to it, tried before `upload`.
  localPaths?(kind: DroppedKind, files: File[]): Promise<LinkItem[] | undefined>;
  /// The chat column a file drag lifts the drop overlay over (composer/dropOverlayState.ts): over
  /// it a drop attaches; elsewhere in the pane the overlay only arms. Unset: the whole page.
  dropZone?(): Element | null;
  /// The chat the composer shows. A file is the chat's it was pasted or dropped in: its placeholder
  /// shows only there, and a read that ends after the composer moved to another chat hands its
  /// chips to `elsewhere` instead of this chat's strip.
  scope?: string;
  /// Keeps chips whose read ended after the composer left `scope` for that chat (keptAttachments.ts).
  elsewhere?(scope: string, attachments: ComposerAttachment[]): void;
  /// A chat on this Mac, whose attached videos the host may read (composer/videoAttachments.ts);
  /// `localPaths` says so too. Quick Chat has no `localPaths` but is on this Mac.
  localChat?: boolean;
  /// When the composer moves to another chat: whether the files still being read move with it (a
  /// harness switch's new session carries the prompt). A chat that had no id yet always carries.
  carries?(): boolean;
};

/** Append a batch while replacing the same attachment id and collapsing repeated local path links
 * (for example, highlighting the same element or dropping the same folder twice). */
export function appendAttachments(
  current: readonly ComposerAttachment[],
  added: readonly ComposerAttachment[],
): ComposerAttachment[] {
  const result = [...current];
  const ids = new Map<string, number>();
  const links = new Map<string, number>();
  result.forEach((attachment, index) => {
    ids.set(attachment.id, index);
    if (attachment.kind === "link" && attachment.path) links.set(attachment.path, index);
  });
  for (const attachment of added) {
    const previous =
      ids.get(attachment.id) ??
      (attachment.kind === "link" && attachment.path ? links.get(attachment.path) : undefined);
    if (previous !== undefined) {
      result[previous] = attachment;
      ids.set(attachment.id, previous);
      if (attachment.kind === "link" && attachment.path) links.set(attachment.path, previous);
      continue;
    }
    ids.set(attachment.id, result.length);
    if (attachment.kind === "link" && attachment.path) links.set(attachment.path, result.length);
    result.push(attachment);
  }
  return result;
}

/// A chip shown the moment a file is pasted, dropped or chosen, while the composer reads, scales or
/// saves it (intakeFiles.ts can take a large screenshot hundreds of ms): the chip it becomes, or
/// the refusal's note, takes its place. Leo 2026-10-21: "ME PASTING IT DOESN'T JUST PASTE RIGHT
/// INTO THE COMPOSER IMMEDIATELY". It spins while it loads and its × cancels it; one that could not
/// be attached stays, saying why (`failed`), with Retry (Leo, 2026-10-24: "why don't you put a
/// spinner on the attachment rather than this placeholder that doesn't do anything... I can't even
/// cancel these").
export type PendingAttachment = {
  id: string;
  name: string;
  image: boolean;
  scope?: string;
  failed?: string;
  /// Streaming to the session's machine (a file of any size): a send goes without waiting for it,
  /// and it stays for the next prompt (Leo, 2026-10-25: "...prevent new things from happening").
  uploading?: boolean;
};

/// What Retry needs of a pending chip: its file and how it came in.
/// Whether chip `chip` (an image whose original may still upload) was taken out of its chat's
/// strip, by its x or a send, so its original goes nowhere. Not when it went to another chat
/// (`stagedHere` false), the strip has not drawn it yet (`everDrawn` false), or the strip is
/// another chat's (`showing` is not the chat it was pasted in): there it is only out of view.
export function chipRemoved(state: {
  chip: string;
  stagedHere: boolean;
  everDrawn: boolean;
  pastedIn: string | undefined;
  showing: string | undefined;
  strip: readonly ComposerAttachment[];
}): boolean {
  if (!state.stagedHere || !state.everDrawn || state.pastedIn !== state.showing) return false;
  return !state.strip.some((attachment) => attachment.id === state.chip);
}

/// `file`: a promise while its bytes are still being made (MadeFile).
type PendingSource = { file: File | Promise<File>; uploads: boolean };

/// A file whose bytes are still being made (pastedText.ts pastedTextFile): its tile shows at once,
/// by its name and type, and it is read once `file` settles.
export type MadeFile = { name: string; type: string; file: Promise<File> };

/// Whether `file` is a MadeFile, by its shape: a File from another window (a test's DOM, a drop
/// from a frame) is not `instanceof` this one's File.
function isMadeFile(file: File | MadeFile): file is MadeFile {
  return "file" in file && typeof (file as MadeFile).file?.then === "function";
}

/// The prompt's staged attachments: what a paste on the composer's field or a file drop anywhere on
/// the page adds (the document-level drop contract, attachments.ts), with the note a refusal leaves.
/// `attach(files, uploads, kind)` adds files another way (the + menu's chooser, which uploads like a
/// drop, or a capture). `pending`: the files still being read, shown at once (PendingAttachment).
export function useAttachmentIntake(options: AttachmentIntakeOptions) {
  const t = useT();
  const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
  const [pending, setPending] = useState<PendingAttachment[]>([]);
  const [attachError, setAttachError] = useState<string | undefined>();
  const [dropping, setDropping] = useState(false);
  /// The drop overlay's state (composer/DropOverlay.tsx). Kept in a ref too: a refused drag's
  /// `dropEffect` is set inside the drag event, before any render.
  const [drop, setDropState] = useState<DropOverlayState>(HIDDEN_DROP);
  const dropRef = useRef<DropOverlayState>(HIDDEN_DROP);
  const [showDrop] = useState(() => (next: DropOverlayState) => {
    if (next === dropRef.current) return;
    dropRef.current = next;
    setDropState(next);
  });
  const live = useRef({ options, t });
  live.current = { options, t };
  /// Each batch still being read, with the chat it belongs to (`scope`).
  const batches = useRef(new Set<{ scope?: string }>());
  /// Each pending chip's file, for Retry; a chip cancelled by its × is gone from here, so what its
  /// read makes later is dropped.
  const sources = useRef(new Map<string, PendingSource>());
  /// The staged chips now, for an upload to see that its chip was removed (its x, or a send).
  const stagedNow = useRef<readonly ComposerAttachment[]>([]);
  stagedNow.current = attachments;
  /// The chips a render has staged: one not yet rendered is not gone, only not drawn yet.
  const everStaged = useRef(new Set<string>());
  for (const attachment of attachments) everStaged.current.add(attachment.id);
  /// Each intake chip's place in paste order (its gesture, then its file), so a chip ready first
  /// still lands where it was pasted, across batches too.
  const places = useRef(new Map<string, number>());
  const gestures = useRef(0);
  const scope = options.scope;
  const lastScope = useRef(scope);
  // Before paint: a carried placeholder never leaves the strip for a frame.
  useLayoutEffect(() => {
    const from = lastScope.current;
    lastScope.current = scope;
    if (from === scope || (from !== undefined && !live.current.options.carries?.())) return;
    for (const batch of batches.current) if (batch.scope === from) batch.scope = scope;
    setPending((chips) => chips.map((chip) => (chip.scope === from ? { ...chip, scope } : chip)));
  }, [scope]);
  /// `uploads`: the person dropped, pasted or chose these, so the chat's host may save what the
  /// composer can't attach (a moved chat's machine, or this Mac for a local chat) and its chip sends
  /// the saved path (composer/intakeFiles.ts); never a capture. `kind`: the person's own drop or
  /// paste, whose files the host of a chat on this Mac knows the paths of (`localPaths`).
  const [attach] = useState(() => async (given: (File | MadeFile)[], uploads = false, kind?: DroppedKind) => {
    if (given.length === 0) return;
    const files = given;
    const { options: current } = live.current;
    const batch = { scope: current.scope };
    // In the paste's or drop's own task, so React draws them before the next frame.
    const shown: PendingAttachment[] = files.map((file) => ({
      id: crypto.randomUUID(),
      name: file.name,
      image: isImageFile(file),
      scope: batch.scope,
    }));
    shown.forEach((chip, index) => {
      const file = files[index]!;
      sources.current.set(chip.id, { file: isMadeFile(file) ? file.file : file, uploads });
    });
    const gesture = (gestures.current += 1);
    batches.current.add(batch);
    setPending((chips) => [...chips, ...shown]);
    const paths = current.localPaths;
    /// The chip each file became, by index, for its original's path arriving later.
    const made: (string | undefined)[] = [];
    /// The chips this batch put in this chat's strip (not handed to another chat).
    const staged = new Set<string>();
    const marked = new Set<number>();
    // Each file's placeholder goes in the same render as what it became, the moment it is ready.
    const settle = (index: number) => {
      const id = shown[index]!.id;
      if (!sources.current.delete(id)) return false;
      setPending((chips) => chips.filter((chip) => chip.id !== id));
      return true;
    };
    const ready = (index: number, attachment: ComposerAttachment) => {
      if (!settle(index)) return;
      made[index] = attachment.id;
      // The composer moved to another chat meanwhile: the chip is the chat's it was pasted in.
      const now = live.current.options;
      if (batch.scope !== now.scope) {
        if (batch.scope !== undefined) now.elsewhere?.(batch.scope, [attachment]);
        return;
      }
      // In paste order, whichever file was ready first: before the first staged chip pasted after it.
      const place = gesture * 100_000 + index;
      places.current.set(attachment.id, place);
      staged.add(attachment.id);
      setAttachments((staged) => {
        const at = staged.findIndex((chip) => (places.current.get(chip.id) ?? -1) > place);
        if (at < 0 || staged.some((chip) => chip.id === attachment.id)) return appendAttachments(staged, [attachment]);
        return [...staged.slice(0, at), attachment, ...staged.slice(at)];
      });
    };
    const failed = (index: number, error: IntakeError) => {
      const id = shown[index]!.id;
      if (!sources.current.has(id)) return;
      marked.add(index);
      const failed = intakeErrorText(error, live.current.t);
      setPending((chips) => chips.map((chip) => (chip.id === id ? { ...chip, failed } : chip)));
    };
    try {
      // A file still being made (a huge paste's text, made a slice per task) is awaited here, after
      // its tile drew.
      const settled = await Promise.all(files.map((file) => (isMadeFile(file) ? file.file : file)));
      // The bytes are made: Retry reads these, never the promise again.
      settled.forEach((file, index) => {
        const id = shown[index]!.id;
        const source = sources.current.get(id);
        if (source) sources.current.set(id, { ...source, file });
      });
      await intakeFiles(
        settled,
        {
          allowImages: current.allowImages,
          ...(kind && paths ? { localPaths: (batch: File[]) => paths(kind, batch) } : {}),
          ...(uploads && current.upload ? { upload: current.upload } : {}),
          // A file not yet a chip: its tile's x. One already a chip (an image whose original still
          // uploads): the chip is gone from the strip (its x, or it was sent), so its original
          // would go nowhere.
          cancelled: (index) => {
            const chip = made[index];
            if (!chip) return !sources.current.has(shown[index]!.id);
            return chipRemoved({
              chip,
              stagedHere: staged.has(chip),
              everDrawn: everStaged.current.has(chip),
              pastedIn: batch.scope,
              showing: live.current.options.scope,
              strip: stagedNow.current,
            });
          },
        },
        {
          ready,
          failed,
          uploading: (index) => {
            const id = shown[index]!.id;
            setPending((chips) => chips.map((chip) => (chip.id === id ? { ...chip, uploading: true } : chip)));
          },
          original: (index, path, name) => {
            const id = made[index];
            setAttachments((staged) =>
              staged.map((chip) => (chip.id === id ? { ...chip, originalPath: path, originalName: name } : chip)),
            );
          },
        },
      );
    } finally {
      batches.current.delete(batch);
      // A file intake said nothing of (it threw) is not left loading.
      shown.forEach((chip, index) => {
        if (sources.current.has(chip.id) && !marked.has(index))
          failed(index, { name: chip.name, reason: "unsupported" });
      });
    }
  });
  /// A pending chip's ×: it goes, and whatever its read makes later is dropped.
  const [cancel] = useState(() => (id: string) => {
    sources.current.delete(id);
    setPending((chips) => chips.filter((chip) => chip.id !== id));
  });
  /// A failed chip's Retry: its file is read again (and uploaded again when it was).
  const [retry] = useState(() => (id: string) => {
    const source = sources.current.get(id);
    const file = source?.file;
    // A file whose bytes were never made (making them failed) has nothing to retry.
    if (!source || !file || "then" in file) return;
    cancel(id);
    // Without the paste's kind: the host's record of where its files are was for that gesture only.
    void attach([file], source.uploads);
  });
  useEffect(() => {
    const paste = (event: ClipboardEvent) => {
      const owned = live.current.options.pasteTarget(event.target as Node);
      if (!owned) return;
      const pasted = filesFrom(event.clipboardData);
      // An image copied as HTML only (from a page or the transcript) or as `![…](data:…)` text (a
      // prompt copied from a bubble) comes in as a chip too; its text still goes into the field (a
      // textarea's own paste, the prompt's handler), without the images.
      const other = pasted.length ? undefined : pastedImageFiles(event.clipboardData);
      const files = other ? other.files : pasted;
      if (!other) event.preventDefault();
      if (files.length) void attach(files, owned.uploads, "paste");
      if (other?.text !== undefined) pasteTextInto(event, other.text);
    };
    const removeFileDropLifecycle = installFileDropLifecycle(
      (files) => {
        showDrop(landDropOverlay(dropRef.current, files));
        void attach(files, true, "drop");
      },
      (active, event) => {
        setDropping(active);
        const { allowImages, dropZone } = live.current.options;
        showDrop(stepDropOverlay(dropRef.current, active, event, allowImages, dropZone?.()));
      },
    );
    document.addEventListener("paste", paste);
    return () => {
      removeFileDropLifecycle();
      document.removeEventListener("paste", paste);
    };
  }, [attach, showDrop]);
  const shown = pending.filter((chip) => chip.scope === scope);
  /// The chips still loading that a send waits for: a failed one waits for its Retry or x, and one
  /// streaming to the session's machine stays for the next prompt, neither holds the send.
  const loading = shown.filter((chip) => !chip.failed && !chip.uploading).length;
  /// The chips not yet a chip or a failure, uploads included (useSendWhenAttached's `unsettled`).
  const unsettled = shown.filter((chip) => !chip.failed).length;
  /// The video chips whose poster and frames the host still reads, for a chat on this Mac: a send
  /// waits for them a few seconds at most (composer/videoAttachments.ts).
  const videoReading = useVideoInfo(
    attachments,
    setAttachments,
    Boolean(options.localPaths) || options.localChat === true,
  );
  /// The landing animation ended: the overlay hides.
  const [dropLanded] = useState(() => () => showDrop(HIDDEN_DROP));
  return {
    attachments,
    setAttachments,
    pending: shown,
    loading,
    unsettled,
    videoReading,
    cancel,
    retry,
    attachError,
    setAttachError,
    dropping,
    drop,
    dropLanded,
    attach,
  };
}

/// A prompt sent while its files are still being read (`pending`) is held and goes, once, when the
/// last of them is a chip, so it never leaves without them. `hold(send)` holds it when there are
/// pending files (true; a later hold replaces it) and does nothing otherwise (false). `send` runs
/// after the render that has the chips, so it must read the composer's state then (a ref). A new
/// `scope` (the composer moved to another chat) drops a held prompt: it never goes to another chat.
///
/// `unsettled` (default `pending`) also counts the files streaming to the session's machine: a send
/// made while files were still being read waits for those too, so the files it was sent with go
/// with it (or their x lets it go without them); a send made once only uploads are left goes at
/// once, and they stay for the next prompt. While one waits, a later send replaces it.
export function useSendWhenAttached(
  pending: number,
  scope?: string,
  unsettled: number = pending,
): (send: () => void) => boolean {
  const held = useRef<(() => void) | undefined>(undefined);
  const count = useRef(pending);
  count.current = pending;
  useEffect(() => {
    held.current = undefined;
  }, [scope]);
  useEffect(() => {
    const send = held.current;
    if (unsettled > 0 || !send) return;
    held.current = undefined;
    send();
  }, [unsettled]);
  const [hold] = useState(() => (send: () => void) => {
    if (count.current === 0 && !held.current) return false;
    held.current = send;
    return true;
  });
  return hold;
}

/// Puts `text` in place of a paste's own text in a plain text field (the New Tab prompt), so the
/// images lifted out of it never land there as base64; the prompt field takes its paste itself.
function pasteTextInto(event: ClipboardEvent, text: string) {
  const target = event.target as Node | null;
  const view = target?.ownerDocument?.defaultView;
  if (!view || !(target instanceof view.HTMLTextAreaElement || target instanceof view.HTMLInputElement)) return;
  event.preventDefault();
  if (!text || target.ownerDocument.execCommand?.("insertText", false, text)) return;
  const end = target.value.length;
  target.setRangeText(text, target.selectionStart ?? end, target.selectionEnd ?? end, "end");
  target.dispatchEvent(new view.Event("input", { bubbles: true }));
}

/// Backspace with the caret at the prompt's start (`atStart`: nothing for the key to delete or
/// lift there) takes back the last staged chip, as a chat composer's Backspace does, so a pasted
/// image goes without reaching for its ×. A held key's repeat does not: holding Backspace to
/// clear the prompt stops at its start.
export function backspacedAttachment(
  event: { key: string; repeat: boolean; shiftKey: boolean; altKey: boolean; metaKey: boolean; ctrlKey: boolean },
  atStart: boolean,
  attachments: readonly ComposerAttachment[],
): ComposerAttachment | undefined {
  if (event.key !== "Backspace" || event.repeat || !atStart) return undefined;
  if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return undefined;
  return attachments[attachments.length - 1];
}

/// The staged attachments' chips over the prompt, with a refusal's note.
export function AttachmentStrip({
  attachments,
  pending = [],
  error,
  codex = false,
  onRemove,
  onExpand,
  onCancel,
  onRetry,
  onReorder,
}: {
  attachments: readonly ComposerAttachment[];
  /// A staged chip dragged (or moved with Option-Left/Right) to `index`; unset, chips stay put.
  onReorder?(id: string, index: number): void;
  /// Files still being read: a placeholder chip each, after the staged ones (PendingAttachment).
  pending?: readonly PendingAttachment[];
  /// A pending chip's ×; unset, the chip has none.
  onCancel?(id: string): void;
  /// A failed chip's Retry; unset, the chip has none.
  onRetry?(id: string): void;
  error?: string;
  codex?: boolean;
  onRemove(id: string): void;
  /// A pasted text chip's click: its text goes back into the prompt (pastedText.ts). Unset, the chip
  /// only shows.
  onExpand?(id: string): void;
}) {
  const t = useT();
  // More chips than fit scroll sideways: the side with chips past it is marked, and the CSS fades it
  // by the prompt's band (composerAttachments.css).
  const edges = useScrollEdges("x");
  /// What a move says to assistive technology: the chip and where it is now.
  const [announced, setAnnounced] = useState("");
  // The chips and the pane's language as they are now: the move below is made once.
  const live = useRef({ attachments, t });
  live.current = { attachments, t };
  const [move] = useState(() => (id: string, index: number) => {
    const { attachments: chips, t: translate } = live.current;
    const chip = chips.find((attachment) => attachment.id === id);
    reorderTo.current?.(id, index);
    if (chip)
      setAnnounced(translate(ATTACHMENT_LABELS.moved, { name: chip.name, position: index + 1, count: chips.length }));
  });
  const reorderTo = useRef(onReorder);
  reorderTo.current = onReorder;
  const reorder = useStripReorder(
    attachments.map((attachment) => attachment.id),
    onReorder ? move : undefined,
  );
  const hint = useId();
  const reorderRef = reorder.ref;
  const stripRef = useCallback(
    (node: HTMLElement | null) => {
      edges(node);
      reorderRef(node);
    },
    [edges, reorderRef],
  );
  // The drop overlay says what a drag does (composer/DropOverlay.tsx); a note here would grow the
  // composer mid-drag.
  if (attachments.length === 0 && pending.length === 0 && !error) return null;
  return (
    <fieldset
      ref={stripRef}
      className="acpmux-attachments"
      data-reorder={onReorder && attachments.length > 1 ? "" : undefined}
      aria-describedby={onReorder && attachments.length > 1 ? hint : undefined}
      aria-label={t(ATTACHMENT_LABELS.attachments)}
      style={{ "--acpmux-md-fade-band": `${FADE_BAND_PX}px` } as React.CSSProperties}
    >
      {attachments.map((attachment, index) => (
        // A slot that draws nothing of its own (display: contents): it names the chip for a drag.
        <div
          key={attachment.id}
          className="acpmux-attachment-slot"
          data-attachment-index={index}
          data-dragging={reorder.dragging === attachment.id || undefined}
        >
          <AttachmentChip
            attachment={attachment}
            codex={codex}
            onRemove={onRemove}
            {...(onExpand ? { onExpand } : {})}
          />
        </div>
      ))}
      {pending.map((chip) => (
        <PendingChip key={chip.id} chip={chip} {...(onCancel ? { onCancel } : {})} {...(onRetry ? { onRetry } : {})} />
      ))}
      {error && <output className="acpmux-attachment-note">{error}</output>}
      {onReorder && attachments.length > 1 && (
        <span id={hint} className="visually-hidden acpmux-attachment-voiceover-only">
          {t(ATTACHMENT_LABELS.reorderHint)}
        </span>
      )}
      <output className="visually-hidden acpmux-attachment-voiceover-only" aria-live="polite">
        {announced}
      </output>
    </fieldset>
  );
}

/// A file still being read: an image's tile in the shape of an image chip, or a file's chip with its
/// name, with a spinner and a × that cancels it. One that could not be attached says why, with
/// Retry.
function PendingChip({
  chip,
  onCancel,
  onRetry,
}: {
  chip: PendingAttachment;
  onCancel?(id: string): void;
  onRetry?(id: string): void;
}) {
  const t = useT();
  const name = chip.image ? imageLabel(t, { name: chip.name }) : chip.name;
  const remove = onCancel && (
    <button
      type="button"
      className="acpmux-attachment-remove"
      aria-label={t(chip.failed ? ATTACHMENT_LABELS.removeAttachment : ATTACHMENT_LABELS.cancelAttachment, { name })}
      onClick={() => onCancel(chip.id)}
    >
      <svg viewBox="0 0 16 16" width="8" height="8" aria-hidden="true">
        <path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      </svg>
    </button>
  );
  const kind = chip.image ? "acpmux-attachment-image" : "acpmux-attachment-file";
  if (chip.failed)
    return (
      <div className={`acpmux-attachment ${kind} acpmux-attachment-failed`} aria-label={name}>
        <span
          className="acpmux-attachment-failed-text"
          /* tooltip-allow: the note is cut to the tile; the tooltip has all of it */ title={chip.failed}
        >
          {chip.failed}
        </span>
        {onRetry && (
          <button type="button" className="acpmux-attachment-retry" onClick={() => onRetry(chip.id)}>
            {t(ATTACHMENT_LABELS.retryAttachment)}
          </button>
        )}
        {remove}
      </div>
    );
  return (
    <div className={`acpmux-attachment ${kind} acpmux-attachment-pending`} aria-busy="true" aria-label={name}>
      <Spinner loading size={16} className="acpmux-attachment-spinner" />
      {!chip.image && <span>{chip.name}</span>}
      {remove}
    </div>
  );
}

function AttachmentChip({
  attachment,
  codex = false,
  onRemove,
  onExpand,
}: {
  attachment: ComposerAttachment;
  codex?: boolean;
  onRemove(id: string): void;
  onExpand?(id: string): void;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const openImage = useContext(ImageViewerContext);
  const [broken, setBroken] = useState(false);
  const [thumb, setThumb] = useState<{ url: string; width: number; height: number } | undefined>(() =>
    keptThumb(attachment.id),
  );
  /// The image's natural size, from its thumbnail or from the image itself once it loads.
  const [size, setSize] = useState<{ width: number; height: number }>();
  const videoReading = useVideoReading(attachment.id);
  const isImage = attachment.kind === "image" && Boolean(attachment.data);
  const image = isImage && !broken;
  const source = image ? `data:${attachment.mimeType};base64,${attachment.data}` : undefined;
  // A pasted image's name is WebKit's "image.png": show what it is instead (imageLabel.ts).
  const pasted = attachment.kind === "pasted";
  const name = isImage
    ? imageLabel(t, { name: attachment.name, ...(thumb ?? size) })
    : pasted
      ? t(ATTACHMENT_LABELS.pastedText)
      : attachment.name;
  useEffect(() => {
    if (!image || !attachment.data || keptThumb(attachment.id)) return;
    let live = true;
    void thumbnail({ mimeType: attachment.mimeType, data: attachment.data }).then((made) => {
      if (live) setThumb(made);
    });
    return () => {
      live = false;
    };
  }, [attachment.data, attachment.id, attachment.mimeType, image]);
  const remove = (
    <button
      type="button"
      className="acpmux-attachment-remove"
      aria-label={t(ATTACHMENT_LABELS.removeAttachment, { name })}
      onClick={() => onRemove(attachment.id)}
    >
      <svg viewBox="0 0 16 16" width="8" height="8" aria-hidden="true">
        <path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      </svg>
    </button>
  );
  // Its right-click menu: Open (or what a click does) where a click opens it, and Remove (cx-2lm4).
  const menu = (open: (() => void) | undefined, chip: React.ReactNode, openLabel = t("image.open")) => (
    <ContextMenu
      className="acpmux-attachment-menu"
      items={[
        ...(open ? [{ id: "open", label: openLabel, onSelect: open }] : []),
        {
          id: "remove",
          label: t(ATTACHMENT_LABELS.removeAttachment, { name }),
          separatorBefore: Boolean(open),
          onSelect: () => onRemove(attachment.id),
        },
      ]}
    >
      {chip}
    </ContextMenu>
  );
  if (image && source) {
    const img = (
      <img
        alt={name}
        // A drag moves the chip along the strip (stripReorder.ts), never the picture out as a file.
        draggable={false}
        src={thumb?.url ?? source}
        onError={() => setBroken(true)}
        onLoad={(event) => {
          const { naturalWidth: width, naturalHeight: height } = event.currentTarget;
          // An image that decodes to no pixels draws nothing: it failed too.
          if (!width || !height) setBroken(true);
          else if (!thumb) setSize({ width, height });
        }}
      />
    );
    return menu(
      openImage ? () => openImage(source, name) : undefined,
      <div
        className="acpmux-attachment acpmux-attachment-image"
        /* tooltip-allow: an image thumbnail shows no name */ title={name}
      >
        {openImage ? (
          <button
            type="button"
            className="acpmux-attachment-open"
            aria-label={t(ATTACHMENT_LABELS.openAttachment, { name })}
            onClick={() => openImage(source, name)}
          >
            {img}
          </button>
        ) : (
          img
        )}
        {remove}
      </div>,
    );
  }
  // An image the engine could not draw says so in its slot, instead of an empty tile or a bare
  // file name; its × still removes it.
  if (isImage)
    return menu(
      undefined,
      <div className="acpmux-attachment acpmux-attachment-image acpmux-attachment-image-failed">
        <ImageIcon size={16} className="acpmux-attachment-failed-icon" />
        <span className="acpmux-attachment-failed-text">{t("image.failed")}</span>
        {remove}
      </div>,
    );
  // A huge paste (pastedText.ts): its first words and line count; a click puts it back in the prompt.
  if (pasted) {
    const text = attachment.text ?? "";
    const lines = pasteLines(text);
    const count = new Intl.NumberFormat(language).format(lines);
    const expand = onExpand ? () => onExpand(attachment.id) : undefined;
    const body = (
      <>
        <span className="acpmux-attachment-pasted-name">{attachment.name || pasteName(text)}</span>
        <span className="acpmux-attachment-pasted-lines">
          {`${name} · ${t(ATTACHMENT_LABELS.pastedLines, { n: lines, count })}`}
        </span>
      </>
    );
    return menu(
      expand,
      <div className="acpmux-attachment acpmux-attachment-pasted">
        {expand ? (
          <button
            type="button"
            className="acpmux-attachment-pasted-open"
            /* tooltip-allow: the chip shows the paste's first words; the tooltip says a click puts it back in the prompt */
            title={t(ATTACHMENT_LABELS.editPasted)}
            onClick={expand}
          >
            {body}
          </button>
        ) : (
          <span className="acpmux-attachment-pasted-open">{body}</span>
        )}
        {remove}
      </div>,
      t(ATTACHMENT_LABELS.editPasted),
    );
  }
  if (attachment.kind === "document" && attachment.data) {
    return menu(
      undefined,
      <PdfAttachmentChip
        attachment={{ ...attachment, kind: "document", data: attachment.data }}
        remove={remove}
        codex={codex}
      />,
    );
  }
  // A video goes as its path too, with its poster and length once the host read them; a click plays it.
  if (isVideoAttachment(attachment) && (attachment.video || videoReading)) {
    const play = () => void callChipHost("video.quickLook", { src: attachment.path });
    return menu(
      attachment.video ? play : undefined,
      <VideoAttachmentTile name={attachment.name} video={attachment.video} remove={remove} onPlay={play} />,
      t("media.play"),
    );
  }
  return menu(
    undefined,
    <div
      className="acpmux-attachment acpmux-attachment-file acpmux-attachment-link"
      data-saved={attachment.saved || undefined}
      /* tooltip-allow: the full path is secondary detail for the file chip */
      title={attachment.path}
    >
      <FileAttachment
        file={{
          ...attachment,
          // Native path-only choices have no byte count; do not invent a zero-byte file.
          size: attachment.mimeType || attachment.size > 0 ? attachment.size : undefined,
        }}
        remove={remove}
      />
    </div>,
  );
}

function PdfAttachmentChip({
  attachment,
  remove,
  codex,
}: {
  attachment: ComposerAttachment & { kind: "document"; data: string };
  remove: React.ReactNode;
  codex: boolean;
}) {
  const t = useT();
  const [pdfOpen, setPdfOpen] = useState(false);
  const close = useRef<HTMLButtonElement>(null);
  // `frame-src` intentionally excludes data/blob URLs. Keep the inline preview deterministic and
  // open the original bytes in a native browser tab from the modal instead of weakening CSP.
  const [pdfUrl, setPdfUrl] = useState<string>();
  useEffect(() => {
    if (!pdfOpen) {
      setPdfUrl(undefined);
      return;
    }
    try {
      const bytes = Uint8Array.from(atob(attachment.data), (char) => char.charCodeAt(0));
      const url = URL.createObjectURL(new Blob([bytes], { type: "application/pdf" }));
      setPdfUrl(url);
      return () => URL.revokeObjectURL(url);
    } catch {
      setPdfUrl(undefined);
      return;
    }
  }, [attachment.data, pdfOpen]);
  const pageLabel = attachment.pageCount === undefined ? "PDF" : `${attachment.pageCount}p`;
  const deliveryLabel = codex ? `${pageLabel} · ${t(ATTACHMENT_LABELS.sentAsFileForCodex)}` : pageLabel;
  return (
    <>
      <div className="acpmux-attachment acpmux-attachment-document" data-page-count={attachment.pageCount ?? undefined}>
        <button
          type="button"
          className="acpmux-attachment-document-open"
          aria-label={t(ATTACHMENT_LABELS.openAttachment, { name: attachment.name })}
          onClick={() => setPdfOpen(true)}
        >
          <PdfSheetPreview />
        </button>
        <span className="acpmux-attachment-document-meta">
          <FileDoc size={15} />
          <span className="acpmux-attachment-document-name">{attachment.name}</span>
          <span className="acpmux-attachment-document-pages">{deliveryLabel}</span>
        </span>
        {remove}
      </div>
      <Dialog
        open={pdfOpen}
        onOpenChange={setPdfOpen}
        label={t(ATTACHMENT_LABELS.openAttachment, { name: attachment.name })}
        className="ui-glass ui-glass-floats acpmux-pdf-viewer"
        initialFocus={close}
      >
        <div className="acpmux-pdf-viewer-bar">
          <span className="acpmux-image-viewer-title">{attachment.name}</span>
          <span className="acpmux-image-viewer-count">{deliveryLabel}</span>
          <button
            type="button"
            className="acpmux-image-viewer-action"
            ref={close}
            aria-label={t("image.close")}
            onClick={() => setPdfOpen(false)}
          >
            <Close />
          </button>
        </div>
        <div className="acpmux-pdf-viewer-preview">
          <PdfSheetPreview large />
        </div>
        {pdfUrl && (
          <a
            className="acpmux-pdf-viewer-open"
            href={pdfUrl}
            target="_blank"
            rel="noreferrer"
            aria-label={t(ATTACHMENT_LABELS.openAttachment, { name: attachment.name })}
          >
            <FileDoc size={15} />
            <span>{attachment.name}</span>
          </a>
        )}
      </Dialog>
    </>
  );
}

/** A CSP-safe PDF thumbnail; the original bytes remain available via the modal's open link. */
function PdfSheetPreview({ large = false }: { large?: boolean }) {
  return (
    <span className={`acpmux-pdf-sheet${large ? " is-large" : ""}`} aria-hidden="true">
      <span className="acpmux-pdf-sheet-fold" />
      <span className="acpmux-pdf-sheet-mark">PDF</span>
      <span className="acpmux-pdf-sheet-lines">
        <i />
        <i />
        <i />
        <i />
      </span>
    </span>
  );
}
