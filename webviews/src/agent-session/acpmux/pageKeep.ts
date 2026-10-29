// The agent page's own keep reasons: an unsent prompt or attachments hold `draft`,
// which keeps the hidden page from being discarded, and dictation holds `capture`, which also keeps
// it from being frozen. The host hears each start and end once (PageKeepAlive), never per keystroke.
import { useEffect, useRef } from "react";
import { pageKeepAliveFor, type PageKeepAlive, type PageKeepReason } from "../../pages/shared/pageClient";
import { pageHostClient } from "./pageHost";

/** The agent page's keep reasons: its page host client's, or one that sends nothing on the old host. */
export const agentPageKeepAlive = (): PageKeepAlive => pageKeepAliveFor(pageHostClient());

/** Holds `reason` while `on`, as this component's own holder; the unmount ends it. */
export function usePageKeepReason(
  reason: PageKeepReason,
  on: boolean,
  keep: () => PageKeepAlive = agentPageKeepAlive,
): void {
  const holder = useRef<object>({}).current;
  useEffect(() => {
    if (!on) return;
    const alive = keep();
    alive.set(reason, true, holder);
    return () => alive.set(reason, false, holder);
  }, [reason, on, keep, holder]);
}

/**
 * Holds `draft` while the prompt has unsent text or attachments. Once it empties (sent or cleared),
 * what was typed into the page is no longer an unsaved edit: the page's edits end (pageEdits.ts).
 */
export function usePageDraft(unsent: boolean, keep: () => PageKeepAlive = agentPageKeepAlive): void {
  usePageKeepReason("draft", unsent, keep);
  const held = useRef(false);
  useEffect(() => {
    if (unsent) {
      held.current = true;
      return;
    }
    if (!held.current) return;
    held.current = false;
    keep().editsSaved();
  }, [unsent, keep]);
}
