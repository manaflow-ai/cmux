import { Fragment, memo, useContext, type ReactNode } from "react";
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
      // The text acpmux recorded: its text blocks joined by a newline (hub/session.rs `prompt_text`),
      // what Find searches and the fold measures.
      text={parts.flatMap((part) => blockText(part) ?? []).join("\n")}
      show={show}
    >
      {(open) => (
        <span className="cv-user__inline-content" data-inline-content="true">
          {parts.map((part, index) => {
            // Two text blocks side by side read as the recorded text does, with its newline between
            // them; the strip view's bubble, its attachments moved to the band, is that text. An
            // attachment drawn between two blocks stands in the newline's place.
            const separator =
              index > 0 && blockText(part) !== undefined && blockText(parts[index - 1]!) !== undefined ? "\n" : null;
            return (
              <Fragment key={index}>
                {separator}
                {renderPart(part, index, open)}
              </Fragment>
            );
          })}
        </span>
      )}
    </PromptText>
  );

  function renderPart(part: PromptContentPart, index: number, open: () => void): ReactNode {
    if (part.kind === "text") return <span key={`text-${index}`}>{show(part.text)}</span>;
    if (part.kind === "image")
      return (
        <span key={`image-${part.id}-${index}`} className="cv-user__inline-image">
          {renderImage(part)}
        </span>
      );
    // A pasted block, or a text file's body (it starts with the file's name, attachments.ts
    // `promptText`): the chip that opens to its text, which is part of the prompt's recorded text.
    const body = blockText(part);
    if (body)
      return (
        <PasteChip key={`pasted-${index}`} rowId={rowId} index={index} text={body} needle={needle} onOpen={open} />
      );
    return (
      <span key={`${part.kind}-${part.id ?? part.name}-${index}`} className="cv-user__inline-file" title={part.name}>
        <FileDoc size={14} />
        <span className="cv-user__inline-file-name">{part.name}</span>
      </span>
    );
  }
});

/** The text block a part went to the agent as (typed text, a pasted block, a text file's body), or
 * none for an attachment. */
function blockText(part: PromptContentPart): string | undefined {
  if (part.kind === "text") return part.text;
  if (part.kind === "pasted" || (part.kind === "file" && !part.uri)) return part.text;
  return undefined;
}

/** The parts the strip setting moves to the band above the bubble: attachments, not what reads as
 * the prompt's text (typed text, pasted blocks and a text file's body stay in the bubble, as a
 * legacy prompt's do), so the bubble keeps the recorded text whole. */
export function isStripMedia(part: PromptContentPart): part is Exclude<PromptContentPart, { kind: "text" }> {
  return blockText(part) === undefined;
}
