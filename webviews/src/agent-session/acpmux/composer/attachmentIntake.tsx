// The prompt's attachments, one implementation for every composer (Leo 2026-10-19: "i cant paste in
// pictures in the new tab area but it works in the existing chats"): a chat's composer (Composer.tsx)
// and the New Tab page's field (newtab/NewTabScreen.tsx) take a pasted or dropped image or file the
// same way, show it as the same chip, and send it with the prompt.
import React, { useContext, useEffect, useRef, useState } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import { Dialog } from "../../../ui/Dialog";
import {
  filesFrom,
  installFileDropLifecycle,
  readAttachments,
  thumbnail,
  type AttachmentError,
  type ComposerAttachment,
} from "../attachments";
import type { UploadResult } from "../cloudUploads";
import { ImageViewerContext } from "../conversation/imageViewerContext";
import { Close, FileDoc } from "../conversation/icons";
import { type StringKey, type Translate, useT } from "../i18n";

const ATTACHMENT_LABELS = {
  attachments: "composer.attachments",
  removeAttachment: "composer.removeAttachment",
  openAttachment: "composer.openAttachment",
  dropFiles: "composer.dropFiles",
  sentAsFileForCodex: "composer.sentAsFileForCodex",
  tooLarge: "composer.tooLarge",
  unsupported: "composer.unsupported",
  imagesUnsupported: "composer.imagesUnsupported",
  tooMany: "composer.tooMany",
} as const satisfies Record<string, StringKey>;

/// The refusals a moved chat's upload can take instead (a file of another type, or past the size an attachment takes).
const UPLOADABLE = new Set<AttachmentError["reason"]>(["unsupported", "tooLarge"]);

export function attachmentErrorText(error: AttachmentError, t: Translate): string {
  return t(ATTACHMENT_LABELS[error.reason], { name: error.name });
}

export type AttachmentIntakeOptions = {
  /// The agent takes images (`promptCapabilities.image`); false refuses an image with a note.
  allowImages: boolean;
  /// Whether a paste on `target` is this composer's: undefined is not; `uploads` false keeps its
  /// files for the next prompt and uploads nothing (a chat's shell mode).
  pasteTarget(target: Node): { uploads: boolean } | undefined;
  /// A moved chat sends what the composer can't attach to its machine (cloudUploads.ts).
  upload?(files: File[]): Promise<UploadResult>;
  /// Puts the uploaded files' machine paths in the prompt.
  insertPaths?(paths: string[]): void;
};

/// The prompt's staged attachments: what a paste on the composer's field or a file drop anywhere on
/// the page adds (the document-level drop contract, attachments.ts), with the note a refusal leaves.
/// `attach(files, uploads)` adds files another way (the + menu's chooser, a capture).
export function useAttachmentIntake(options: AttachmentIntakeOptions) {
  const t = useT();
  const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
  const [attachError, setAttachError] = useState<string | undefined>();
  const [dropping, setDropping] = useState(false);
  const live = useRef({ options, t, held: attachments.length });
  live.current = { options, t, held: attachments.length };
  /// `uploads`: the person dropped or pasted these into the prompt, so a moved chat may send what
  /// the composer can't attach to its machine (never a pick from + or a capture).
  const [attach] = useState(() => async (files: File[], uploads = false) => {
    if (files.length === 0) return;
    const { options: current, t: translate, held } = live.current;
    const { upload, insertPaths } = current;
    const read = await readAttachments(files, held, current.allowImages);
    setAttachments((staged) => [...staged, ...read.attachments]);
    // A moved chat sends what the composer can't attach to its machine and names it in the prompt.
    const refused = new Set(read.errors.filter((error) => UPLOADABLE.has(error.reason)).map((error) => error.name));
    const sendable = files.filter((file) => refused.has(file.name || "file"));
    const sent = uploads && upload && sendable.length > 0 ? await upload(sendable) : undefined;
    if (sent && "paths" in sent) insertPaths?.(sent.paths);
    const errors = sent ? read.errors.filter((error) => !refused.has(error.name)) : read.errors;
    setAttachError(
      sent && "error" in sent ? sent.error : errors[0] ? attachmentErrorText(errors[0], translate) : undefined,
    );
  });
  useEffect(() => {
    const paste = (event: ClipboardEvent) => {
      const owned = live.current.options.pasteTarget(event.target as Node);
      if (!owned) return;
      const files = filesFrom(event.clipboardData);
      if (files.length === 0) return;
      event.preventDefault();
      void attach(files, owned.uploads);
    };
    const removeFileDropLifecycle = installFileDropLifecycle((files) => void attach(files, true), setDropping);
    document.addEventListener("paste", paste);
    return () => {
      removeFileDropLifecycle();
      document.removeEventListener("paste", paste);
    };
  }, [attach]);
  return { attachments, setAttachments, attachError, setAttachError, dropping, attach };
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
  const [thumb, setThumb] = useState<string>();
  const image = attachment.kind === "image" && attachment.data && !broken;
  const source = image ? `data:${attachment.mimeType};base64,${attachment.data}` : undefined;
  useEffect(() => {
    if (!image || !attachment.data) return;
    let live = true;
    void thumbnail({ mimeType: attachment.mimeType, data: attachment.data }).then((url) => {
      if (live) setThumb(url);
    });
    return () => {
      live = false;
    };
  }, [attachment.data, attachment.mimeType, image]);
  const remove = (
    <button
      type="button"
      className="acpmux-attachment-remove"
      aria-label={t(ATTACHMENT_LABELS.removeAttachment, { name: attachment.name })}
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
          label: t(ATTACHMENT_LABELS.removeAttachment, { name: attachment.name }),
          separatorBefore: Boolean(open),
          onSelect: () => onRemove(attachment.id),
        },
      ]}
    >
      {chip}
    </ContextMenu>
  );
  if (image && source) {
    const img = <img alt={attachment.name} src={thumb ?? source} onError={() => setBroken(true)} />;
    return menu(
      openImage ? () => openImage(source, attachment.name) : undefined,
      <div
        className="acpmux-attachment acpmux-attachment-image"
        /* tooltip-allow: an image thumbnail shows no name */ title={attachment.name}
      >
        {openImage ? (
          <button
            type="button"
            className="acpmux-attachment-open"
            aria-label={t(ATTACHMENT_LABELS.openAttachment, { name: attachment.name })}
            onClick={() => openImage(source, attachment.name)}
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
            title={t("image.close")}
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
