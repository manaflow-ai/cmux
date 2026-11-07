import { Fragment, memo, useMemo, type ReactNode } from "react";
import type { PromptContentPart, PromptImage } from "../model";
import { attachmentPath, FileAttachment } from "../FileAttachment";
import { PastedText, PromptText, PromptTyped } from "./PromptText";
import {
  blockText,
  drawnBody,
  drawnPromptText,
  HUGE_PROMPT_HEAD_CHARS,
  hasHugeTypedPart,
  headParts,
  isStripMedia,
} from "./promptCollapse";
import { experimentArm } from "../../../experiments/experiment";
import { sentPasteJoin } from "./sentPasteJoin.experiment";

/** Sent prompt content in ACP order. Text and attachment runs stay in one bubble, like Messages.
 * The typed text and the person's pastes between two attachments are one text body
 * (promptCollapse.ts `oneBody`; ask-14d16a6247), as the draft read; a paste another agent wrote
 * stands apart as its own lines, never a card (PromptText.tsx PastedText), and an attachment (a text
 * file too) keeps its chip. */
export const InlinePromptContent = memo(function InlinePromptContent({
  rowId,
  parts,
  show,
  renderImage,
  renderFile,
}: {
  rowId: string;
  parts: readonly PromptContentPart[];
  show(text: string): string;
  renderImage(image: PromptImage): ReactNode;
  /// A file drawn some other way than its chip (a sent video's tile, UserBubble.tsx), or undefined.
  renderFile?(part: Exclude<PromptContentPart, { kind: "text" | "image" }>): ReactNode | undefined;
}) {
  const join = experimentArm(sentPasteJoin);
  // The words between two pastes are the draft's own runs, so as typed the runs join with nothing.
  const body = useMemo(() => drawnBody(parts, join), [parts, join]);
  return (
    <PromptText
      rowId={rowId}
      // What Find searches and the fold measures: the words the bubble draws.
      text={drawnPromptText(parts)}
      show={show}
      huge={hasHugeTypedPart(body)}
    >
      {(_open, head, collapsed) => (
        <span className="cv-user__inline-content" data-inline-content="true">
          {/* A huge prompt collapsed draws only its head (PromptText.tsx): the clamp hides the rest. */}
          {(head ? headParts(body, HUGE_PROMPT_HEAD_CHARS, typedText) : body).map((part, index, shown) => {
            // The body is one text between attachments; a paste apart from it is a block of its own
            // lines, and an attachment drawn between two runs stands in their join. Two text parts
            // side by side (a huge body's head) read as the recorded text does, a newline between.
            const separator = index > 0 && part.kind === "text" && shown[index - 1]!.kind === "text" ? "\n" : null;
            return (
              <Fragment key={index}>
                {separator}
                {renderPart(part, index, collapsed)}
              </Fragment>
            );
          })}
        </span>
      )}
    </PromptText>
  );

  function renderPart(part: PromptContentPart, index: number, collapsed: boolean): ReactNode {
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
    // A paste another agent wrote: its own lines under its "Pasted from" line. A text file keeps
    // its file chip, as every attachment does; its body is in the prompt's recorded text.
    if (part.kind === "pasted" && part.text)
      return <PastedText key={`pasted-${index}`} text={part.text} collapsed={collapsed} />;
    return renderFile?.(part) ?? <PromptFile key={`${part.kind}-${part.id ?? part.name}-${index}`} part={part} />;
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

export { isStripMedia };

/** A body's text: what a collapsed huge prompt's head counts. */
const typedText = (part: PromptContentPart) => (part.kind === "text" ? part.text : undefined);
