// A prompt's bubble, with its action row under it as Claude Code desktop draws one: the prompt's age
// ("1 hour ago", its time on hover), two ticks once the agent has it, then Copy, Edit, Fork and
// Bookmark (cx-ncc.60, Claude parity). The latest prompt shows the row always, older ones on hover
// (VirtualTranscript marks the latest `data-last-prompt`). Edit opens the prompt in
// place; Send forks the chat through the turn before it and sends the edited text there (the App's
// `edit.send`), Escape or Cancel puts the bubble back. Edit shows only on a prompt the chat can fork
// before (`editableTurns`), so it is never dead. A prompt with versions (an edit made it, or replaced
// it) shows < n/m > before them, always (branches.ts, cx-ncc.61). Fork forks the chat through the
// prompt's own turn, as its right-click Fork does. The row is Claude's whole
// row (GUI push 2026-10-20), not the `hover-actions` experiment's one action. The images a prompt
// sent show above its bubble, each opening the image viewer (Leo, 2026-10-13: they vanished once sent).
import { useContext, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { AcpmuxRow, PromptImage } from "../model";
import { useMinuteClock } from "../clock";
import { usePaneLanguage, useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { copyText } from "./clipboard";
import { DeliveryMark } from "./PromptDelivery";
import { Check, ChevronLeft, ChevronRight, Copy, ImageIcon, Pencil, TurnFork } from "./icons";
import { relativeTime } from "./relativeTime";
import { ImageViewerContext } from "./imageViewerContext";
import { TurnActionsContext } from "./turnActions";
import { BookmarkIcon } from "../threadMinimap/BookmarkIcon";
import { usePromptRowMark } from "../threadMinimap/promptMarks";

export function UserBubble({ row, text }: { row: AcpmuxRow; text: string }) {
  const t = useT();
  const { edit, branches, fork, forkSeq, forkAny, promptTurns } = useContext(TurnActionsContext);
  const now = useMinuteClock();
  const language = usePaneLanguage();
  const branch = branches?.of.get(row.id);
  const [editing, setEditing] = useState(false);
  const [copied, setCopied] = useState(false);
  const mark = usePromptRowMark(row);
  const through = edit?.seqs.get(row.id);
  // A prompt this pane sent is read once the agent started on it (its delivery), else as before; a
  // steer is unread while it still waits for the agent to take it, whatever its delivery says.
  const unread = row.steer === "waiting" || (row.delivery ? row.delivery.state !== "read" : row.pending);
  // Fork goes through the prompt's own turn, as its right-click Fork does, so the new chat keeps it.
  const own = promptTurns?.get(row.id);
  const forkThrough = fork && own !== undefined && (forkAny || own === forkSeq) ? own : undefined;
  // An open editor stays while the chat changes under it (a reconnect, a turn starting), so the
  // draft is kept; Send waits until the prompt can be forked before again. A resend that fails
  // (the fork refused, the reader opened another chat) leaves the draft open too.
  if (editing) {
    return (
      <PromptEditor
        initial={row.text ?? text}
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
      <div className="cv-user__bubble selectable">
        {text}
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
          <time className="cv-user__time" dateTime={new Date(row.at).toISOString()}>
            {relativeTime(row.at, now, language)}
          </time>
          {/* Claude's single check: Read once the agent has the prompt, Unread while it is still
              being sent or waits as a steer. */}
          <span
            className={`cv-user__read${unread ? " is-unread" : ""}`}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an icon with a spoken state, not an image file.
            role="img"
            aria-label={t(unread ? "message.unread" : "message.read")}
            title={t(unread ? "message.unread" : "message.read")}
          >
            <Check size={14} />
          </span>
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact"
            aria-label={copied ? t("turn.copied") : t("turn.copy")}
            title={copied ? t("turn.copied") : t("turn.copy")}
            onClick={() =>
              void copyText(row.text ?? text).then(
                () => setCopied(true),
                () => setCopied(false),
              )
            }
          >
            <Copy size={14} />
          </button>
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
          {forkThrough !== undefined && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("turn.fork")}
              title={t("turn.fork")}
              onClick={() => fork!(forkThrough)}
            >
              <TurnFork size={14} />
            </button>
          )}
          {/* The prompt's bookmark, the same mark as the thread minimap's dot and card. */}
          {mark.can && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact cv-user__bookmark"
              aria-pressed={mark.marked}
              aria-label={t(mark.marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
              title={t(mark.marked ? "minimap.bookmarkRemove" : "minimap.bookmarkAdd")}
              onClick={mark.toggle}
            >
              <BookmarkIcon filled={mark.marked} size={14} />
            </button>
          )}
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

function PromptEditor({
  initial,
  canSend,
  onCancel,
  onSend,
}: {
  initial: string;
  canSend: boolean;
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
    if (!element) return;
    element.focus();
    element.setSelectionRange(element.value.length, element.value.length);
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
        aria-label={t("message.editLabel")}
        value={value}
        rows={1}
        onChange={(event) => setValue(event.target.value)}
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
