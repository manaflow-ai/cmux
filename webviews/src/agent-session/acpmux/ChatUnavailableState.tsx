import type { ChatUnavailable } from "./chatUnavailable";
import { Spinner } from "./conversation/icons";
import { relativeTime } from "./conversation/relativeTime";
import { currentLanguage, useT } from "./i18n";

/// The tab's chat is not here (`missingSession`): centered in place of the transcript, quiet, in the
/// new chat hero's type (EmptyState.tsx), it says which case it is. Deleted: Remove from Sidebar
/// closes the tab. Its machine is not connected: the machine, when it was last seen, and Reconnect,
/// which reads the machines and the chat list again (the chat opens once it is listed). Still
/// connecting (the grace, chatUnavailable.ts): nothing, an empty area where the chat opens once it
/// is listed; never "unavailable" (Leo 2026-10-21: "second pic is weird has "this chat isn't
/// available"") and no spinner or "Reconnecting…" (Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT
/// ON LOAD"). Not listed and never seen here (it may be deleted, or in an acpmux this tab is
/// not routed to): "Can't find this chat", never "deleted". Every case but loading keeps what MissingChat.tsx
/// offered (Lawrence, 86dec887282): the chat's short session id, so a person knows which chat it was,
/// Resume from Transcript, which opens All Chats, where the chat's saved transcript resumes in a new
/// session, and Close Tab (a deleted chat's is Remove from Sidebar).
export function ChatUnavailableState({
  unavailable,
  session,
  machine,
  now = Date.now(),
  onResumeMachine,
  resuming = false,
  error,
  onRemove,
  onReconnect,
  onResume,
  onClose,
}: {
  unavailable: ChatUnavailable;
  /// The session the tab recorded (`missingSession`); its first 13 characters show under the detail.
  session?: string;
  /// The machine the app says the tab's chat is on (the handshake's `machineName`), for a deleted chat.
  machine?: string;
  now?: number;
  onResumeMachine?(): void;
  resuming?: boolean;
  error?: string;
  onRemove(): void;
  onReconnect(): void;
  onResume?(): void;
  /// Close Tab, on every case but deleted (Remove from Sidebar closes that one's tab).
  onClose?(): void;
}) {
  const t = useT();
  // Still loading: nothing shows until the chat opens or the grace ends (then offline, below).
  if (unavailable.reason === "connecting")
    return <div className="acpmux-empty acpmux-unavailable" data-unavailable="connecting" aria-busy="true" />;
  // A deleted chat names the machine acpmux had it on when the pane knows it, else the tab's machine;
  // one not connected names only the peer acpmux had it on, never this Mac's name (the handshake's
  // for a chat of this Mac); one not found here is not on the tab's machine.
  const named =
    unavailable.reason === "deleted"
      ? (unavailable.machine ?? machine)
      : unavailable.reason === "notFound"
        ? machine
        : unavailable.machine;
  let title: string;
  let detail: string | undefined;
  let action: { label: string; run(): void; kind: string } | undefined;
  if (unavailable.reason === "paused") {
    title = t("unavailable.paused.title");
    detail = t("unavailable.paused.detail", { machine: named ?? machine ?? "" });
    if (onResumeMachine)
      action = {
        label: t("unavailable.resumeMachine"),
        run: onResumeMachine,
        kind: "resumeMachine",
      };
  } else if (unavailable.reason === "machineDeleted") {
    title = t("unavailable.machineDeleted.title");
    detail = t("unavailable.machineDeleted.detail", { machine: named ?? machine ?? "" });
  } else if (unavailable.reason === "deleted") {
    title = t("unavailable.deleted.title");
    detail = named ? t("unavailable.deleted.detailOn", { machine: named }) : t("unavailable.deleted.detail");
    action = { label: t("unavailable.remove"), run: onRemove, kind: "remove" };
  } else if (unavailable.reason === "notFound") {
    // Not listed here and never seen here: it may be deleted, or in an acpmux this tab is not routed
    // to (a Chief home's own), so the pane never says it was deleted.
    title = t("unavailable.notFound.title");
    detail = named ? t("unavailable.notFound.detailOn", { machine: named }) : t("unavailable.notFound.detail");
  } else {
    title = `${t("header.reconnecting")}…`;
    detail =
      unavailable.lastSeen !== undefined
        ? t("unavailable.offline.lastSeen", {
            time: relativeTime(unavailable.lastSeen, now, currentLanguage()),
          })
        : t("unavailable.offline.detail");
    action = { label: t("unavailable.reconnect"), run: onReconnect, kind: "reconnect" };
  }
  // Remove from Sidebar closes a deleted chat's tab; every other case keeps MissingChat's Close Tab.
  const closes = onClose !== undefined && unavailable.reason !== "deleted";
  return (
    <div
      className="acpmux-empty acpmux-unavailable"
      data-unavailable={unavailable.reason}
      role={unavailable.reason === "offline" ? "status" : "alert"}
    >
      {unavailable.reason === "offline" ? (
        <Spinner size={28} loading className="acpmux-unavailable-spinner" />
      ) : (
        <svg
          className="acpmux-empty-glyph"
          width={36}
          height={36}
          viewBox="0 0 36 36"
          fill="none"
          stroke="currentColor"
          strokeWidth={1.5}
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
          focusable="false"
        >
          <rect x="4.75" y="6.75" width="26.5" height="22.5" rx="6" />
          {unavailable.reason === "deleted" || unavailable.reason === "notFound" ? (
            <path d="M13.5 18h9" />
          ) : (
            <path d="M11.5 18h1M17.5 18h1M23.5 18h1" />
          )}
        </svg>
      )}
      <h2 className="acpmux-empty-title acpmux-unavailable-title">{title}</h2>
      <div className="acpmux-unavailable-copy">
        {resuming && <Spinner size={20} loading />}
        {error && (
          <p className="acpmux-unavailable-detail" role="alert">
            {error}
          </p>
        )}
        {detail && <p className="acpmux-unavailable-detail">{detail}</p>}
        {session && (
          <p className="acpmux-unavailable-detail acpmux-unavailable-session">
            {t("unavailable.session", { session: shortSession(session) })}
          </p>
        )}
        {(action || onResume || closes) && (
          <div className="acpmux-unavailable-actions">
            {action && (
              <button
                type="button"
                className="acpmux-unavailable-action"
                data-action={action.kind}
                disabled={resuming}
                onClick={action.run}
              >
                {action.label}
              </button>
            )}
            {onResume && (
              <button type="button" className="acpmux-unavailable-action" data-action="resume" onClick={onResume}>
                {t("link.missing.resume")}
              </button>
            )}
            {closes && (
              <button type="button" className="acpmux-unavailable-action" data-action="close" onClick={onClose}>
                {t("link.missing.close")}
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

/// The first 13 characters of a session id (an acpmux UUIDv7's time part), enough to tell chats apart.
export function shortSession(session: string): string {
  return session.length > 13 ? session.slice(0, 13) : session;
}
