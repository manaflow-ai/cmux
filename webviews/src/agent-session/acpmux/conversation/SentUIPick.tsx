// A sent prompt's text with its inspector picks drawn as the composer's chip (composer/UIPickChip.tsx)
// in the message's one body: the element and a snippet of its text, opening the whole report in place
// with Collapse to fold it back (sentUIPickModel.ts). The text around each pick draws as `typed` does
// (PromptText.tsx PromptTyped). Its own file, so the bubble's renderer changes by one line.
import { createContext, Fragment, useContext, useLayoutEffect, type ReactNode } from "react";
import { UIPickChip } from "../composer/UIPickChip";
import { FindReveal, foldFind } from "./chatFind";
import type { SentPromptSegment } from "./sentUIPickModel";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";

/// The sent prompt a pick's chip is drawn in (PromptText.tsx): its row, whether its fold is shut, and
/// how to open it. None outside a transcript's prompt (a gallery, a test of the chip alone).
export type SentPromptFold = { rowId: string; collapsed: boolean; open: () => void };
export const SentPromptFoldContext = createContext<SentPromptFold | undefined>(undefined);

/// A pick's chip in a sent message, as the text file's chip it took the place of behaved
/// (InlinePromptContent.tsx PromptTextFile): its open state is the row's disclosure
/// (`prompt:<row>:<slot>`), so it outlives the row's mount and a restored message; opening it opens
/// the prompt's fold first, so the report never opens behind the clamp; and Find's current match in
/// its report opens the chip and the fold, and repaints, so the match is drawn.
export function SentUIPickChip({ slot, name, text }: { slot: string; name: string; text: string }) {
  const fold = useContext(SentPromptFoldContext);
  const [open, setOpen] = useTranscriptDisclosure(`prompt:${fold?.rowId ?? ""}:${slot}`);
  const reveal = useContext(FindReveal);
  const needle = fold && reveal && reveal.rowId === fold.rowId ? reveal.needle : "";
  const hit = Boolean(needle && foldFind(text).includes(needle));
  useLayoutEffect(() => {
    if (!hit || (open && !fold?.collapsed)) return;
    if (fold?.collapsed) fold.open();
    setOpen(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [hit, reveal]);
  return (
    <UIPickChip
      host="sent"
      name={name}
      text={text}
      open={open}
      onOpenChange={(next) => {
        if (next) fold?.open();
        setOpen(next);
      }}
    />
  );
}

export function SentUIPicks({
  segments,
  typed,
  slot,
}: {
  segments: SentPromptSegment[];
  typed: (text: string) => ReactNode;
  /// Where the segments are in the prompt (its typed part), keying each pick's disclosure.
  slot: string;
}) {
  return (
    <>
      {segments.map((segment, index) => (
        <Fragment key={index}>
          {segment.kind === "text" ? (
            typed(segment.text)
          ) : (
            <SentUIPickChip slot={`${slot}:pick:${index}`} name={segment.name} text={segment.text} />
          )}
        </Fragment>
      ))}
    </>
  );
}
