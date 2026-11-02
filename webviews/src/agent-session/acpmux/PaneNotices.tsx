import { type PaneNotice, usePaneNotices } from "./paneNotices";
import { Notice } from "./NoticeSlot";

/// One app notice as a card above the composer (paneNotices.ts): the title, the detail under it,
/// and the app's button, off while its action runs.
export function PaneNoticeCard({ notice, onAction }: { notice: PaneNotice; onAction(id: string): void }) {
  return (
    <output className="acpmux-host-error acpmux-pane-notice" data-notice={notice.id}>
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">{notice.title}</p>
        {notice.detail && <p className="acpmux-host-error-hint">{notice.detail}</p>}
        {notice.button && (
          <div className="acpmux-host-error-actions">
            <button type="button" disabled={!notice.enabled} onClick={() => onAction(notice.id)}>
              {notice.button}
            </button>
          </div>
        )}
      </div>
    </output>
  );
}

/// The app's notices about the chat's agent service, in the notice slot: what happens now with the
/// chat's approvals, so a status, under an error.
export function PaneNotices({ onAction }: { onAction(id: string): void }) {
  const notices = usePaneNotices();
  return (
    <Notice id="pane-notices" tier="status" when={notices.length > 0}>
      {notices.map((notice) => (
        <PaneNoticeCard key={notice.id} notice={notice} onAction={onAction} />
      ))}
    </Notice>
  );
}
