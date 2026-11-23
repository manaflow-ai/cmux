// `row.hover` / `default`: the row ReplyActions drew before slots, unchanged (Slots.defaults.test.tsx
// compares it to the pre-slot JSX). Over a status row this line is the reply's whole bottom room
// (conversation.css `--cv-status-gap`), so its own blank box, never its buttons, is a transcript gap a
// drag can start from (gutterSelect.ts).
import type { RowHoverProps } from "./slot";

export function DefaultReplyActionsRow({ children }: RowHoverProps) {
  return (
    <div className="cv-turn-actions cv-reply-actions" data-transcript-gap="blank">
      {children}
    </div>
  );
}
