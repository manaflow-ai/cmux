// The prompt's attachments, one implementation for every composer (Leo 2026-10-19: "i cant paste in
// pictures in the new tab area but it works in the existing chats"): a chat's composer (Composer.tsx)
// and the New Tab page's field (newtab/NewTabScreen.tsx) take a pasted or dropped image or file the
// same way, show it as the same chip, and send it with the prompt.
import React, { useCallback, useContext, useEffect, useId, useRef, useState } from "react";

import { ContextMenu } from "../../../ui/ContextMenu";
import { Dialog } from "../../../ui/Dialog";
import { inlineCopyParent, thumbnail, type ComposerAttachment } from "../attachments";

import { ImageViewerContext } from "../conversation/imageViewerContext";
import { Close, FileDoc, ImageIcon, PlayTriangle, Retry } from "../conversation/icons";
import { usePaneLanguage, useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { pasteLines, pasteName } from "../conversation/promptCollapse";
import { keptThumb } from "./imagePool";
import { useStripReorder } from "./stripReorder";

import { SourceBadge } from "./SourceBadge";
import { useSourceLabel, withSourceLabel } from "./sourceBadgeModel";
import { FADE_BAND_PX } from "../markdownFieldModel";
import { useScrollEdges } from "../summary/scrollEdges";
import { isVideoAttachment } from "./videoAttachments";
import { chipVideoRatio, videoShapeStyle } from "./videoShape";
import { VideoAttachmentTile } from "./VideoAttachmentTile";
import { useAttachedVideoPlayer } from "./videoAttachmentTileModel";
import { FileAttachment } from "../FileAttachment";
import { PastedTextChip } from "./PastedTextChip";
import { UIPickChip } from "./UIPickChip";
import { isUIPick } from "./uiPickModel";
import { TextAttachmentCard } from "./TextAttachmentCard";
import { pastedSize } from "./textAttachmentCardModel";
import { ATTACHMENT_LABELS, imageShape, type PendingAttachment } from "./attachmentIntakeModel";
import { RemoveGlyph } from "./RemoveGlyph";
import { chipRef } from "../conversation/sendMorph";
import { PasteLoadingMark } from "./pasteLoading";
import { PASTE_LOADING_CLASS, usePasteLoadingLook } from "./pasteLoadingLook";

/// The staged attachments' chips over the prompt, with a refusal's note.
export function AttachmentStrip({
  attachments,
  pending = [],
  error,
  codex = false,
  onRemove,
  onExpand,
  onKeepFile,
  onCancel,
  onRetry,
  onReorder,
  originalFailures,
  selected = false,
}: {
  attachments: readonly ComposerAttachment[];
  /// The prompt's whole draft is selected (Select All): the chips are in it, and show so.
  selected?: boolean;
  /// Why a staged image's original failed to upload, by chip id (useAttachmentIntake): its chip
  /// shows Retry (`onRetry`) while its preview still sends.
  originalFailures?: Readonly<Record<string, string>>;
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
  /// A pasted text chip's Keep as .txt: it goes as a file instead. Unset, the chip has no such button.
  onKeepFile?(id: string): void;
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
      setAnnounced(
        translate(ATTACHMENT_LABELS.moved, {
          name: chip.name,
          position: index + 1,
          count: chips.length,
        }),
      );
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
      data-selected={selected ? "" : undefined}
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
          // Where its chip is when the prompt goes: sent from the latest row, it moves from there
          // to its slot in the message (conversation/sendMorph.ts).
          ref={chipRef(attachment.id)}
          data-dragging={reorder.dragging === attachment.id || undefined}
        >
          <AttachmentChip
            attachment={attachment}
            codex={codex}
            onRemove={onRemove}
            {...(onExpand ? { onExpand } : {})}
            {...(onKeepFile ? { onKeepFile } : {})}
            {...(onRetry && originalFailures?.[attachment.id]
              ? { onRetry, originalFailed: originalFailures[attachment.id] }
              : {})}
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
  const look = usePasteLoadingLook();
  const name = chip.image ? imageLabel(t, { name: chip.name }) : chip.name;
  const remove = onCancel && (
    <button
      type="button"
      className="acpmux-attachment-remove"
      aria-label={t(chip.failed ? ATTACHMENT_LABELS.removeAttachment : ATTACHMENT_LABELS.cancelAttachment, { name })}
      onClick={() => onCancel(chip.id)}
    >
      <RemoveGlyph />
    </button>
  );
  // A video (a screen recording) is the square its poster will fill, like an image's tile; only
  // another file shows its name (Leo, 2026-10-26: "not for screen recordings. ... We know it's a
  // video. ... Just do the square.").
  const square = chip.image || chip.video;
  const kind = square ? "acpmux-attachment-image" : "acpmux-attachment-file";
  const shape = chip.image ? imageShape(chip.size) : chip.video ? videoShapeStyle(chip.videoShape) : undefined;
  const style =
    shape || (chip.preview && square)
      ? { ...shape, ...(chip.preview && square ? { backgroundImage: `url("${chip.preview}")` } : {}) }
      : undefined;
  // One that could not be attached keeps its shape: what it is (its kind's glyph, a file's name),
  // one small retry button where a retry can work (`retryable`), and its ×; why is in its tooltip (Leo, 2026-10-31: "video attachments
  // (big attachments?) still sucks", over a strip of empty tiles with only an underlined Retry).
  if (chip.failed)
    return (
      <div
        className={`acpmux-attachment ${kind} acpmux-attachment-failed`}
        aria-label={name}
        {...(chip.video ? { "data-video-shape": "", style: videoShapeStyle(chip.videoShape) } : {})}
        /* tooltip-allow: the tile shows no reason; the tooltip says why it failed */ title={chip.failed}
      >
        {chip.image ? (
          <ImageIcon size={16} className="acpmux-attachment-failed-icon" />
        ) : chip.video ? (
          <PlayTriangle size={16} className="acpmux-attachment-failed-icon" />
        ) : (
          <>
            <FileDoc size={14} className="acpmux-attachment-failed-icon" />
            <span className="acpmux-attachment-failed-name">{chip.name}</span>
          </>
        )}
        {onRetry && chip.retryable && <RetryButton reason={chip.failed} onRetry={() => onRetry(chip.id)} />}
        {remove}
      </div>
    );
  return (
    <div
      className={`acpmux-attachment ${kind} acpmux-attachment-pending ${PASTE_LOADING_CLASS}`}
      data-paste-look={look}
      aria-busy="true"
      aria-label={name}
      // The image's shape from its header (the slot its thumbnail ends in), and its own picture
      // behind the spinner (a background, not an <img>: the strip's images are its ready chips).
      {...(chip.image && shape ? { "data-sized": "" } : {})}
      {...(chip.video ? { "data-video-shape": "" } : {})}
      {...(chip.sizing ? { "data-sizing": "" } : {})}
      {...(chip.preview && square ? { "data-instant": "" } : {})}
      {...(style ? { style } : {})}
    >
      <PasteLoadingMark
        look={look}
        size={16}
        className="acpmux-attachment-spinner"
        upload={chip.progress === undefined ? undefined : <UploadProgress value={chip.progress} name={name} />}
      />
      {!square && <span>{chip.name}</span>}
      {remove}
    </div>
  );
}

/// A loading image tile's picture, from the file itself (PendingAttachment `preview`): under the
/// tile's spinner, filling it, until the chip it becomes takes its place. One the engine cannot
/// draw (a HEIC in Chromium) just goes, leaving the tile as it was.
export function InstantPreview({ src }: { src: string }) {
  const [broken, setBroken] = useState(false);
  if (broken) return null;
  return (
    <img className="acpmux-attachment-instant" src={src} alt="" draggable={false} onError={() => setBroken(true)} />
  );
}

/// A failed attachment's one retry control: a small round button with the retry glyph, the same in
/// the strip and in the text; its tooltip says why it failed.
export function RetryButton({
  label,
  reason,
  onRetry,
  className = "acpmux-attachment-retry",
}: {
  /// What it does, for assistive technology (its tile is named for the file); "Retry" by default.
  label?: string;
  reason?: string;
  onRetry(): void;
  className?: string;
}) {
  const t = useT();
  return (
    <button
      type="button"
      className={className}
      aria-label={label ?? t(ATTACHMENT_LABELS.retryAttachment)}
      /* tooltip-allow: the button is a glyph; the tooltip says what failed and why */
      title={reason ? `${t(ATTACHMENT_LABELS.retryAttachment)}: ${reason}` : t(ATTACHMENT_LABELS.retryAttachment)}
      onClick={(event) => {
        event.stopPropagation();
        onRetry();
      }}
    >
      <Retry size={12} />
    </button>
  );
}

/// How much of a file streaming to the chat's machine is there: a ring that fills, on its tile. The
/// `<progress>` is for assistive technology only, hidden by the strip's own class: the agent pane
/// does not load the pages' global `.visually-hidden`, so with it the native bar drew beside the
/// ring, a lone progress bar at the composer's top left (Leo, 2026-11-06, a picture sent under load).
export function UploadProgress({ value, name, size = 16 }: { value: number; name: string; size?: number }) {
  const percent = Math.round(value * 100);
  const radius = 6;
  const circumference = 2 * Math.PI * radius;
  return (
    <>
      <progress className="acpmux-attachment-voiceover-only" aria-label={name} max={100} value={percent} />
      <svg className="acpmux-attachment-progress" width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
        <circle className="acpmux-attachment-progress-track" cx="8" cy="8" r={radius} />
        <circle
          className="acpmux-attachment-progress-arc"
          cx="8"
          cy="8"
          r={radius}
          strokeDasharray={circumference}
          strokeDashoffset={circumference * (1 - value)}
          transform="rotate(-90 8 8)"
        />
      </svg>
    </>
  );
}

/// A chip's kept thumbnail; a copy pasted beside its original in the prompt (attachments.ts
/// inlineCopyId) draws the original's.
const keptThumbOf = (id: string) => keptThumb(id) ?? keptThumb(inlineCopyParent(id) ?? id);

/// A staged attachment's chip: the strip draws it, and so does the prompt for one placed in its text
/// (composer/inlineAttachments.tsx), with the same preview, open, play and remove.
export function AttachmentChip({
  attachment,
  codex = false,
  onRemove,
  onExpand,
  onKeepFile,
  onRetry,
  originalFailed,
}: {
  attachment: ComposerAttachment;
  codex?: boolean;
  onRemove(id: string): void;
  onExpand?(id: string): void;
  /// A pasted chip sent as a .txt file instead (composer/pastedChips.ts `keepAsFile`).
  onKeepFile?(id: string): void;
  /// An image whose original failed to upload (`originalFailed`, why): its Retry uploads it again.
  onRetry?(id: string): void;
  originalFailed?: string;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const openImage = useContext(ImageViewerContext);
  const [broken, setBroken] = useState(false);
  const [thumb, setThumb] = useState<{ url: string; width: number; height: number } | undefined>(() =>
    keptThumbOf(attachment.id),
  );
  /// The image's natural size, from its thumbnail or from the image itself once it loads.
  const [size, setSize] = useState<{ width: number; height: number }>();
  const videoPlayer = useAttachedVideoPlayer(attachment.path, attachment.name);
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
    if (!image || !attachment.data || keptThumbOf(attachment.id)) return;
    let live = true;
    void thumbnail({ mimeType: attachment.mimeType, data: attachment.data }).then((made) => {
      if (live) setThumb(made);
    });
    return () => {
      live = false;
    };
  }, [attachment.data, attachment.id, attachment.mimeType, image]);
  // The app it came from, at the tile's top-right corner (composer/SourceBadge.tsx); the × takes
  // that corner while the pointer is on the tile, and the tooltip names the source.
  const from = useSourceLabel(attachment.source);
  const removeButton = (
    <button
      type="button"
      className="acpmux-attachment-remove"
      aria-label={t(ATTACHMENT_LABELS.removeAttachment, { name })}
      onClick={() => onRemove(attachment.id)}
    >
      <RemoveGlyph />
    </button>
  );
  const remove = (
    <>
      <SourceBadge source={attachment.source} />
      {removeButton}
    </>
  );
  // Its right-click menu: Open (or what a click does) where a click opens it, and Remove (cx-2lm4).
  const menu = (
    open: (() => void) | undefined,
    chip: React.ReactNode,
    openLabel = t("image.open"),
    keep?: () => void,
  ) => (
    <ContextMenu
      className="acpmux-attachment-menu"
      items={[
        ...(open ? [{ id: "open", label: openLabel, onSelect: open }] : []),
        ...(keep ? [{ id: "keep", label: t(ATTACHMENT_LABELS.keepPasted), onSelect: keep }] : []),
        {
          id: "remove",
          label: t(ATTACHMENT_LABELS.removeAttachment, { name }),
          separatorBefore: Boolean(open || keep),
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
        // Its thumbnail's shape before it decodes, so the chip is its final width from its first frame.
        style={imageShape(thumb)}
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
        /* tooltip-allow: an image thumbnail shows no name */ title={withSourceLabel(name, from)}
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
        {originalFailed && onRetry && (
          <RetryButton
            className="acpmux-attachment-original-retry"
            label={t(ATTACHMENT_LABELS.retryOriginal, { name })}
            reason={t(ATTACHMENT_LABELS.originalFailed, { name, reason: originalFailed })}
            onRetry={() => onRetry(attachment.id)}
          />
        )}
        {remove}
      </div>,
    );
  }
  // An image the engine could not draw says so in its slot, instead of an empty tile or a bare
  // file name; its × still removes it.
  if (isImage) return menu(undefined, <BrokenImageChip remove={remove} onRetry={() => setBroken(false)} />);
  // A huge paste (pastedText.ts): a compact chip that opens its whole text, Edit in Prompt and Keep
  // as .txt in the opened view (PastedTextChip.tsx). Its menu keeps both too.
  if (pasted) {
    const text = attachment.text ?? "";
    const expand = onExpand ? () => onExpand(attachment.id) : undefined;
    const keep = onKeepFile ? () => onKeepFile(attachment.id) : undefined;
    const label = `${name} · ${pastedSize(t, language, text)}`;
    return menu(
      expand,
      <PastedTextChip
        host="strip"
        text={text}
        name={name}
        accessibleName={`${attachment.name || pasteName(text)}, ${label}`}
        remove={remove}
        {...(expand ? { onEdit: expand } : {})}
        {...(keep ? { onKeep: keep } : {})}
      />,
      t(ATTACHMENT_LABELS.editPasted),
      keep,
    );
  }
  // An inspector pick (uiPickModel.ts): the element and a snippet of its text, opening its whole
  // report in place (UIPickChip.tsx).
  if (attachment.kind === "text" && attachment.text !== undefined && isUIPick(attachment))
    return menu(undefined, <UIPickChip host="strip" name={attachment.name} text={attachment.text} remove={remove} />);
  // A text file (attachments.ts readAttachment) or a picked selection: the same page of its first
  // lines, under its name and line count.
  if (attachment.kind === "text" && attachment.text !== undefined) {
    const lines = pasteLines(attachment.text);
    const label = `${attachment.name} · ${t(ATTACHMENT_LABELS.pastedLines, { n: lines, count: new Intl.NumberFormat(language).format(lines) })}`;
    return menu(
      undefined,
      <div
        className="acpmux-attachment acpmux-attachment-pasted acpmux-text-card"
        data-text-kind="file"
        /* tooltip-allow: the card cuts a long name; the tooltip has it whole */
        title={attachment.path ?? attachment.name}
      >
        <span className="acpmux-attachment-pasted-open">
          <TextAttachmentCard text={attachment.text} label={label} />
        </span>
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
  // A video goes as its path too, with its poster and length once the host read them; a click plays it
  // in the pane, streamed from its path (VideoAttachmentTile.tsx useAttachedVideoPlayer); in a chat on
  // another machine, from its upload there. One the host could not read (or never asked: a chat on
  // another machine) keeps the square with its play glyph and no poster; Quick Look plays it from its
  // path when the pane may not, and one nothing can play says so on its tile.
  if (isVideoAttachment(attachment)) {
    const play = videoPlayer.play;
    return (
      <>
        {menu(
          play,
          <VideoAttachmentTile
            name={attachment.name}
            title={withSourceLabel(attachment.name, from)}
            video={attachment.video}
            shape={chipVideoRatio(attachment)}
            remove={remove}
            onPlay={play}
            unplayable={videoPlayer.unplayable}
          />,
          t("media.play"),
        )}
        {videoPlayer.viewer}
      </>
    );
  }
  return menu(
    undefined,
    <div
      className="acpmux-attachment acpmux-attachment-file acpmux-attachment-link"
      data-saved={attachment.saved || undefined}
      /* tooltip-allow: the full path is secondary detail for the file chip */
      title={withSourceLabel(attachment.path, from)}
    >
      <FileAttachment
        file={{
          ...attachment,
          // Native path-only choices have no byte count; do not invent a zero-byte file.
          size: attachment.mimeType || attachment.size > 0 ? attachment.size : undefined,
        }}
        remove={removeButton}
      />
    </div>,
  );
}

/// An image the engine could not draw: it says so in its slot, instead of an empty tile or a bare file
/// name. Retry draws it again; its × still removes it. The strip's chip and the prompt's
/// (composer/inlineAttachments.tsx) both draw this one.
export function BrokenImageChip({ remove, onRetry }: { remove: React.ReactNode; onRetry(): void }) {
  const t = useT();
  return (
    <div className="acpmux-attachment acpmux-attachment-image acpmux-attachment-image-failed">
      <ImageIcon size={16} className="acpmux-attachment-failed-icon" />
      <span className="acpmux-attachment-failed-text">{t("image.failed")}</span>
      <RetryButton onRetry={onRetry} />
      {remove}
    </div>
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
          <FileDoc size={16} />
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
            <FileDoc size={16} />
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
