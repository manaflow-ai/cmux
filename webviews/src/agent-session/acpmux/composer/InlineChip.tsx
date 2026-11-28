import { memo, useState } from "react";
import type { ComposerAttachment } from "../attachments";
import { ContextMenu } from "../../../ui/ContextMenu";
import { ImageIcon, PlayTriangle } from "../conversation/icons";
import { usePaneLanguage, useT } from "../i18n";
import { pasteName } from "../conversation/promptCollapse";
import { imageLabel } from "../imageLabel";
import { AttachmentChip, InstantPreview, PendingChip, UploadProgress, useStillUploading } from "./attachmentIntake";
import { imageShape, type PendingAttachment } from "./attachmentIntakeModel";
import { localDraftShape, useDraftRatio } from "./draftMediaShape";
import { videoShapeStyle } from "./videoShape";
import { keptThumb } from "./imagePool";
import { PasteLoadingMark } from "./pasteLoading";
import { PASTE_LOADING_CLASS, usePasteLoadingLook } from "./pasteLoadingLook";
import { PastedTextChip } from "./PastedTextChip";
import { UIPickChip } from "./UIPickChip";
import { BrowserPickChip } from "./BrowserPickChip";
import { isBrowserPick } from "./browserPickModel";
import { isUIPick } from "./uiPickModel";
import { pastedSize } from "./textAttachmentCardModel";
import { RemoveGlyph } from "./RemoveGlyph";
import { chipRef } from "../conversation/sendMorph";

