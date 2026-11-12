// A message's text cut between whole lines past `lines` of them, with Show more / Show less under it
// (ExpandRow.tsx): a sent message's opened card (MessageCard.tsx) and an inbox thread's newest
// message (InboxNoticeCard.tsx). The cut is measured where the text wraps (lineCut.ts), never in
// the middle of a line, a chip or a code block, and again whenever the pane's width changes it.
// The caller owns whether it is open, so a virtualized row keeps it.
import { useId, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { ExpandRow } from "./ExpandRow";
import { CLAMPED_LINES, wholeLineCut } from "./lineCut";

export function ClampedText({
  expanded,
  onExpand,
  watch,
  className,
  lines = CLAMPED_LINES,
  children,
}: {
  expanded: boolean;
  onExpand(next: boolean): void;
  /// What the cut is measured again for when it changes (the text).
  watch: unknown;
  className: string;
  lines?: number;
  children: ReactNode;
}) {
  const t = useT();
  const id = useId();
  const ref = useRef<HTMLDivElement>(null);
  const [cutAt, setCutAt] = useState<number>();
  const measure = () => {
    const node = ref.current;
    if (!node) return;
    const limit = lines * parseFloat(node.ownerDocument.defaultView!.getComputedStyle(node).lineHeight);
    setCutAt(node.scrollHeight > limit + 1 ? wholeLineCut(node, limit) : undefined);
  };
  useLayoutEffect(() => {
    measure();
    // The pane's width decides the wrap and therefore the safe cut.
    const node = ref.current;
    if (!node || typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    observer.observe(node.firstElementChild ?? node);
    return () => observer.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- measure reads only the node
  }, [watch, lines]);
  const cut = !expanded && cutAt !== undefined;
  return (
    <>
      <div
        id={id}
        ref={ref}
        className={`${className}${cut ? " is-cut" : ""}`}
        style={cut ? { maxHeight: cutAt } : undefined}
        onFocusCapture={cut ? () => onExpand(true) : undefined}
      >
        {children}
      </div>
      {cutAt !== undefined && (
        <ExpandRow
          className="cv-user__more cv-message__more"
          open={expanded}
          controls={id}
          onToggle={() => onExpand(!expanded)}
          label={t(expanded ? "message.less" : "message.more")}
        />
      )}
    </>
  );
}
