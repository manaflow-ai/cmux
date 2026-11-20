import type { AutoResumeStatus } from "./autoResumeStatus";
import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import { retryLabel } from "./subagents/retryState";

/// One quiet line in the existing composer notice slot, shared by local and Cloud chats: only while
/// the daemon waits to retry. A turn it already resumed shows nothing; the reply says so itself.
export function AutoResumeNotice({ state }: { state: AutoResumeStatus | undefined }) {
  const t = useT();
  const retry = state?.retry;
  return (
    <Notice id="auto-resume" tier="status" when={retry}>
      <output className="acpmux-switch-notice" data-auto-resume="waiting">
        {retry ? retryLabel(t, retry) : null}
      </output>
    </Notice>
  );
}
