import { memo, type ReactNode } from "react";
import type { PromptContentPart, PromptImage } from "../model";
import { FileDoc } from "./icons";
import { PasteChip } from "./PromptText";

type PartProps = {
  show: (text: string) => string;
  renderImage: (image: PromptImage) => ReactNode;
  rowId: string;
};

/** The ordered body of a sent prompt. Text stays in the bubble's reading order around attachments. */
export const InlinePromptContent = memo(function InlinePromptContent({
  parts,
  show,
  renderImage,
  rowId = "inline",
}: {
  parts: readonly PromptContentPart[];
  show: (text: string) => string;
  renderImage: (image: PromptImage) => ReactNode;
  rowId?: string;
}) {
  return (
    <span className="cv-user__inline-content" data-inline-content="true">
      {parts.map((part, index) => promptPart(part, index, { show, renderImage, rowId }))}
    </span>
  );
});

/** The Strip view's row above the bubble (`agentPane.attachmentView` "strip", composerSettings.ts):
 * a sent prompt's attachments of every kind, in the order they were added; the bubble keeps the
 * text. `index` is each part's place among all of them, so a pasted block keeps its disclosure
 * when the view switches. */
export const StripPromptAttachments = memo(function StripPromptAttachments({
  parts,
  show,
  renderImage,
  rowId = "inline",
}: {
  parts: readonly PromptContentPart[];
  show: (text: string) => string;
  renderImage: (image: PromptImage) => ReactNode;
  rowId?: string;
}) {
  return (
    <div className="cv-user__images cv-user__strip" data-attachment-view="strip">
      {parts.map((part, index) =>
        part.kind === "text" ? null : promptPart(part, index, { show, renderImage, rowId }),
      )}
    </div>
  );
});

/** One part of a sent prompt, named by `data-part` (its kind, then its text, id or name). */
function promptPart(part: PromptContentPart, index: number, { show, renderImage, rowId }: PartProps): ReactNode {
  if (part.kind === "text") {
    return (
      // Text is a span so the next image/file remains in the same run rather than moving to
      // the old attachment band. `pre-wrap` in conversation.css preserves typed newlines.
      <span key={`text-${index}`} className="cv-user__inline-text" data-part={`text:${part.text}`}>
        {show(part.text)}
      </span>
    );
  }
  if (part.kind === "image") {
    return (
      <span
        key={`image-${part.id}-${index}`}
        className="cv-user__inline-image"
        data-kind="image"
        data-part={`image:${part.id}`}
      >
        {renderImage(part)}
      </span>
    );
  }
  if (part.kind === "pasted" && part.text)
    return (
      <span key={`paste-${index}`} data-part={`pasted:${part.name}`}>
        <PasteChip rowId={rowId} index={index} text={part.text} needle="" onOpen={() => {}} />
      </span>
    );
  return <InlineFile key={`${part.kind}-${part.id ?? part.name}-${index}`} part={part} />;
}

function InlineFile({ part }: { part: Exclude<PromptContentPart, { kind: "text" | "image" }> }) {
  const note = part.kind === "pasted" ? "pasted text" : (part.mimeType ?? part.kind);
  return (
    <span
      className="acpmux-attachment acpmux-attachment-file cv-user__inline-file"
      title={part.name}
      data-part={`${part.kind}:${part.name}`}
    >
      <FileDoc size={14} />
      <span className="cv-user__inline-file-name">{part.name}</span>
      <span className="cv-user__inline-file-note">{note}</span>
    </span>
  );
}
