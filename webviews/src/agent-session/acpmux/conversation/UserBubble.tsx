// A prompt's bubble, with its action row under its right edge (Leo's spec, after Claude Code
// desktop's): the prompt's age ("3 days ago"; "Oct 18, 2026, 10:16 PM" above it on
// hover), then Copy, Edit, Retry and Fork from here, each naming itself on hover. The ellipsis
// is gone; its menu remains on right-click. No Pin here: an
// answer's row has it. Fork hides where the harness cannot fork there (cx-ncc.60, Claude parity;
// Leo, GUI push 2026-10-20/21). The row shows on hover or keyboard focus only, its height kept, so
// nothing moves when it appears. Edit opens the prompt in place; Send forks the chat through the
// turn before it and sends the edited text there (the App's `edit.send`), Escape or Cancel puts the
// bubble back. Edit shows only on a prompt the chat can fork before (`editableTurns`), so it is
// never dead. Retry sends the prompt again (MessageActions.tsx PromptRetry). A prompt with versions
// (an edit made it, or replaced it) shows < n/m > before them, always (branches.ts, cx-ncc.61).
// Fork forks the chat through the prompt's own turn, as its right-click Fork does. The images a
// prompt sent show above its bubble, each opening the image viewer (Leo, 2026-10-13: they vanished
// once sent). A long prompt opens collapsed on its first ten lines with Show more, and a pasted
// block is a chip that opens in place (PromptText.tsx); Copy still copies the whole prompt.
import { memo, useCallback, useContext, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { AcpmuxRow, PromptImage } from "../model";
import { useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { liftInlineImages, withoutDataUris } from "../inlineImages";
import { DeliveryMark } from "./PromptDelivery";
import { ChevronLeft, ChevronRight, ImageIcon, Pencil, Spinner } from "./icons";
import { ImageViewerContext } from "./imageViewerContext";
import { useStableImage } from "./imageEntries";
import { PromptText } from "./PromptText";
import { attachmentPath, FileAttachment, type FileAttachmentInfo } from "../FileAttachment";
import { ForkButton, forkWithFeedback, MessageCopy, MessageTime, PromptRetry, ROW_ICON } from "./MessageActions";
import { TurnActionsContext } from "./turnActions";

/// A waiting steer replaces the hover actions with queue controls until delivery is accepted.
export function UserBubble({
  row,
  text,
  pending,
}: {
  row: AcpmuxRow;
  text: string;
  pending?: (actions: ReactNode) => ReactNode;
}) {
  const t = useT();
  const { edit, branches, fork, forkSeq, forkAny, promptTurns } = useContext(TurnActionsContext);
  const branch = branches?.of.get(row.id);
  const [editing, setEditing] = useState(false);
  const through = edit?.seqs.get(row.id);
  // Fork goes through the prompt's own turn, as its right-click Fork does, so the new chat keeps it.
  const own = promptTurns?.get(row.id);
  const forkThrough = fork && own !== undefined && (forkAny || own === forkSeq) ? own : undefined;
  const resend = row.resend ?? row.text ?? text;
  // Only a recorded companion relation or an exact retained original path proves that a
  // file belongs to an image. An unrelated file after an image must remain visible on replay.
  const originals = new Set(
    row.retryAttachments?.flatMap((file) => (file.kind === "image" && file.originalPath ? [file.originalPath] : [])),
  );
  const recorded = row.inlineParts?.flatMap((part): FileAttachmentInfo[] =>
    part.kind === "file" &&
    part.companionOf === undefined &&
    !part.mimeType?.startsWith("video/") &&
    !originals.has(attachmentPath(part.uri) ?? "")
      ? [{ ...part, path: attachmentPath(part.uri) }]
      : [],
  );
  const files = recorded?.length
    ? recorded
    : row.retryAttachments?.flatMap((file): FileAttachmentInfo[] =>
        file.kind === "link" && !file.mimeType.startsWith("video/")
          ? [{ ...file, size: file.mimeType || file.size > 0 ? file.size : undefined }]
          : [],
      );
  // A prompt that went out with an image as `data:` text (before the composer stopped making them)
  // reads each one as its name: a bubble never draws base64 (inlineImages.ts, Leo 2026-10-20).
  // Edit opens it without the images (the field would draw them full size again); Copy copies it as sent.
  const imageName = t("image.viewer");
  const show = useCallback((part: string) => withoutDataUris(part, imageName), [imageName]);
  const editable = useMemo(() => (editing ? liftInlineImages(row.text ?? text).text : ""), [editing, row.text, text]);
  // An open editor stays while the chat changes under it (a reconnect, a turn starting), so the
  // draft is kept; Send waits until the prompt can be forked before again. A resend that fails
  // (the fork refused, the reader opened another chat) leaves the draft open too.
  if (editing) {
    return (
      <PromptEditor
        initial={editable}
        canSend={edit !== undefined && through !== undefined}
        onCancel={() => setEditing(false)}
        onSend={async (value) => {
          if (!edit || through === undefined) return;
          if (await edit.send(row.id, through, value)) setEditing(false);
        }}
      />
    );
  }
  return (
    <>
      {row.images && row.images.length > 0 && <SentImages images={row.images} />}
      {Boolean(files?.length) && (
        <div className="cv-user__files">
          {files!.map((file, index) => (
            <FileAttachment key={index} file={file} />
          ))}
        </div>
      )}
      {/* No text to read draws no bubble: a prompt of images alone is its images (an empty glass
          bubble under them read as a lost message; Leo 2026-10-21). */}
      {text.trim() && (
        <div className="ui-glass cv-user__bubble selectable">
          <PromptText rowId={row.id} text={text} pasted={row.pasted} show={show} />
          {/* A prompt this pane sent that is still on its way; a steer's mark says it instead. */}
          {row.delivery && !row.steer && <DeliveryMark delivery={row.delivery} />}
        </div>
      )}
      {!row.failed && !row.queued && (text || pending) && (
        <UserFooter
          className={branch ? "cv-user__actions cv-user__actions--versions" : "cv-user__actions"}
          pending={pending}
        >
          {branch && branches && (
            <span className="cv-user__versions">
              <button
                type="button"
                className="cv-iconbtn cv-iconbtn--compact"
                aria-label={t("message.previousVersion")}
                title={t("message.previousVersion")}
                disabled={branch.index === 0}
                onClick={() => branches.open(branch.sessions[branch.index - 1]!)}
              >
                <ChevronLeft size={12} />
              </button>
              <span
                className="cv-user__version-count"
                aria-label={t("message.versionCount", { index: branch.index + 1, total: branch.sessions.length })}
              >
                {branches.running?.has(branch.sessions[branch.index] ?? "") && <Spinner size={12} loading />}
                {branch.index + 1}/{branch.sessions.length}
              </span>
              <button
                type="button"
                className="cv-iconbtn cv-iconbtn--compact"
                aria-label={t("message.nextVersion")}
                title={t("message.nextVersion")}
                disabled={branch.index === branch.sessions.length - 1}
                onClick={() => branches.open(branch.sessions[branch.index + 1]!)}
              >
                <ChevronRight size={12} />
              </button>
            </span>
          )}
          <MessageTime at={row.at} className="cv-user__time" />
          <MessageCopy text={row.text ?? text} />
          {through !== undefined && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("message.edit")}
              title={t("message.edit")}
              onClick={() => setEditing(true)}
            >
              <Pencil size={ROW_ICON} />
            </button>
          )}
          {/* Not while it is still on its way: a second send would duplicate it. */}
          {!row.pending && row.delivery?.state !== "sending" && <PromptRetry rowId={row.id} prompt={resend} />}
          {forkThrough !== undefined && (
            <ForkButton onFork={() => forkWithFeedback(forkThrough, () => fork!(forkThrough))} />
          )}
        </UserFooter>
      )}
    </>
  );
}

