// Break points inside a long token: a SHA range (`9127e619…..68ab…`), a path or a URL has no space,
// so the bubble's `overflow-wrap: break-word` cut it wherever the line ran out, mid-word (Leo
// 2026-10-28: "WHY IS THIS RENDERING/MESSAGING NOT FIXED YET"). A `<wbr>` after a range's `..`
// and after each separator lets the line end there instead; it is invisible, copies as nothing,
// and Find still sees the token whole. Short words take none.
import { Fragment } from "react";
import { softBreaks } from "./softBreaksModel";
/// A code span's or typed text's long tokens with break points, as one node.
export function SoftBroken({ text }: { text: string }) {
  return <Fragment>{softBreaks(text, "sb")}</Fragment>;
}
