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
// block is a chip that opens in place (PromptText.tsx); Copy still copies the whole prompt. A video
// it sent with its frames is its poster and length among them, playing on a click (SentVideoTile.tsx).
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
import type { AcpmuxRow, PromptContentPart, PromptImage } from "../model";
import { useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { liftInlineImages, withoutDataUris } from "../inlineImages";
import { DeliveryMark } from "./PromptDelivery";
import { ChevronLeft, ChevronRight, ImageIcon, Pencil, Spinner } from "./icons";
import { ImageViewerContext } from "./imageViewerContext";
import { useStableImage } from "./imageEntries";
import { PromptText } from "./PromptText";
import { InlinePromptContent, isStripMedia, PromptFile, readsAsText } from "./InlinePromptContent";
import { recordedPromptParts } from "../inlinePrompt";
import { frameTextOf, rowImageNames, withoutFramesNotes, withoutVideoFrames } from "../composer/videoPrompt";
import { useComposerSettings } from "../composerSettings";
import { attachmentPath, FileAttachment, type FileAttachmentInfo } from "../FileAttachment";
import { SourceBadge, useSourceLabel, withSourceLabel } from "../composer/SourceBadge";
import {
  ForkButton,
  forkWithFeedback,
  MessageCopy,
  MessageFooterRow,
  MessageTime,
  PromptRetry,
  ROW_ICON,
} from "./MessageActions";
import { TurnActionsContext } from "./turnActions";
import { pickedSkillsOf, withSkillDollars, withoutSkillDollars, type SkillCatalog } from "../slashCommands";
import { SkillWordsContext } from "./skillWords";
import { SentVideoTile } from "./SentVideoTile";
import { sentVideoOf, sentVideosOf, type SentVideo } from "./sentVideos";

/// The files a recorded prompt sent (its `inlineParts`: documents, audio, resource links), drawn
/// as a sent prompt draws them; a file that is an image's companion, a video, or an image's
/// original path is drawn by that image instead.
export function recordedFiles(
  parts: AcpmuxRow["inlineParts"],
  originals: ReadonlySet<string> = new Set(),
): FileAttachmentInfo[] | undefined {
  return parts?.flatMap((part): FileAttachmentInfo[] =>
    part.kind === "file" && !isImageOriginal(part, originals) && !part.mimeType?.startsWith("video/")
      ? [{ ...part, path: attachmentPath(part.uri) }]
      : [],
  );
}

/// A waiting steer replaces the hover actions with queue controls until delivery is accepted.
export function UserBubble({
  row: given,
  text: givenText,
  pending,
}: {
  row: AcpmuxRow;
  text: string;
  pending?: (actions: ReactNode) => ReactNode;
}) {
  // A video's frames and their note went to the agent only; the bubble draws the video's tile. A
  // Codex skill reads `/name` as typed, not `/$name` as sent (slashCommands.ts withoutSkillDollars):
  // in the bubble, its Copy and its editor; Retry sends the prompt as it went.
  // Only a skill of the chat's list reads so (skillWords.ts).
  const skills = useContext(SkillWordsContext);
  const row = useMemo(() => shownSkills(withoutVideoFrames(given), skills), [given, skills]);
  // Read before the frames go: a video's note and first frame are its tile (sentVideos.ts).
  const videos = useMemo(() => sentVideosOf(given), [given]);
  const text = useMemo(
    () =>
      withoutSkillDollars(
        withoutFramesNotes(givenText, frameTextOf(rowImageNames(given)), !given.pasted?.length),
        skills,
      ),
    [givenText, given, skills],
  );
  const t = useT();
  const { edit, branches, fork, forkSeq, forkAny, promptTurns } = useContext(TurnActionsContext);
  const branch = branches?.of.get(row.id);
  const [editing, setEditing] = useState(false);
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
      : row.retryAttachments?.flatMap((file): FileAttachmentInfo[] =>
          file.kind === "link" && !file.mimeType.startsWith("video/")
            ? [{ ...file, size: file.mimeType || file.size > 0 ? file.size : undefined }]
            : [],
        )
  )?.filter((file) => !videos.some((video) => video.name === file.name && video.path === file.path));
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
  const firstMedia = orderedParts?.findIndex((part) => part.kind !== "text") ?? -1;
  const placed = orderedParts?.some((part) => part.kind !== "text" && part.placed === true) ?? false;
  const hasInterleaved =
    firstMedia >= 0 &&
    (placed
      ? orderedParts!.some((part) => !isStripMedia(part))
      : orderedParts!.slice(firstMedia + 1).some((part) => part.kind === "text"));
  const strip = useComposerSettings().attachmentView === "strip" && hasInterleaved;
  // A placed prompt's attachments the composer left in the strip (unmarked) stay in the band.
  const banded = (part: PromptContentPart) =>
    isStripMedia(part) && (strip || (hasInterleaved && placed && part.placed !== true));
  const stripMedia = orderedParts?.filter(isStripMedia).filter(banded) ?? [];
  const shownParts = orderedParts?.filter((part) => !banded(part));
  const renderImage = useCallback((image: PromptImage) => <SentImage image={image} />, []);
  const renderFile = useCallback(
    (part: Exclude<PromptContentPart, { kind: "text" | "image" }>) => {
      const video = sentVideoOf(part, videos);
      return video ? (
        <span className="cv-user__inline-image">
          <SentVideoTile video={video} width={sentImageWidth(video)} />
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
  return (
    <>
      {!hasInterleaved && (Boolean(row.images?.length) || videos.length > 0) && (
        <SentImages images={row.images ?? []} leading={videos.length > 0 ? <SentVideoTiles videos={videos} /> : null} />
      )}
      {!hasInterleaved && Boolean(files?.length) && (
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
        {/* No text to read draws no bubble: a prompt of images alone is its images (an empty glass
            bubble under them read as a lost message; Leo 2026-10-21). */}
        {(strip ? shownParts!.some(readsAsText) : hasInterleaved || text.trim()) && (
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
            {/* A prompt this pane sent that is still on its way; a steer's mark says it instead. */}
            {row.delivery && !row.steer && <DeliveryMark delivery={row.delivery} />}
          </div>
        )}
        {/* A prompt held while its agent starts keeps the footer too (time and Copy), so nothing
            moves once it goes (Leo, 2026-11-01: "then the stupid ass layout shift"). */}
        {!row.failed && (text || pending) && (
          <UserFooter
            className={branch ? "cv-user__actions cv-user__actions--versions" : "cv-user__actions"}
            pending={pending}
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
                    <ChevronLeft size={12} />
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
                <ForkButton
                  throughSeq={forkThrough}
                  onFork={() => forkWithFeedback(forkThrough, () => fork!(forkThrough))}
                />
              )}
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

/// The paths of the originals a prompt's images kept (an image the composer converted sends its
/// original file after it).
function imageOriginals(row: AcpmuxRow): ReadonlySet<string> {
  return new Set(
    row.retryAttachments?.flatMap((file) => (file.kind === "image" && file.originalPath ? [file.originalPath] : [])),
  );
}

/// A file part that is an image's retained original: drawn as the image, never again as a file.
function isImageOriginal(part: PromptContentPart, originals: ReadonlySet<string>): boolean {
  return part.kind === "file" && (part.companionOf !== undefined || originals.has(attachmentPath(part.uri) ?? ""));
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
function SentVideoTiles({ videos }: { videos: readonly SentVideo[] }) {
  return videos.map((video) => (
    <SentVideoTile key={`${video.name}\n${video.path}`} video={video} width={sentImageWidth(video)} />
  ));
}

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
    <span className="cv-user__sourced">
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