function UserFooter({
  className,
  pending,
  children,
}: {
  className: string;
  pending?: (actions: ReactNode) => ReactNode;
  children: ReactNode;
}) {
  return <div className={className}>{pending ? pending(children) : children}</div>;
}

/// A prompt's images, each opening the image viewer; IncomingMessageCard shows another agent's.
export const SentImages = memo(function SentImages({
  images,
  className,
}: {
  images: readonly PromptImage[];
  className?: string;
}) {
  return (
    <div className={className ? `cv-user__images ${className}` : "cv-user__images"}>
      {images.map((image) => (
        <SentImage key={image.id} image={image} />
      ))}
    </div>
  );
});

/// The sent thumbnail's height (conversation.css), and the narrowest and
/// widest it draws as a share of that: a tall phone shot or a wide screenshot is cropped to fill
/// past those bounds rather than drawn as a sliver.
export const SENT_IMAGE_HEIGHT = 120;
const SENT_IMAGE_RATIO = { min: 0.75, max: 1.6 };

/// A thumbnail's width at SENT_IMAGE_HEIGHT for an image of `size`: square only while no size is known.
export function sentImageWidth(size: { width?: number; height?: number }): number {
  const ratio =
    size.width && size.height
      ? Math.min(SENT_IMAGE_RATIO.max, Math.max(SENT_IMAGE_RATIO.min, size.width / size.height))
      : 1;
  return Math.round(SENT_IMAGE_HEIGHT * ratio);
}

