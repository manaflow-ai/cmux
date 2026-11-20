import { forwardRef } from "react";

/**
 * The chat's name in the header: plain text, as Claude Code and ChatGPT desktop draw it. It is not
 * a dropdown and draws no pill (Leo, 2026-11-01: "still background on the top right ... why is
 * there a dropdown of this"); the chat's actions are in the header's ⋮ menu. A double-click renames,
 * as ⌘R does. The ref is the inline rename form's anchor (RenameForm.tsx).
 */
export const ThreadTitle = forwardRef<HTMLSpanElement, { title: string; onRename?: () => void }>(function ThreadTitle(
  { title, onRename },
  ref,
) {
  return (
    <span ref={ref} className="acpmux-thread-title" title={title} onDoubleClick={onRename}>
      {title}
    </span>
  );
});
