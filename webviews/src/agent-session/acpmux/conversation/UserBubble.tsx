// A prompt's bubble, with its action row under its right edge as Claude Code desktop draws one:
// the prompt's age ("8 minutes ago", its date and time on hover), its read receipt (one check once
// acpmux has it, two once the agent read it, "Read by Claude Code" on hover), then Copy, Edit, Retry,
// Fork from here and Pin (cx-ncc.60, Claude parity; Leo, GUI push 2026-10-20). The row shows on
// hover or keyboard focus only, its height kept, so nothing moves when it appears. Edit opens the
// prompt in place; Send forks the chat through the turn before it and sends the edited text there
// (the App's `edit.send`), Escape or Cancel puts the bubble back. Edit shows only on a prompt the
// chat can fork before (`editableTurns`), so it is never dead. Retry sends the prompt again; it shows
// on the prompt of the last ended turn only (MessageActions.tsx PromptRetry). A prompt
// with versions (an edit made it, or replaced it) shows < n/m > before them, always (branches.ts,
// cx-ncc.61). Fork forks the chat through the prompt's own turn, as its right-click Fork does. The
// images a prompt sent show above its bubble, each opening the image viewer (Leo, 2026-10-13: they
// vanished once sent). A long prompt opens collapsed on its first ten lines with Show more, and a
// pasted block is a chip that opens in place (PromptText.tsx); Copy still copies the whole prompt.
import { useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxRow, PromptImage } from "../model";
import { useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { liftInlineImages, withoutDataUris } from "../inlineImages";
import { DeliveryMark } from "./PromptDelivery";
import { ChevronLeft, ChevronRight, ImageIcon, Pencil } from "./icons";
import { ImageViewerContext } from "./imageViewerContext";
import { PromptText } from "./PromptText";
import { ForkButton, MessageCopy, MessageTime, PinButton, PromptRetry, ReadReceipt } from "./MessageActions";
import { TurnActionsContext } from "./turnActions";

export function UserBubble({ row, text }: { row: AcpmuxRow; text: string }) {
  const t = useT();
  const { edit, branches, fork, forkSeq, forkAny, promptTurns } = useContext(TurnActionsContext);
  const branch = branches?.of.get(row.id);
  const [editing, setEditing] = useState(false);
  const through = edit?.seqs.get(row.id);
  // Fork goes through the prompt's own turn, as its right-click Fork does, so the new chat keeps it.
  const own = promptTurns?.get(row.id);
  const forkThrough = fork && own !== undefined && (forkAny || own === forkSeq) ? own : undefined;
  const resend = row.resend ?? row.text ?? text;
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
      <div className="ui-glass cv-user__bubble selectable">
        <PromptText rowId={row.id} text={text} pasted={row.pasted} show={show} />
        {/* A prompt this pane sent that is still on its way; a steer's mark says it instead. */}
        {row.delivery && !row.steer && <DeliveryMark delivery={row.delivery} />}
      </div>
      {text && !row.failed && !row.queued && (
        <div className={branch ? "cv-user__actions cv-user__actions--versions" : "cv-user__actions"}>
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
          <ReadReceipt row={row} />
          <MessageCopy text={row.text ?? text} />
          {through !== undefined && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("message.edit")}
              title={t("message.edit")}
              onClick={() => setEditing(true)}
            >
              <Pencil size={14} />
            </button>
          )}
          <PromptRetry rowId={row.id} prompt={resend} />
          {forkThrough !== undefined && <ForkButton onFork={() => fork!(forkThrough)} />}
          <PinButton rowId={row.id} />
        </div>
      )}
    </>
  );
}

/// A prompt's images, each opening the image viewer; IncomingMessageCard shows another agent's.
export function SentImages({ images, className }: { images: readonly PromptImage[]; className?: string }) {
  return (
    <div className={className ? `cv-user__images ${className}` : "cv-user__images"}>
      {images.map((image) => (
        <SentImage key={image.id} image={image} />
      ))}
    </div>
  );
}

/// The sent thumbnail's height (conversation.css), and the narrowest and
/// widest it draws as a share of that: a tall phone shot or a wide screenshot is cropped to fill
/// past those bounds rather than drawn as a sliver.
export const SENT_IMAGE_HEIGHT = 120;
const SENT_IMAGE_RATIO = { min: 0.75, max: 1.6 };

/// One sent image, read from acpmux by its id. Its slot holds the thumbnail's height while the image
/// is read (square, then the image's own shape within bounds once it loads), and says
/// "Couldn't load image" when the image cannot be drawn. An image acpmux no longer has shows nothing.
function SentImage({ image }: { image: PromptImage }) {
  const t = useT();
  const { promptImage } = useContext(TurnActionsContext);
  const openImage = useContext(ImageViewerContext);
  const [src, setSrc] = useState<string>();
  const [state, setState] = useState<"loading" | "ready" | "missing" | "failed">(() =>
    promptImage ? "loading" : "missing",
  );
  const [size, setSize] = useState<{ width: number; height: number }>();
  useEffect(() => {
    let live = true;
    setSrc(undefined);
    setSize(undefined);
    if (!promptImage) {
      setState("missing");
      return;
    }
    setState("loading");
    void promptImage(image.id).then(
      (url) => {
        if (!live) return;
        if (url) {
          setSrc(url);
          setState("ready");
        } else setState("missing");
      },
      () => {
        // Attachment reads can fail after a reconnect or session switch. Clear the reserved
        // slot and treat it like a missing attachment; never leave an unhandled rejection or
        // stale thumbnail from the previous image id on screen.
        if (!live) return;
        setSrc(undefined);
        setState("missing");
      },
    );
    return () => {
      live = false;
    };
  }, [promptImage, image.id]);
  if (state === "missing") return null;
  if (state === "failed")
    return (
      <span className="cv-user__image-failed">
        <ImageIcon size={16} />
        <span>{t("image.failed")}</span>
      </span>
    );
  // Keep the thumbnail's row slot while the host reads the attachment. Without this, the
  // sent-image band appears after the transcript row has already been placed and pushes the
  // prompt and everything below it down by a frame.
  if (!src) return <span className="cv-user__image-placeholder" aria-hidden="true" />;
  // A pasted image's name is WebKit's "image.png": name it by its size instead (imageLabel.ts).
  const label = imageLabel(t, { name: image.name, ...size });
  const ratio = size ? Math.min(SENT_IMAGE_RATIO.max, Math.max(SENT_IMAGE_RATIO.min, size.width / size.height)) : 1;
  const thumbnail = (
    <img
      className="cv-user__image cv-enter"
      src={src}
      alt={label}
      decoding="async"
      style={{ width: Math.round(SENT_IMAGE_HEIGHT * ratio) }}
      onError={() => setState("failed")}
      onLoad={(event) => {
        const { naturalWidth: width, naturalHeight: height } = event.currentTarget;
        // An image that decodes to no pixels draws nothing: it failed too.
        if (!width || !height) setState("failed");
        else setSize({ width, height });
      }}
    />
  );
  if (!openImage) return thumbnail;
  return (
    <button
      type="button"
      /* tooltip-allow: an image thumbnail shows no name */ title={label}
      aria-label={label || t("image.view")}
      onClick={() => openImage(src, label)}
    >
      {thumbnail}
    </button>
  );
}

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