/// An attachment as the text shows it: the strip's own chip (attachmentIntake.tsx AttachmentChip), with
/// its preview, open, play and × (which takes it out of the prompt); a file still being read spins
/// (its × cancels it); one that could not be read says why, with Retry. Memoized: a keystroke
/// re-renders the composer, never a chip whose attachment did not change.
export const InlineChip = memo(function InlineChip({
  id,
  attachment,
  pending,
  onRemove,
  onCancel,
  onExpand,
  onKeepFile,
  codex,
  originalFailed,
}: {
  id: string;
  attachment: ComposerAttachment | undefined;
  pending: PendingAttachment | undefined;
  onRemove(id: string): void;
  onCancel(id: string): void;
  onExpand(id: string): void;
  onKeepFile?(id: string): void;
  codex: boolean;
  originalFailed: string | undefined;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const look = usePasteLoadingLook();
  // A loading tile whose upload is asked again on its own: its quiet words once that lasts.
  const still = useStillUploading(
    pending ?? {},
    pending?.image ? imageLabel(t, { name: pending.name }) : (pending?.name ?? ""),
  );
  const ratio = useDraftRatio(attachment?.[localDraftShape] ?? pending?.[localDraftShape]);
  /// Whether this chip loaded in place (a paste, a drop): its picture then comes up from the loading
  /// tile's dim instead of popping in. A chip that arrives ready (a draft read back) just shows.
  // Sticky state set in render (not a ref read in render): it flips once, the first time it holds.
  const [loaded, setLoaded] = useState(false);
  // Only a tile that showed (not one held unseen for its size or picture) has a dim to come up from.
  if (!loaded && pending && !pending.resolvingPath && !pending.failed && !pending.sizing && ratio !== 0)
    setLoaded(true);
  /// Whether its loading tile already showed its own picture: the chip then just stays, with no
  /// second coming up (Leo, 2026-11-11: "this 3 stage attachment thing is still there").
  const [pictured, setPictured] = useState(false);
  if (!pictured && pending?.preview && pending.image && !pending.failed) setPictured(true);

  // A node whose attachment is not here (yet: a chat's kept chips still on their way) draws nothing.
  if ((!attachment && !pending) || ratio === 0) return null;
  if (!attachment && pending && ((!pending.image && !pending.video) || pending.resolvingPath))
    return (
      <span className="acpmux-md-inline-chip" data-chip="strip">
        <PendingChip chip={pending} onCancel={onCancel} />
      </span>
    );
  const name = imageLabel(t, { name: attachment?.name ?? pending?.name, ...keptThumb(id) });
  const remove = (
    <button
      type="button"
      className="acpmux-md-inline-remove"
      aria-label={t(pending && !pending.failed ? "composer.cancelAttachment" : "composer.removeAttachment", { name })}
      onClick={() => (attachment ? onRemove(id) : onCancel(id))}
    >
      <RemoveGlyph />
    </button>
  );
  if (!attachment)
    return (
      <span
        className={pending!.failed ? "acpmux-md-inline-chip" : `acpmux-md-inline-chip ${PASTE_LOADING_CLASS}`}
        data-state={pending!.failed ? "failed" : "loading"}
        {...(pending!.failed ? {} : { "data-paste-look": look })}
        // A loading image is the shape its thumbnail will be (its header's size), so the picture
        // arriving moves nothing.
        {...(!pending!.failed && pending!.image && (ratio || pending!.size)
          ? { "data-sized": "", style: imageShape(ratio ? { width: ratio, height: 1 } : pending!.size) }
          : {})}
        // A video is the box its chip, poster and sent tile keep (videoShape.ts), loading or failed.
        {...(pending!.video ? { "data-video-shape": "", style: videoShapeStyle(ratio ?? pending!.videoShape) } : {})}
        {...(!pending!.failed && pending!.sizing ? { "data-sizing": "" } : {})}
        {...(!pending!.failed && pending!.image && pending!.preview ? { "data-instant": "" } : {})}
        aria-busy={pending!.failed ? undefined : "true"}
        aria-label={name}
        {...(still ? { "data-still-trying": "" } : {})}
        /* tooltip-allow: the tile is cut to its size; the tooltip has why it failed or is still trying */
        title={pending!.failed ?? still}
      >
        {pending!.failed ? (
          <>
            {pending!.image ? (
              <ImageIcon size={14} className="acpmux-attachment-failed-icon" />
            ) : (
              <PlayTriangle size={14} className="acpmux-attachment-failed-icon" />
            )}
          </>
        ) : (
          <>
            {pending!.preview && <InstantPreview src={pending!.preview} />}
            <PasteLoadingMark
              look={look}
              size={14}
              className="acpmux-md-inline-spinner"
              upload={
                pending!.progress === undefined ? undefined : (
                  <UploadProgress value={pending!.progress} name={name} size={14} />
                )
              }
            />
          </>
        )}
        {remove}
      </span>
    );
  // A huge paste: the compact chip that opens its whole text (PastedTextChip.tsx), Edit in Prompt
  // and Keep as .txt in the opened view.
  if (attachment.kind === "pasted") {
    const text = attachment.text ?? "";
    const label = `${t("composer.pastedText")} · ${pastedSize(t, language, text)}`;
    // Its right-click menu has what the strip's has (attachmentIntake.tsx `menu`): Edit in Prompt,
    // Keep as .txt and Remove.
    const items = [
      { id: "open", label: t("composer.pastedText.edit"), onSelect: () => onExpand(id) },
      ...(onKeepFile ? [{ id: "keep", label: t("composer.pastedText.keepFile"), onSelect: () => onKeepFile(id) }] : []),
      {
        id: "remove",
        label: t("composer.removeAttachment", { name }),
        separatorBefore: true,
        onSelect: () => onRemove(id),
      },
    ];
    return (
      <ContextMenu className="acpmux-attachment-menu" items={items}>
        <PastedTextChip
          host="inline"
          text={text}
          name={t("composer.pastedText")}
          accessibleName={`${attachment.name || pasteName(text)}, ${label}`}
          remove={remove}
          onEdit={() => onExpand(id)}
          {...(onKeepFile ? { onKeep: () => onKeepFile(id) } : {})}
        />
      </ContextMenu>
    );
  }
  // A browser pick: its number and comment, opening its whole card in place (BrowserPickChip.tsx).
  if (attachment.kind === "text" && attachment.text !== undefined && isBrowserPick(attachment))
    return (
      <ContextMenu
        className="acpmux-attachment-menu"
        items={[{ id: "remove", label: t("composer.removeAttachment", { name }), onSelect: () => onRemove(id) }]}
      >
        <BrowserPickChip host="inline" name={attachment.name} text={attachment.text} remove={remove} />
      </ContextMenu>
    );
  // An inspector pick: the element and a snippet of its text, opening its whole report in place
  // (UIPickChip.tsx). Its right-click menu removes it, as the strip's does.
  if (attachment.kind === "text" && attachment.text !== undefined && isUIPick(attachment))
    return (
      <ContextMenu
        className="acpmux-attachment-menu"
        items={[{ id: "remove", label: t("composer.removeAttachment", { name }), onSelect: () => onRemove(id) }]}
      >
        <UIPickChip host="inline" name={attachment.name} text={attachment.text} remove={remove} />
      </ContextMenu>
    );
  // An image, a PDF, a video or a file: the strip's chip, so it previews, opens, plays and falls back
  // (an image that cannot be drawn) as it does there.
  return (
    <span
      className="acpmux-md-inline-chip"
      data-state="ready"
      data-chip="strip"
      ref={chipRef(id)}
      {...(loaded && !pictured ? { "data-loaded": "" } : {})}
    >
      <AttachmentChip
        attachment={attachment}
        codex={codex}
        onRemove={onRemove}
        {...(originalFailed ? { originalFailed } : {})}
      />
    </span>
  );
});
