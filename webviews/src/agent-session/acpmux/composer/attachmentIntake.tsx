// The prompt's attachments, one implementation for every composer (Leo 2026-10-19: "i cant paste in
// pictures in the new tab area but it works in the existing chats"): a chat's composer (Composer.tsx)
// and the New Tab page's field (newtab/NewTabScreen.tsx) take a pasted or dropped image or file the
// same way, show it as the same chip, and send it with the prompt.
import React, { useContext, useEffect, useLayoutEffect, useRef, useState } from "react";
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
import { Close, FileDoc, ImageIcon } from "../conversation/icons";
import { type StringKey, type Translate, usePaneLanguage, useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { pasteLines, pasteName } from "../conversation/promptCollapse";
import { intakeFiles } from "./intakeFiles";
import { type DropOverlayState, HIDDEN_DROP, landDropOverlay, stepDropOverlay } from "./dropOverlayState";
import { FADE_BAND_PX } from "../MarkdownField";
import { useScrollEdges } from "../summary/scrollEdges";

const ATTACHMENT_LABELS = {
  attachments: "composer.attachments",
  removeAttachment: "composer.removeAttachment",
  openAttachment: "composer.openAttachment",
  sentAsFileForCodex: "composer.sentAsFileForCodex",
  sentAsPath: "composer.sentAsPath",
  tooLarge: "composer.tooLarge",
  unsupported: "composer.unsupported",
  imagesUnsupported: "composer.imagesUnsupported",
  pastedText: "composer.pastedText",
  pastedLines: "transcript.pastedLines",
  editPasted: "composer.pastedText.edit",
} as const satisfies Record<string, StringKey>;

export function attachmentErrorText(error: AttachmentError, t: Translate): string {
  return t(ATTACHMENT_LABELS[error.reason], { name: error.name });
}

export type AttachmentIntakeOptions = {
  /// The agent takes images (`promptCapabilities.image`); false refuses an image with a note.
  allowImages: boolean;
  /// Whether a paste on `target` is this composer's: undefined is not; `uploads` false keeps its
  /// files for the next prompt and uploads nothing (a chat's shell mode).
  pasteTarget(target: Node): { uploads: boolean } | undefined;
  /// The chat's host saves what the composer can't attach (cloudUploads.ts); its chip sends the path.
  upload?(files: File[]): Promise<UploadResult>;
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
/// INTO THE COMPOSER IMMEDIATELY".
export type PendingAttachment = { id: string; name: string; image: boolean; scope?: string };

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
  const [attach] = useState(() => async (files: File[], uploads = false, kind?: DroppedKind) => {
    if (files.length === 0) return;
    const { options: current, t: translate } = live.current;
    const batch = { scope: current.scope };
    // In the paste's or drop's own task, so React draws them before the next frame.
    const shown: PendingAttachment[] = files.map((file) => ({
      id: crypto.randomUUID(),
      name: file.name,
      image: isImageFile(file),
      scope: batch.scope,
    }));
    const ids = new Set(shown.map((chip) => chip.id));
    batches.current.add(batch);
    if (shown.length) setPending((chips) => [...chips, ...shown]);
    const paths = current.localPaths;
    // Their placeholders go in the same render as what they became (or when the read fails).
    const read = () => {
      batches.current.delete(batch);
      if (shown.length) setPending((chips) => chips.filter((chip) => !ids.has(chip.id)));
    };
    let taken: Awaited<ReturnType<typeof intakeFiles>>;
    try {
      taken = await intakeFiles(files, {
        allowImages: current.allowImages,
        ...(kind && paths ? { localPaths: (batch: File[]) => paths(kind, batch) } : {}),
        ...(uploads && current.upload ? { upload: current.upload } : {}),
      });
    } catch (error) {
      read();
      throw error;
    }
    read();
    // The composer moved to another chat meanwhile: the chips are the chat's they were pasted in.
    const now = live.current.options;
    if (batch.scope !== now.scope) {
      if (batch.scope !== undefined && taken.attachments.length) now.elsewhere?.(batch.scope, taken.attachments);
      return;
    }
    setAttachments((staged) => appendAttachments(staged, taken.attachments));
    const error = taken.error;
    setAttachError(error && ("text" in error ? error.text : attachmentErrorText(error, translate)));
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
  /// The landing animation ended: the overlay hides.
  const [dropLanded] = useState(() => () => showDrop(HIDDEN_DROP));
  return {
    attachments,
    setAttachments,
    pending: shown,
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
export function useSendWhenAttached(pending: number, scope?: string): (send: () => void) => boolean {
  const held = useRef<(() => void) | undefined>(undefined);
  const count = useRef(pending);
  count.current = pending;
  useEffect(() => {
    held.current = undefined;
  }, [scope]);
  useEffect(() => {
    const send = held.current;
    if (pending > 0 || !send) return;
    held.current = undefined;
    send();
  }, [pending]);
  const [hold] = useState(() => (send: () => void) => {
    if (count.current === 0) return false;
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
}: {
  attachments: readonly ComposerAttachment[];
  /// Files still being read: a placeholder chip each, after the staged ones (PendingAttachment).
  pending?: readonly PendingAttachment[];
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
  // The drop overlay says what a drag does (composer/DropOverlay.tsx); a note here would grow the
  // composer mid-drag.
  if (attachments.length === 0 && pending.length === 0 && !error) return null;
  return (
    <fieldset
      ref={edges}
      className="acpmux-attachments"
      aria-label={t(ATTACHMENT_LABELS.attachments)}
      style={{ "--acpmux-md-fade-band": `${FADE_BAND_PX}px` } as React.CSSProperties}
    >
      {attachments.map((attachment) => (
        <AttachmentChip
          key={attachment.id}
          attachment={attachment}
          codex={codex}
          onRemove={onRemove}
          {...(onExpand ? { onExpand } : {})}
        />
      ))}
      {pending.map((chip) => (
        <PendingChip key={chip.id} chip={chip} />
      ))}
      {error && <output className="acpmux-attachment-note">{error}</output>}
    </fieldset>
  );
}

/// A file still being read: an image's tile in the shape of an image chip, or a file's chip with its
/// name, marked busy. No ×: it is a chip (or a refusal's note) in a moment.
function PendingChip({ chip }: { chip: PendingAttachment }) {
  const t = useT();
  if (chip.image)
    return (
      <div
        className="acpmux-attachment acpmux-attachment-image acpmux-attachment-pending"
        aria-busy="true"
        aria-label={imageLabel(t, { name: chip.name })}
      >
        <ImageIcon size={16} className="acpmux-attachment-failed-icon" />
      </div>
    );
  return (
    <div className="acpmux-attachment acpmux-attachment-file acpmux-attachment-pending" aria-busy="true">
      <span>{chip.name}</span>
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
  const [thumb, setThumb] = useState<{ url: string; width: number; height: number }>();
  /// The image's natural size, from its thumbnail or from the image itself once it loads.
  const [size, setSize] = useState<{ width: number; height: number }>();
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
    if (!image || !attachment.data) return;
    let live = true;
    void thumbnail({ mimeType: attachment.mimeType, data: attachment.data }).then((made) => {
      if (live) setThumb(made);
    });
    return () => {
      live = false;
    };
  }, [attachment.data, attachment.mimeType, image]);
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
  // A file that goes as its path (a saved copy, or a file or folder the panel chose) says so, with
  // the path on hover: the agent reads it there instead of getting its bytes.
  if (attachment.kind === "link")
    return menu(
      undefined,
      <div
        className="acpmux-attachment acpmux-attachment-file acpmux-attachment-link"
        data-saved={attachment.saved || undefined}
        /* tooltip-allow: the chip shows a file's name; its path is where the agent reads it */ title={attachment.path}
      >
        <span className="acpmux-attachment-link-name">{attachment.name}</span>
        {attachment.saved && <span className="acpmux-attachment-link-note">{t(ATTACHMENT_LABELS.sentAsPath)}</span>}
        {remove}
      </div>,
    );
  return menu(
    undefined,
    <div className="acpmux-attachment acpmux-attachment-file">
      <span>{attachment.name}</span>
      {remove}
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
        className="acpmux-pdf-viewer"
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
