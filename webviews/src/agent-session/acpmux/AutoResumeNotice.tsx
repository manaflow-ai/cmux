import type { AutoResumeStatus } from "./autoResumeStatus";
import { useConnectionQuiet } from "../../ui/lasting";
import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import { retryLabel } from "./subagents/retryState";

/// One quiet line in the existing composer notice slot, shared by local and Cloud chats: only while
/// the daemon waits to retry, and only once that has lasted the shared 10 s (a capacity or transport
/// retry usually runs under it, and the person can do nothing about the wait). A turn it already
/// resumed shows nothing; the reply says so itself. The slot's line lies over the transcript's foot
/// (noticeSlotModel.ts `DOCK_NOTICE`), so showing it moves no row.
export function AutoResumeNotice({ state }: { state: AutoResumeStatus | undefined }) {
  const t = useT();
  const retry = state?.retry;
  const lasting = useConnectionQuiet(Boolean(retry));
  return (
    <Notice id="auto-resume" tier="status" when={lasting && retry}>
      <output className="acpmux-switch-notice" data-auto-resume="waiting">
        {retry ? retryLabel(t, retry) : null}
      </output>
    </Notice>
  );
}