/// One sent image, read from acpmux by its id (conversation/imageEntries.ts keeps it, so a
/// re-render or a remount draws the same <img> at once). Its slot holds the thumbnail's own shape
/// from its first frame when its size is known (the pane sent it, it drew before, its header says
/// it), and says "Couldn't load image" when the image cannot be drawn. An image acpmux no longer
/// has shows nothing. It fades in on its first draw only.
const SentImage = memo(function SentImage({ image }: { image: PromptImage }) {
  const t = useT();
  const { promptImage } = useContext(TurnActionsContext);
  const openImage = useContext(ImageViewerContext);
  const shown = useStableImage({ id: image.id, read: promptImage }, image);
  const [failed, setFailed] = useState<string>();
  if (shown.status === "missing") return null;
  const width = sentImageWidth(shown);
  // The failed slot keeps the image's known shape, so the row does not reflow when it fails.
  if (shown.src !== undefined && failed === shown.src)
    return (
      <span className="cv-user__image-failed" style={{ width }}>
        <ImageIcon size={16} />
        <span>{t("image.failed")}</span>
      </span>
    );
  // Keep the thumbnail's row slot while the host reads the attachment. Without this, the
  // sent-image band appears after the transcript row has already been placed and pushes the
  // prompt and everything below it down by a frame.
  if (shown.src === undefined)
    return <span className="cv-user__image-placeholder" aria-hidden="true" style={{ width, flexBasis: width }} />;
  const src = shown.src;
  // A pasted image's name is WebKit's "image.png": name it by its size instead (imageLabel.ts).
  const label = imageLabel(t, { name: image.name, width: shown.width, height: shown.height });
  const thumbnail = (
    <img
      className={shown.fresh ? "cv-user__image cv-enter" : "cv-user__image"}
      src={src}
      alt={label}
      // Decoded ahead (imageEntries.ts): it paints with the frame that mounts it, no blank frame.
      decoding={shown.decoded ? "sync" : "async"}
      width={shown.width}
      height={shown.height}
      style={{ width }}
      onError={() => setFailed(src)}
      onLoad={(event) => {
        // An image that decodes to no pixels draws nothing: it failed too.
        if (!event.currentTarget.naturalWidth || !event.currentTarget.naturalHeight) setFailed(src);
        else shown.onLoad(event);
      }}
    />
  );
  if (!openImage) return thumbnail;
  return (
    <button
      type="button"
      /* The image drags out as a file (conversation/dragOut.ts). */
      draggable
      /* tooltip-allow: an image thumbnail shows no name */ title={label}
      aria-label={label || t("image.view")}
      onClick={() => openImage(src, label)}
    >
      {thumbnail}
    </button>
  );
});

/// A prompt open for typing: Enter sends, Shift-Enter breaks the line, Escape cancels. Edit and
/// resend uses it here; a message card's Reply too (IncomingMessageCard.tsx), under `label`,
/// keeping its draft through `onChange`; one it draws again after scrolling back leaves the focus
/// alone (`autoFocus` false).
export function PromptEditor({
  initial,
  canSend,
  label,
  autoFocus = true,
  onChange,
  onCancel,
  onSend,
}: {
  initial: string;
  canSend: boolean;
  label?: string;
  autoFocus?: boolean;
  onChange?(text: string): void;
  onCancel(): void;
  onSend(text: string): Promise<void>;
}) {
  const t = useT();
  const [value, setValue] = useState(initial);
  const [sending, setSending] = useState(false);
  const field = useRef<HTMLTextAreaElement>(null);
  // Opened to type in: the caret at the end, the field as tall as the prompt.
  useLayoutEffect(() => {
    const element = field.current;
    if (!element || !autoFocus) return;
    element.focus();
    element.setSelectionRange(element.value.length, element.value.length);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- focus once, when it opens
  }, []);
  useLayoutEffect(() => {
    const element = field.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = `${element.scrollHeight}px`;
  }, [value]);
  const ready = canSend && !sending && value.trim() !== "";
  const send = () => {
    if (!ready) return;
    setSending(true);
    void onSend(value).finally(() => setSending(false));
  };
  return (
    <div className="cv-user__edit">
      <textarea
        ref={field}
        className="cv-user__edit-field selectable"
        aria-label={label ?? t("message.editLabel")}
        value={value}
        rows={1}
        onChange={(event) => {
          setValue(event.target.value);
          onChange?.(event.target.value);
        }}
        // ui-allow: the editor's own Enter (send) and Escape (cancel), as the composer's
        onKeyDown={(event) => {
          // WebKit may end an IME composition before its Enter's keydown, which then says only 229.
          if (event.nativeEvent.isComposing || event.keyCode === 229) return;
          if (event.key === "Escape") {
            event.preventDefault();
            onCancel();
          } else if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();
            send();
          }
        }}
      />
      <div className="cv-user__edit-actions">
        <button type="button" className="cv-user__edit-button" onClick={onCancel}>
          {t("message.editCancel")}
        </button>
        <button
          type="button"
          className="cv-user__edit-button cv-user__edit-button--send"
          aria-label={t("message.editSend")}
          disabled={!ready}
          onClick={send}
        >
          {t("message.editSend")}
        </button>
      </div>
    </div>
  );
}
