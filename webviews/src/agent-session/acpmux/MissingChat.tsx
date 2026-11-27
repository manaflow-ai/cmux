import { useT } from "./i18n";

/// The session this tab recorded is not in the acpmux it attached to (`missingSession`): it was
/// deleted, or it runs on a machine that is not connected. The line names the machine and the
/// session, so a person knows which chat it was, and never leaves them at a dead end: Resume from
/// Transcript opens All Chats, where the chat's saved transcript resumes in a new session, and
/// Close Tab closes it. It drops in from the top of the chat (ui/popupSurface.css `data-enter`).
export function MissingChat({
  session,
  machine,
  onResume,
  onClose,
}: {
  session: string;
  machine?: string;
  onResume(): void;
  onClose(): void;
}) {
  const t = useT();
  return (
    <div className="acpmux-link-missing acpmux-live-chat" role="alert" data-enter="top">
      <p>{t("link.sessionMissing")}</p>
      {machine && (
        <p className="acpmux-missing-chat-detail">
          {t("link.sessionMissingDetail", { machine, session: shortSession(session) })}
        </p>
      )}
      <p className="acpmux-live-chat-actions">
        <button type="button" className="acpmux-folder-choice-button" onClick={onResume}>
          {t("link.missing.resume")}
        </button>
        <button type="button" className="acpmux-folder-choice-button" onClick={onClose}>
          {t("link.missing.close")}
        </button>
      </p>
    </div>
  );
}

/// The first 13 characters of a session id (an acpmux UUIDv7's time part), enough to tell chats apart.
function shortSession(session: string): string {
  return session.length > 13 ? session.slice(0, 13) : session;
}
