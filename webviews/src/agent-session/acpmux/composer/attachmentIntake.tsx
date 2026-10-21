// The prompt's attachments, one implementation for every composer (Leo 2026-10-19: "i cant paste in
// pictures in the new tab area but it works in the existing chats"): a chat's composer (Composer.tsx)
// and the New Tab page's field (newtab/NewTabScreen.tsx) take a pasted or dropped image or file the
// same way, show it as the same chip, and send it with the prompt.
import React, { useContext, useEffect, useRef, useState } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import { Dialog } from "../../../ui/Dialog";
import {
  filesFrom,
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
import { type StringKey, type Translate, useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { intakeFiles } from "./intakeFiles";

const ATTACHMENT_LABELS = {
  attachments: "composer.attachments",
  removeAttachment: "composer.removeAttachment",
  openAttachment: "composer.openAttachment",
  dropFiles: "composer.dropFiles",
  sentAsFileForCodex: "composer.sentAsFileForCodex",
  sentAsPath: "composer.sentAsPath",
  tooLarge: "composer.tooLarge",
  unsupported: "composer.unsupported",
  imagesUnsupported: "composer.imagesUnsupported",
  tooMany: "composer.tooMany",
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
};

/// The prompt's staged attachments: what a paste on the composer's field or a file drop anywhere on
/// the page adds (the document-level drop contract, attachments.ts), with the note a refusal leaves.
/// `attach(files, uploads, kind)` adds files another way (the + menu's chooser, which uploads like a
/// drop, or a capture).
export function useAttachmentIntake(options: AttachmentIntakeOptions) {
  const t = useT();
  const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
  const [attachError, setAttachError] = useState<string | undefined>();
  const [dropping, setDropping] = useState(false);
  const live = useRef({ options, t, held: attachments.length });
  live.current = { options, t, held: attachments.length };
  /// `uploads`: the person dropped, pasted or chose these, so the chat's host may save what the
  /// composer can't attach (a moved chat's machine, or this Mac for a local chat) and its chip sends
  /// the saved path (composer/intakeFiles.ts); never a capture. `kind`: the person's own drop or
  /// paste, whose files the host of a chat on this Mac knows the paths of (`localPaths`).
  const [attach] = useState(() => async (files: File[], uploads = false, kind?: DroppedKind) => {
    if (files.length === 0) return;
    const { options: current, t: translate, held } = live.current;
    const paths = current.localPaths;
    const taken = await intakeFiles(files, {
      held,
      allowImages: current.allowImages,
      ...(kind && paths ? { localPaths: (batch: File[]) => paths(kind, batch) } : {}),
      ...(uploads && current.upload ? { upload: current.upload } : {}),
    });
    setAttachments((staged) => [...staged, ...taken.attachments]);
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
    const removeFileDropLifecycle = installFileDropLifecycle((files) => void attach(files, true, "drop"), setDropping);
    document.addEventListener("paste", paste);
    return () => {
      removeFileDropLifecycle();
      document.removeEventListener("paste", paste);
    };
  }, [attach]);
  return { attachments, setAttachments, attachError, setAttachError, dropping, attach };
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

/// The staged attachments' chips over the prompt, with the drop hint or a refusal's note.
export function AttachmentStrip({
  attachments,
  error,
  dropping,
  codex = false,
  onRemove,
}: {
  attachments: readonly ComposerAttachment[];
  error?: string;
  dropping: boolean;
  codex?: boolean;
  onRemove(id: string): void;
}) {
  const t = useT();
  if (attachments.length === 0 && !error && !dropping) return null;
  return (
    <fieldset className="acpmux-attachments" aria-label={t(ATTACHMENT_LABELS.attachments)}>
      {attachments.map((attachment) => (
        <AttachmentChip key={attachment.id} attachment={attachment} codex={codex} onRemove={onRemove} />
      ))}
      {dropping ? (
        <span className="acpmux-attachment-note">{t(ATTACHMENT_LABELS.dropFiles)}</span>
      ) : (
        error && <output className="acpmux-attachment-note">{error}</output>
      )}
    </fieldset>
  );
}

function AttachmentChip({
  attachment,
  codex = false,
  onRemove,
}: {
  attachment: ComposerAttachment;
  codex?: boolean;
  onRemove(id: string): void;
}) {
  const t = useT();
  const openImage = useContext(ImageViewerContext);
  const [broken, setBroken] = useState(false);
  const [thumb, setThumb] = useState<{ url: string; width: number; height: number }>();
  /// The image's natural size, from its thumbnail or from the image itself once it loads.
  const [size, setSize] = useState<{ width: number; height: number }>();
  const isImage = attachment.kind === "image" && Boolean(attachment.data);
  const image = isImage && !broken;
  const source = image ? `data:${attachment.mimeType};base64,${attachment.data}` : undefined;
  // A pasted image's name is WebKit's "image.png": show what it is instead (imageLabel.ts).
  const name = isImage ? imageLabel(t, { name: attachment.name, ...(thumb ?? size) }) : attachment.name;
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
  // Its right-click menu: Open where a click opens it, and Remove (cx-2lm4).
  const menu = (open: (() => void) | undefined, chip: React.ReactNode) => (
    <ContextMenu
      className="acpmux-attachment-menu"
      items={[
        ...(open ? [{ id: "open", label: t("image.open"), onSelect: open }] : []),
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
