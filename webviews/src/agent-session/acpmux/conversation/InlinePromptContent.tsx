import { memo, useContext, type ReactNode } from "react";
import type { PromptContentPart, PromptImage } from "../model";
import { FindReveal } from "./chatFind";
import { FileDoc } from "./icons";
import { PasteChip, PromptText } from "./PromptText";

/** Sent prompt content in ACP order. Text and attachment runs stay in one bubble, like Messages.
 * A pasted block is the same chip a legacy prompt draws (PromptText.tsx), opening to its text. */
export const InlinePromptContent = memo(function InlinePromptContent({
  rowId,
  parts,
  show,
  renderImage,
}: {
  rowId: string;
  parts: readonly PromptContentPart[];
  show(text: string): string;
  renderImage(image: PromptImage): ReactNode;
}) {
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === rowId ? reveal.needle : "";
  return (
    <PromptText
      rowId={rowId}
      text={parts.flatMap((part) => (part.kind === "text" ? [part.text] : [])).join("")}
      show={show}
    >
      {(open) => (
        <span className="cv-user__inline-content" data-inline-content="true">
          {parts.map((part, index) => {
            if (part.kind === "text") return <span key={`text-${index}`}>{show(part.text)}</span>;
            if (part.kind === "image")
              return (
                <span key={`image-${part.id}-${index}`} className="cv-user__inline-image">
                  {renderImage(part)}
                </span>
              );
            if (part.kind === "pasted" && part.text)
              return (
                <PasteChip
                  key={`pasted-${index}`}
                  rowId={rowId}
                  index={index}
                  text={part.text}
                  needle={needle}
                  onOpen={open}
                />
              );
            return (
              <span
                key={`${part.kind}-${part.id ?? part.name}-${index}`}
                className="cv-user__inline-file"
                title={part.name}
              >
                <FileDoc size={14} />
                <span className="cv-user__inline-file-name">{part.name}</span>
              </span>
            );
          })}
        </span>
      )}
    </PromptText>
  );
});

/** The parts the strip setting moves to the band above the bubble: attachments, not what reads as
 * the prompt's text (typed text and pasted blocks stay in the bubble, as a legacy prompt's do). */
export function isStripMedia(part: PromptContentPart): part is Exclude<PromptContentPart, { kind: "text" }> {
  return part.kind !== "text" && part.kind !== "pasted";
}
