import { Fragment, memo, useContext, useLayoutEffect, useMemo, type ReactNode } from "react";
import type { PromptContentPart, PromptImage } from "../model";
import { FileAttachment } from "../FileAttachment";
import { attachmentPath } from "../fileAttachmentModel";
import { PastedText, PromptText, PromptTyped } from "./PromptText";
import { FindReveal, foldFind } from "./chatFind";
import {
  blockText,
  bodyText,
  drawnBody,
  findBodyText,
  HUGE_PROMPT_HEAD_CHARS,
  hasHugeTypedPart,
  headParts,
} from "./promptCollapse";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { experimentArm } from "../../../experiments/experiment";
import { sentPasteJoin } from "./sentPasteJoin.experiment";
import { SentUIPickChip } from "./SentUIPick";
import { sentUIPick } from "./sentUIPickModel";

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
  // The typed part the prompt starts with, past attachments placed before it (as send reads the
  // prompt's first word): its first word draws as a command when it names one (PromptTyped `lead`).
  const firstWords = body.findIndex(
    (part) => part.kind === "pasted" || (part.kind === "text" && part.text.trim() !== ""),
  );
  const firstTyped = body[firstWords]?.kind === "text" ? firstWords : -1;
  return (
    <PromptText
      rowId={rowId}
      // What the fold measures: the words the bubble draws, from the same join.
      text={bodyText(body)}
      // What Find searches (chatFind.ts `drawnPromptText`, the same text): those words and each text
      // file's body behind its chip, so a match there opens the fold even past a huge prompt's head.
      findText={findBodyText(body)}
      show={show}
      huge={hasHugeTypedPart(body)}
    >
      {(open, head, collapsed) => (
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
                {renderPart(part, index, collapsed, open)}
              </Fragment>
            );
          })}
        </span>
      )}
    </PromptText>
  );

  function renderPart(part: PromptContentPart, index: number, collapsed: boolean, open: () => void): ReactNode {
    if (part.kind === "text")
      return (
        <PromptTyped
          key={`text-${index}`}
          text={part.text}
          show={show}
          plain={"huge" in part && part.huge === true}
          slot={`typed:${index}`}
          lead={index === firstTyped}
        />
      );
    if (part.kind === "image")
      return (
        <span key={`image-${part.id}-${index}`} className="cv-user__inline-image">
          {renderImage(part)}
        </span>
      );
    // A paste another agent wrote: its own lines under its "Pasted from" line. A text file keeps
    // its file chip, as every attachment does, and the chip opens to the body it went as.
    if (part.kind === "pasted" && part.text)
      return <PastedText key={`pasted-${index}`} text={part.text} collapsed={collapsed} />;
    const stored = blockText(part);
    // An inspector pick placed in the text went as a text file of its report (inlinePrompt.ts): it
    // draws as the composer's chip, opening the report in place (SentUIPick.tsx), not a file chip.
    const pick = part.kind === "file" && stored ? sentUIPick(stored) : undefined;
    // Its disclosure is the file chip's (`paste:<index>`), so a message opened before keeps it open.
    if (pick) return <SentUIPickChip key={`pick-${index}`} slot={`paste:${index}`} name={pick.name} text={pick.text} />;
    if (part.kind === "file" && stored)
      return (
        <PromptTextFile
          key={`file-${part.id ?? part.name}-${index}`}
          rowId={rowId}
          index={index}
          part={part}
          text={stored}
          collapsed={collapsed}
          onOpen={open}
        />
      );
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

/** A text file sent with no file behind it (its body went as a text block, attachments.ts
 * `promptText`): its file chip, which opens in place to the body it stored, as its paste card did
 * (the same disclosure, `prompt:<row>:paste:<index>`, kept by the row's id), restored messages
 * included. Opening it opens the prompt's fold, so the body shows whole. Find searches the body
 * (promptCollapse.ts `findBodyText`), and its current match there opens the chip and the fold, as it
 * opened the paste card (FindReveal). */
function PromptTextFile({
  rowId,
  index,
  part,
  text,
  collapsed,
  onOpen,
}: {
  rowId: string;
  index: number;
  part: Exclude<PromptContentPart, { kind: "text" | "image" }>;
  text: string;
  collapsed: boolean;
  onOpen: () => void;
}) {
  const [open, setOpen] = useTranscriptDisclosure(`prompt:${rowId}:paste:${index}`);
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === rowId ? reveal.needle : "";
  const hit = Boolean(needle && foldFind(text).includes(needle));
  useLayoutEffect(() => {
    if (!hit || (open && !collapsed)) return;
    if (collapsed) onOpen();
    setOpen(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [hit, reveal]);
  return (
    <>
      <button
        type="button"
        className="cv-user__inline-file cv-user__file-open"
        // Its name and size are a label, not the prompt's text: Find counts its body and paints
        // none here, as on the paste card's label, so the drawn matches keep Find's order.
        data-find-skip=""
        aria-expanded={open}
        onClick={() => {
          if (!open) onOpen();
          setOpen(!open);
        }}
      >
        <FileAttachment file={{ name: part.name, size: part.size, mimeType: part.mimeType, source: part.source }} />
      </button>
      {open && <PastedText text={text} collapsed={collapsed} file />}
    </>
  );
}

/** A body's text: what a collapsed huge prompt's head counts. */
const typedText = (part: PromptContentPart) => (part.kind === "text" ? part.text : undefined);
