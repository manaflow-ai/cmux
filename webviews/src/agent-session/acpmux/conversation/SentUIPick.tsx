// A sent prompt's text with its inspector picks drawn as the composer's chip (composer/UIPickChip.tsx)
// in the message's one body: the element and a snippet of its text, opening the whole report in place
// with Collapse to fold it back (sentUIPickModel.ts). The text around each pick draws as `typed` does
// (PromptText.tsx PromptTyped). Its own file, so the bubble's renderer changes by one line.
import { Fragment, type ReactNode } from "react";
import { UIPickChip } from "../composer/UIPickChip";
import type { SentPromptSegment } from "./sentUIPickModel";

export function SentUIPicks({
  segments,
  typed,
}: {
  segments: SentPromptSegment[];
  typed: (text: string) => ReactNode;
}) {
  return (
    <>
      {segments.map((segment, index) => (
        <Fragment key={index}>
          {segment.kind === "text" ? (
            typed(segment.text)
          ) : (
            <UIPickChip host="sent" name={segment.name} text={segment.text} />
          )}
        </Fragment>
      ))}
    </>
  );
}
