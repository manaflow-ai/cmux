// A prompt's bubble, with its action row under its right edge (Leo's spec, after Claude Code
// desktop's): the prompt's age ("3 days ago"; "Oct 18, 2026, 10:16 PM" above it on
// hover), then Copy, Edit, Retry, Fork from here and Bookmark, each naming itself on hover. The ellipsis
// is gone; its menu remains on right-click. Bookmark toggles the same saved mark as the rail.
// Fork hides where the harness cannot fork there (cx-ncc.60, Claude parity;
// Leo, GUI push 2026-10-20/21). The row shows on hover or keyboard focus only, its height kept, so
// nothing moves when it appears. Edit opens the prompt in place; Send forks the chat through the
// turn before it and sends the edited text there (the App's `edit.send`), Escape or Cancel puts the
// bubble back. Edit shows only on a prompt the chat can fork before (`editableTurns`), so it is
// never dead. Retry sends the prompt again (MessageActions.tsx PromptRetry). A prompt with versions
// (an edit made it, or replaced it) shows < n/m > before them, always (branches.ts, cx-ncc.61).
// Fork forks the chat through the prompt's own turn, as its right-click Fork does. The images a
// prompt sent show above its bubble, each opening the image viewer (Leo, 2026-10-13: they vanished
// once sent). A long prompt opens collapsed on its first twenty lines with Show more, and a pasted
// block is the bubble's own text under that fold (PromptText.tsx); Copy still copies the whole prompt. A video
// it sent is its poster and length among them, playing on a click (SentVideoTile.tsx), frames or not.
// A Cloud chat's prompt whose turn has a machine checkpoint taken before it ran adds Back to before
// this turn after Fork (MessageActions.tsx RewindButton): one click puts the machine back there.
import {
  Fragment,
  memo,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { PresentationContext } from "./presentationContextModel";
import type { AcpmuxRow, PromptContentPart, PromptImage } from "../model";
import { useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { liftInlineImages, withoutDataUris } from "../inlineImages";
import { PendingDelivery, usePendingShown } from "./PromptDelivery";
import { ChevronLeft, ChevronRight, ImageIcon, Pencil, Spinner } from "./icons";
import { ImageViewerContext } from "./imageViewerContext";
import { useStableImage } from "./imageEntries";
import { PromptText } from "./PromptText";
import { InlinePromptContent, PromptFile } from "./InlinePromptContent";
import { readsAsText } from "./inlinePromptContentModel";
import { recordedPromptParts, resendsAttachments } from "../inlinePrompt";
import { inlineBubbleParts, isStripMedia } from "./promptCollapse";
import { attachmentOnly, imageOriginals } from "./bubbleParts";
import { frameTextOf, rowImageNames, withoutFramesNotes, withoutVideoFrames } from "../composer/videoPrompt";
import { useComposerSettings } from "../composerSettings";
import { FileAttachment, type FileAttachmentInfo } from "../FileAttachment";

import { SourceBadge } from "../composer/SourceBadge";
import { useSourceLabel, withSourceLabel } from "../composer/sourceBadgeModel";
import {
  ForkButton,
  MessageCopy,
  MessageFooterRow,
  MessageTime,
  PinButton,
  PromptRetry,
  RewindButton,
} from "./MessageActions";
import { forkWithFeedback, ROW_ICON } from "./messageActionsModel";
import { RetryTargetContext, TurnActionsContext, type QueuedActions } from "./turnActions";
import { NO_RETRY_TARGET, retryPlacement } from "./turns";
import { useTranscriptReadOnly } from "./readOnly";
import { pickedSkillsOf, withSkillDollars, withoutSkillDollars, type SkillCatalog } from "../slashCommands";
import { SkillWordsContext } from "./skillWords";
import { tourBubbleText } from "../repoTour/tourModel";
import { SentVideoTile } from "./SentVideoTile";
import { sentVideoOf, sentVideosOf, type SentVideo } from "./sentVideos";
import { recordedFiles, isImageOriginal, SENT_IMAGE_HEIGHT, sentImageWidth, sentImageSize } from "./userBubbleModel";

/// A waiting steer replaces the hover actions with queue controls until delivery is accepted.
export function UserBubble({
  row: given,
  text: givenText,
  pending,
}: {
  row: AcpmuxRow;
  text: string;
  pending?: (actions: ReactNode, queued: QueuedActions) => ReactNode;
}) {
  // A video's frames and their note went to the agent only; the bubble draws the video's tile. A
  // Codex skill reads `/name` as typed, not `/$name` as sent (slashCommands.ts withoutSkillDollars):
  // in the bubble, its Copy and its editor; Retry sends the prompt as it went.
  // Only a skill of the chat's list reads so (skillWords.ts).
  const skills = useContext(SkillWordsContext);
  const row = useMemo(() => shownSkills(withoutVideoFrames(given), skills), [given, skills]);
  // Read before the frames go: a video's note and first frame are its tile (sentVideos.ts).
  const videos = useMemo(() => sentVideosOf(given), [given]);
  // A repo tour's prompt reads as its first line; the rest is instructions to the agent (repoTour/).
  const text = useMemo(
    () =>
      tourBubbleText(givenText) ??
      withoutSkillDollars(
        withoutFramesNotes(givenText, frameTextOf(rowImageNames(given)), !given.pasted?.length),
        skills,
      ),
    [givenText, given, skills],
  );
  const t = useT();
  const { edit, branches, fork, forkSeq, forkAny, promptTurns, retry: canResend } = useContext(TurnActionsContext);
  // The Messages view draws no reply footer for a turn that ended well (messagesRows.ts), so its
  // prompts keep their own Retry there; the transcript's is the last turn's footer (TurnFooter).
  const messagesView = useContext(PresentationContext) === "messages";
  const retryTarget = useContext(RetryTargetContext);
  const readOnly = useTranscriptReadOnly();
  // In the transcript, this prompt draws the chat's one Retry when turns.ts retryPlacement puts it
  // under the prompt: its turn's footer does not draw it (a turn of tool calls alone, history with no
  // turn result, a turn still running).
  const promptRetry =
    retryTarget?.promptId === row.id &&
    retryPlacement(retryTarget ?? NO_RETRY_TARGET, {
      canRetry: Boolean(canResend),
      readOnly,
      messages: messagesView,
    }) === "prompt";
  const branch = branches?.of.get(row.id);
  const [editing, setEditing] = useState(false);
  // A prompt still on its way says so in its footer's time slot, and only there (PromptDelivery.tsx).
  const pendingShown = usePendingShown(row.delivery);
  const through = edit?.seqs.get(row.id);
  // Fork goes through the prompt's own turn, as its right-click Fork does, so the new chat keeps it.
  const own = promptTurns?.get(row.id);
  const forkThrough = fork && own !== undefined && (forkAny || own === forkSeq) ? own : undefined;
  const resend = given.resend ?? given.text ?? givenText;
  // Only a recorded companion relation or an exact retained original path proves that a
  // file belongs to an image. An unrelated file after an image must remain visible on replay.
  // The ordered bubble below skips them by the same rule.
  const originals = imageOriginals(row);
  const recorded = recordedFiles(row.inlineParts, originals);
  const files = (
    recorded?.length
      ? recorded
      : // A video, with its frames or without, is its tile (sentVideos.ts), left out below.
        row.retryAttachments?.flatMap((file): FileAttachmentInfo[] =>
          file.kind === "link" ? [{ ...file, size: file.mimeType || file.size > 0 ? file.size : undefined }] : [],
        )
  )?.filter((file) => !videos.some((video) => video.name === file.name && video.path === file.path));
  // Every recorded non-text part is an attachment, including documents, audio and pasted blocks
  // that do not become legacy file chips.
  const hasAttachment = Boolean(
    row.images?.length ||
    row.retryAttachments?.length ||
    files?.length ||
    row.inlineParts?.some((part) => part.kind !== "text"),
  );
  // A prompt that went out with an image as `data:` text (before the composer stopped making them)
  // reads each one as its name: a bubble never draws base64 (inlineImages.ts, Leo 2026-10-20).
  // Edit opens it without the images (the field would draw them full size again); Copy copies it as sent.
  const imageName = t("image.viewer");
  const show = useCallback((part: string) => withoutDataUris(part, imageName), [imageName]);
  const orderedParts = useMemo(() => {
    const kept = imageOriginals(row);
    return recordedPromptParts(row)?.filter((part) => !isImageOriginal(part, kept));
  }, [row]);
  // A prompt whose attachments the composer placed draws in its recorded order, each attachment
  // where it was put, the last part included. Placed: the pane marked it so (`placed`, acpmux
  // keeps it; inlinePrompt.ts), or text follows an attachment, which the old shape never has.
  // The old shape (its text, then its pastes, then its attachments), and a prompt with nothing
  // to read beside its attachments, keep the legacy bands above the bubble.
  const placed = orderedParts?.some((part) => part.kind !== "text" && part.placed === true) ?? false;
  // The row's height estimate reads the same rule (promptCollapse.ts `inlineBubbleParts`).
  const hasInterleaved = orderedParts !== undefined && inlineBubbleParts(orderedParts) !== undefined;
  // An attachment-only inline prompt has no text bubble to host its media. Keep its attachments
  // in the same strip as the legacy `images` shape, otherwise the estimator reserves a thumbnail
  // row while the DOM draws nothing and the next virtualized row jumps into that space.
  // The row's estimate reads the same rule (bubbleParts.ts `attachmentOnlyPrompt`).
  const inlineAttachmentOnly = attachmentOnly(orderedParts, text);
  const strip = (useComposerSettings().attachmentView === "strip" && hasInterleaved) || inlineAttachmentOnly;
  // The legacy bands draw a prompt's `images` and files only when its recorded parts do not: an
  // attachment-only row carries both shapes (send and replay record each), and drawing both drew
  // every attachment twice.
  const legacyBands = !hasInterleaved && !inlineAttachmentOnly;
  // An attachment-only row whose recorded parts hold fewer images than its `images` (an image
  // recorded only in the legacy shape beside an inline-recorded file) still draws those images.
  const inlineImages = orderedParts?.filter((part) => part.kind === "image") ?? [];
  const looseImages =
    inlineAttachmentOnly && (row.images?.length ?? 0) > inlineImages.length
      ? row.images!.filter((image) => !inlineImages.some((part) => part.id === image.id))
      : [];
  // A placed prompt's attachments the composer left in the strip (unmarked) stay in the band.
  const banded = (part: PromptContentPart) =>
    isStripMedia(part) && (strip || (hasInterleaved && placed && part.placed !== true));
  const stripMedia = orderedParts?.filter(isStripMedia).filter(banded) ?? [];
  // These are bubbleParts.ts `bubbleParts` in the pane's view, which Find and the row's estimate read.
  const shownParts = orderedParts?.filter((part) => !banded(part));
  const renderImage = useCallback((image: PromptImage) => <SentImage image={image} />, []);
  const renderFile = useCallback(
    (part: Exclude<PromptContentPart, { kind: "text" | "image" }>) => {
      const video = sentVideoOf(part, videos);
      return video ? (
        <span className="cv-user__inline-image">
          <SentVideoTile video={video} width={sentImageWidth(video)} height={SENT_IMAGE_HEIGHT} />
        </span>
      ) : undefined;
    },
    [videos],
  );
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
          // Its skills go as `/$name` again, a skill it named keeping that name where a command
          // shares it, and a skill added in the editor too.
          const sent = withSkillDollars(value, skills, pickedSkillsOf(given.text ?? givenText, skills));
          if (await edit.send(row.id, through, sent)) setEditing(false);
        }}
      />
    );
  }
  // Retry is the last turn's reply footer's (TurnRows.tsx TurnFooter; Leo, 2026-11-04: "Today Retry
  // is on your prompt bubble ... Put it, with the model switch, in the last turn's footer."), so neither
  // the sent row nor a waiting steer's queue row (PendingSteer.tsx) draws one, and the row keeps its
  // buttons when the steer is delivered, except where that footer draws no Retry (`promptRetry`). The
  // Messages view draws no footer for a turn that ended well (messagesRows.ts), so its prompts keep
  // their Retry; not while one is on its way, as a second send would duplicate it.
  // An attachment-only prompt retries only when every attachment can go again: a Retry that sent
  // none of them would send an empty prompt.
  const retryAttachments = resendsAttachments(row);
  const retry =
    (messagesView || promptRetry) && !row.pending && row.delivery?.state !== "sending" ? (
      <PromptRetry rowId={row.id} prompt={resend} hasAttachment={retryAttachments} />
    ) : null;
  const forkButton =
    forkThrough !== undefined ? (
      <ForkButton throughSeq={forkThrough} onFork={() => forkWithFeedback(forkThrough, () => fork!(forkThrough))} />
    ) : null;
  // No text to read draws no bubble: a prompt of images alone is its images (an empty glass
  // bubble under them read as a lost message; Leo 2026-10-21).
  const hasBubble = strip ? shownParts!.some(readsAsText) : hasInterleaved || Boolean(text.trim());
  const showsLegacyImages = legacyBands && (Boolean(row.images?.length) || videos.length > 0);
  const showsLegacyFiles = legacyBands && Boolean(files?.length);
  return (
    <>
      {showsLegacyImages && (
        <SentImages images={row.images ?? []} leading={videos.length > 0 ? <SentVideoTiles videos={videos} /> : null} />
      )}
      {looseImages.length > 0 && <SentImages images={looseImages} />}
      {showsLegacyFiles && (
        <div className="cv-user__files">
          {files!.map((file, index) => (
            <FileAttachment key={index} file={file} />
          ))}
        </div>
      )}
      {stripMedia.length > 0 && (
        <div className="cv-user__files cv-user__inline-strip" data-inline-attachment-strip="true">
          {stripMedia.map((part, index) =>
            part.kind === "image" ? (
              <span key={`${part.id}-${index}`} className="cv-user__inline-image">
                {renderImage(part)}
              </span>
            ) : (
              <Fragment key={`${part.kind}-${part.id ?? part.name}-${index}`}>
                {renderFile(part) ?? <PromptFile part={part} />}
              </Fragment>
            ),
          )}
        </div>
      )}
      <div className="cv-user__body">
        {hasBubble ? (
          <div className="ui-glass cv-user__bubble selectable">
            {hasInterleaved ? (
              <InlinePromptContent
                rowId={row.id}
                parts={shownParts!}
                show={show}
                renderImage={renderImage}
                renderFile={renderFile}
              />
            ) : (
              <PromptText rowId={row.id} text={text} pasted={row.pasted} show={show} />
            )}
          </div>
        ) : null}
        {/* A prompt held while its agent starts keeps the footer too (time and Copy), so nothing
            moves once it goes (Leo, 2026-11-01: "then the stupid ass layout shift"). */}
        {!row.failed && (text || hasAttachment || pending) && (
          <UserFooter
            className={
              (branch ? "cv-user__actions cv-user__actions--versions" : "cv-user__actions") +
              (pendingShown ? " cv-user__actions--pending" : "")
            }
            pending={
              pending &&
              ((actions) =>
                pending(actions, {
                  retry: retry && <PromptRetry rowId={row.id} prompt={resend} hasAttachment={retryAttachments} held />,
                  fork: forkButton,
                }))
            }
          >
            <MessageFooterRow>
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
                    <ChevronLeft size={ROW_ICON} />
                  </button>
                  <span
                    className="cv-user__version-count"
                    aria-label={t("message.versionCount", {
                      index: branch.index + 1,
                      total: branch.sessions.length,
                    })}
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
                    <ChevronRight size={ROW_ICON} />
                  </button>
                </span>
              )}
              {pendingShown && row.delivery ? (
                <PendingDelivery delivery={row.delivery} queued={Boolean(row.steer || row.delivery.queued)} />
              ) : (
                <MessageTime at={row.at} className="cv-user__time" />
              )}
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
              {retry}
              {forkButton}
              <RewindButton rowId={row.id} />
              <PinButton rowId={row.id} bookmark />
            </MessageFooterRow>
          </UserFooter>
        )}
      </div>
    </>
  );
}

