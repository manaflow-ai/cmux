import type { AcpmuxRow } from "../model";
import { inboxThreadKey } from "./inboxNotice";

/// The ids a digest's lines open by: each message's row, and an inbox thread's line by its own key
/// (InboxNoticeCard.tsx `inboxThreadKey`), so a preview-only thread opens and reads its messages. A
/// batch inside it ("Received N messages", reports) keeps its own fold: it reveals its lines, then
/// each opens (Leo, 2026-11-02).
export function digestMembers(rows: readonly AcpmuxRow[]): string[] {
  return rows
    .filter((member) => !member.laneNoticeBatch)
    .flatMap((member) => {
      if (member.inboxThread) return [inboxThreadKey(member.id, member.inboxThread.threadId)];
      if (member.incoming?.kind === "inbox")
        return [
          member.id,
          ...member.incoming.notice.threads.map((thread) => inboxThreadKey(member.id, thread.threadId)),
        ];
      return [member.id];
    });
}
