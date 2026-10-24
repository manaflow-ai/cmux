import { memo, type ReactNode } from "react";
import type { PromptContentPart, PromptImage } from "../model";
import { FileDoc } from "./icons";

/** The ordered body of a sent prompt. Text stays in the bubble's reading order around attachments. */
export const InlinePromptContent = memo(function InlinePromptContent({
  parts,
  show,
  renderImage,
}: {
  parts: readonly PromptContentPart[];
  show: (text: string) => string;
  renderImage: (image: PromptImage) => ReactNode;
}) {
  return (
    <span className="cv-user__inline-content" data-inline-content="true">
      {parts.map((part, index) => {
        if (part.kind === "text") {
          return (
            // Text is a span so the next image/file remains in the same run rather than moving to
            // the old attachment band. `pre-wrap` in conversation.css preserves typed newlines.
            <span key={`text-${index}`} className="cv-user__inline-text">
              {show(part.text)}
            </span>
          );
        }
        if (part.kind === "image") {
          return (
            <span key={`image-${part.id}-${index}`} className="cv-user__inline-image">
              {renderImage(part)}
            </span>
          );
        }
        return <InlineFile key={`${part.kind}-${part.id ?? part.name}-${index}`} part={part} />;
      })}
    </span>
  );
});

function InlineFile({ part }: { part: Exclude<PromptContentPart, { kind: "text" | "image" }> }) {
  const note = part.kind === "pasted" ? "pasted text" : (part.mimeType ?? part.kind);
  return (
    <span className="acpmux-attachment acpmux-attachment-file cv-user__inline-file" title={part.name}>
      <FileDoc size={14} />
      <span className="cv-user__inline-file-name">{part.name}</span>
      <span className="cv-user__inline-file-note">{note}</span>
    </span>
  );
}
