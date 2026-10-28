import { memo, type ReactNode } from "react";
import type { PromptContentPart, PromptImage } from "../model";
import { FileDoc } from "./icons";

/** Sent prompt content in ACP order. Text and attachment runs stay in one bubble, like Messages. */
export const InlinePromptContent = memo(function InlinePromptContent({
  parts,
  show,
  renderImage,
}: {
  parts: readonly PromptContentPart[];
  show(text: string): string;
  renderImage(image: PromptImage): ReactNode;
}) {
  return (
    <span className="cv-user__inline-content" data-inline-content="true">
      {parts.map((part, index) => {
        if (part.kind === "text") return <span key={`text-${index}`}>{show(part.text)}</span>;
        if (part.kind === "image")
          return (
            <span key={`image-${part.id}-${index}`} className="cv-user__inline-image">
              {renderImage(part)}
            </span>
          );
        return (
          <span
            key={`${part.kind}-${part.id ?? part.name}-${index}`}
            className="cv-user__inline-file"
            title={part.name}
          >
            <FileDoc size={14} />
            <span className="cv-user__inline-file-name">{part.name}</span>
            {part.kind === "pasted" && <span className="cv-user__inline-file-note">pasted text</span>}
          </span>
        );
      })}
    </span>
  );
});

export function orderedMedia(parts: readonly PromptContentPart[]) {
  return parts.filter((part) => part.kind !== "text");
}
