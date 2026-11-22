import { memo, useLayoutEffect, useRef, useState } from "react";
import { useT } from "./i18n";
import { announcerState, paneAnnouncement, type PaneAsk } from "./paneAnnouncer";
import "./PaneAnnouncer.css";

/// The pane's one polite live region (a11y gaps 1 and 2, paneAnnouncer.ts): "Needs your input: TITLE"
/// when an ask starts waiting, "Reply finished" when a turn ends. Always mounted, so the region is in
/// the accessibility tree before its text changes, which is what makes VoiceOver read the change.
export const PaneAnnouncer = memo(function PaneAnnouncer({
  sessionId,
  asks,
  working,
}: {
  sessionId: string | undefined;
  asks: readonly PaneAsk[];
  working: boolean;
}) {
  const t = useT();
  // The asks already waiting when the pane opened are seeded, not spoken: only a change is news.
  const before = useRef(announcerState(sessionId, asks, working));
  const [said, setSaid] = useState({ text: "", count: 0 });
  useLayoutEffect(() => {
    const next = paneAnnouncement(before.current, sessionId, asks, working);
    before.current = announcerState(sessionId, asks, working);
    if (!next) return;
    const text =
      next.kind === "finished"
        ? t("announce.replyFinished")
        : next.title
          ? t("announce.needsInputTitled", { title: next.title })
          : t("question.needsInput");
    // The same sentence twice is a change too: a trailing no-break space alternates, so the region's
    // text differs and is read again.
    setSaid((last) => ({ text: last.count % 2 ? text : `${text}\u00a0`, count: last.count + 1 }));
  }, [sessionId, asks, working, t]);
  return (
    <div className="acpmux-pane-announcer" role="status" aria-live="polite" aria-atomic="true" data-pane-announcer="">
      {said.text}
    </div>
  );
});
