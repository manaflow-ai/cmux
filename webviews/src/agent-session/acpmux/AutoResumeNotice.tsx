import type { AutoResumeStatus } from "./autoResumeStatus";
import { useConnectionQuiet } from "../../ui/lasting";
import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import { QueueStatusLine } from "./QueueStatusLine";
import { queueStatus } from "./queueStatus";

/// One quiet line in the existing composer notice slot, shared by local and Cloud chats: only while
/// the daemon waits to retry, and only once that has lasted the shared 10 s (a capacity or transport
/// retry usually runs under it, and the person can do nothing about the wait). A turn it already
/// resumed shows nothing; the reply says so itself. The slot's line lies over the transcript's foot
/// (noticeSlotModel.ts `DOCK_NOTICE`), so showing it moves no row.
///
/// It says the wait as the queue's status line does (QueueStatusLine.tsx: "Waiting for capacity",
/// "retrying in 9:42 · 1 of 4"), and only while no queue draws that line: `inQueue`, prompts wait and
/// the queue's own line says it, so the state shows once (Leo, 2026-11-23, on this line over the
/// queue's "Paused after an error": "this looks ass idk").
export function AutoResumeNotice({
  state,
  inQueue = false,
}: {
  state: AutoResumeStatus | undefined;
  inQueue?: boolean;
}) {
  const t = useT();
  const retry = inQueue ? undefined : state?.retry;
  const lasting = useConnectionQuiet(Boolean(retry));
  const status = retry && queueStatus(t, { retry, paused: false });
  return (
    <Notice id="auto-resume" tier="status" when={lasting && status}>
      {status && <QueueStatusLine t={t} status={status} as="output" className="acpmux-switch-notice" autoResume />}
    </Notice>
  );
}
