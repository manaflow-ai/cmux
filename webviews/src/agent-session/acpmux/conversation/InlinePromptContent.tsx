import { Fragment, memo, useContext, type ReactNode } from "react";
import type { PromptContentPart, PromptImage } from "../model";
import { FindReveal } from "./chatFind";
import { attachmentPath, FileAttachment } from "../FileAttachment";
import { PasteChip, PromptText, PromptTyped } from "./PromptText";
import { HUGE_PROMPT_HEAD_CHARS, hasHugeTypedPart, headParts } from "./promptCollapse";

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
      huge={hasHugeTypedPart(parts)}
    >
      {(open, head) => (
        <span className="cv-user__inline-content" data-inline-content="true">
          {/* A huge prompt collapsed draws only its head (PromptText.tsx): the clamp hides the rest. */}
          {(head ? headParts(parts, HUGE_PROMPT_HEAD_CHARS, typedText) : parts).map((part, index) => {
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
    if (part.kind === "text")
      return (
        <PromptTyped key={`text-${index}`} text={part.text} show={show} plain={"huge" in part && part.huge === true} />
      );
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
    return <PromptFile key={`${part.kind}-${part.id ?? part.name}-${index}`} part={part} />;
  }
});

/** A sent file, document or recording in a prompt's order (the bubble's text, or the strip view's
 * band): the same file chip a legacy prompt's band and the composer draw (FileAttachment.tsx), with
 * its size and its whole path as its tooltip, so two files of one name read apart. */
export function PromptFile({ part }: { part: Exclude<PromptContentPart, { kind: "text" | "image" }> }) {
  return (
    <span className="cv-user__inline-file">
      <FileAttachment
        file={{
          name: part.name,
          size: part.size,
          mimeType: part.mimeType,
          path: attachmentPath(part.uri),
          // The app it came from: its icon and tooltip line, as the legacy band's file chip has.
          source: part.source,
        }}
      />
    </span>
  );
}

/** Whether a part the strip view keeps in the bubble gives it something to read: typed text with
 * more than space, a pasted block, a text file's body. */
export function readsAsText(part: PromptContentPart): boolean {
  return part.kind === "text" ? part.text.trim() !== "" : part.kind === "pasted" || Boolean(blockText(part));
}

/** The text block a part went to the agent as (typed text, a pasted block, a text file's body), or
 * none for an attachment. */
function blockText(part: PromptContentPart): string | undefined {
  if (part.kind === "text") return part.text;
  if (part.kind === "pasted" || (part.kind === "file" && !part.uri)) return part.text;
  return undefined;
}

/** A typed text block's text: what a collapsed huge prompt's head counts (pastes are chips). */
const typedText = (part: PromptContentPart) => (part.kind === "text" ? part.text : undefined);

/** The parts the strip setting moves to the band above the bubble: attachments, not what reads as
 * the prompt's text (typed text, pasted blocks and a text file's body stay in the bubble, as a
 * legacy prompt's do), so the bubble keeps the recorded text whole. */
export function isStripMedia(part: PromptContentPart): part is Exclude<PromptContentPart, { kind: "text" }> {
  return blockText(part) === undefined;
}