/// `row` with its prompt text and placed text parts as the bubble reads them (`withoutSkillDollars`);
/// `row` itself when it names no Codex skill.
function shownSkills(row: AcpmuxRow, skills: SkillCatalog): AcpmuxRow {
  const sent = [row.text, ...(row.inlineParts ?? []).map((part) => (part.kind === "text" ? part.text : ""))];
  if (!sent.some((text) => text?.includes("/$"))) return row;
  return {
    ...row,
    ...(row.text !== undefined && { text: withoutSkillDollars(row.text, skills) }),
    ...(row.inlineParts && {
      inlineParts: row.inlineParts.map((part) =>
        part.kind === "text" ? { ...part, text: withoutSkillDollars(part.text, skills) } : part,
      ),
    }),
  };
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
/// `leading` goes first in the same row: the prompt's videos (SentVideoTile.tsx).
export const SentImages = memo(function SentImages({
  images,
  className,
  leading,
}: {
  images: readonly PromptImage[];
  className?: string;
  leading?: ReactNode;
}) {
  return (
    <div className={className ? `cv-user__images ${className}` : "cv-user__images"}>
      {leading}
      {images.map((image) => (
        <SentImage key={image.id} image={image} />
      ))}
    </div>
  );
});

/// A prompt's videos, each at a sent image's height in its own shape.
export function SentVideoTiles({ videos }: { videos: readonly SentVideo[] }) {
  return videos.map((video) => (
    <SentVideoTile
      key={`${video.name}\n${video.path}`}
      video={video}
      width={sentImageWidth(video)}
      height={SENT_IMAGE_HEIGHT}
    />
  ));
}

/// One sent image, read from acpmux by its id (conversation/imageEntries.ts keeps it, so a
/// re-render or a remount draws the same <img> at once). Its slot holds the thumbnail's own shape
/// from its first frame when its size is known (the pane sent it, it drew before, its header says
/// it), and says "Couldn't load image" when the image cannot be drawn. An image acpmux no longer
/// has shows nothing. It fades in on its first draw only.
export const SentImage = memo(function SentImage({ image }: { image: PromptImage }) {
  const t = useT();
  const { promptImage } = useContext(TurnActionsContext);
  const openImage = useContext(ImageViewerContext);
  // Bytes the row holds (this pane's own send) draw at once; acpmux cannot read a composer id.
  const shown = useStableImage(image.src ? { src: image.src } : { id: image.id, read: promptImage }, image);
  const [failed, setFailed] = useState<string>();
  // The app it came from, at the thumbnail's top-right corner (composer/SourceBadge.tsx).
  const from = useSourceLabel(image.source);
  if (shown.status === "missing") return null;
  const { width, height } = sentImageSize(shown);
  // Its shape, at most `width` wide: in a narrow chat the bubble's width scales it down whole
  // (conversation.css), never past the bubble's edge.
  const shape = { width, aspectRatio: `${width} / ${height}` };
  // The failed slot keeps the image's known shape, so the row does not reflow when it fails.
  if (shown.src !== undefined && failed === shown.src)
    return (
      <span className="cv-user__image-failed" style={shape}>
        <ImageIcon size={16} />
        <span>{t("image.failed")}</span>
      </span>
    );
  // Keep the thumbnail's row slot while the host reads the attachment. Without this, the
  // sent-image band appears after the transcript row has already been placed and pushes the
  // prompt and everything below it down by a frame.
  // The box a send from the latest row lands its chip's copy on (sendMorph.ts): the badge's box when
  // it names its source, else the thumbnail.
  const key = image.source ? undefined : image.id;
  if (shown.src === undefined)
    return (
      <span
        className="cv-user__image-placeholder"
        aria-hidden="true"
        data-send-key={key}
        style={{ ...shape, flexBasis: width }}
      />
    );
  const src = shown.src;
  // A pasted image's name is WebKit's "image.png": name it by its size instead (imageLabel.ts).
  const label = imageLabel(t, { name: image.name, width: shown.width, height: shown.height });
  const thumbnail = (
    <img
      className={shown.fresh ? "cv-user__image cv-enter" : "cv-user__image"}
      data-send-key={key}
      src={src}
      alt={label}
      // Decoded ahead (imageEntries.ts): it paints with the frame that mounts it, no blank frame.
      decoding={shown.decoded ? "sync" : "async"}
      width={shown.width}
      height={shown.height}
      style={shape}
      onError={() => setFailed(src)}
      onLoad={(event) => {
        // An image that decodes to no pixels draws nothing: it failed too.
        if (!event.currentTarget.naturalWidth || !event.currentTarget.naturalHeight) setFailed(src);
        else shown.onLoad(event);
      }}
    />
  );
  const opened = openImage ? (
    <button
      type="button"
      /* The image drags out as a file (conversation/dragOut.ts). */
      draggable
      /* tooltip-allow: an image thumbnail shows no name */ title={withSourceLabel(label, from)}
      aria-label={label || t("image.view")}
      onClick={() => openImage(src, label)}
    >
      {thumbnail}
    </button>
  ) : (
    thumbnail
  );
  if (!image.source) return opened;
  return (
    <span className="cv-user__sourced" data-send-key={image.id}>
      {opened}
      <SourceBadge source={image.source} />
    </span>
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
    <div className="ui-glass cv-user__edit">
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
