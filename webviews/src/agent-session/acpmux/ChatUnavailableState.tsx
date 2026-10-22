import type { ChatUnavailable } from "./chatUnavailable";
import { relativeTime } from "./conversation/relativeTime";
import { currentLanguage, useT } from "./i18n";

/// The tab's chat is not here (`missingSession`): centered in place of the transcript, quiet, in the
/// new chat hero's type (EmptyState.tsx), it says which case it is. Deleted: Remove from Sidebar
/// closes the tab. Its machine is not connected: the machine, when it was last seen, and Reconnect,
/// which reads the machines and the chat list again (the chat opens once it is listed). Still
/// connecting: only that, never "unavailable" (Leo 2026-10-21: "second pic is weird has "this chat
/// isn't available""). Deleted or not connected, Resume from Transcript opens All Chats, where the
/// chat's saved transcript resumes in a new session (the way on MissingChat.tsx offered).
export function ChatUnavailableState({
  unavailable,
  machine,
  now = Date.now(),
  onRemove,
  onReconnect,
  onResume,
}: {
  unavailable: ChatUnavailable;
  /// The machine the app says the tab's chat is on (the handshake's `machineName`), for a deleted chat.
  machine?: string;
  now?: number;
  onRemove(): void;
  onReconnect(): void;
  onResume?(): void;
}) {
  const t = useT();
  // A deleted chat was on the tab's machine; one not connected names the peer acpmux had it on, never
  // this Mac's name (the handshake's for a chat of this Mac).
  const named = unavailable.reason === "deleted" ? machine : unavailable.machine;
  let title: string;
  let detail: string | undefined;
  let action: { label: string; run(): void; kind: string } | undefined;
  if (unavailable.reason === "deleted") {
    title = t("unavailable.deleted.title");
    detail = named ? t("unavailable.deleted.detailOn", { machine: named }) : t("unavailable.deleted.detail");
    action = { label: t("unavailable.remove"), run: onRemove, kind: "remove" };
  } else if (unavailable.reason === "connecting") {
    title = named ? t("unavailable.connecting.titleOn", { machine: named }) : t("unavailable.connecting.title");
  } else {
    title = named ? t("unavailable.offline.titleOn", { machine: named }) : t("unavailable.offline.title");
    detail =
      unavailable.lastSeen !== undefined
        ? t("unavailable.offline.lastSeen", { time: relativeTime(unavailable.lastSeen, now, currentLanguage()) })
        : t("unavailable.offline.detail");
    action = { label: t("unavailable.reconnect"), run: onReconnect, kind: "reconnect" };
  }
  return (
    <div
      className="acpmux-empty acpmux-unavailable"
      data-unavailable={unavailable.reason}
      role={unavailable.reason === "connecting" ? "status" : "alert"}
    >
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
        {unavailable.reason === "deleted" ? <path d="M13.5 18h9" /> : <path d="M11.5 18h1M17.5 18h1M23.5 18h1" />}
      </svg>
      <h2 className="acpmux-empty-title acpmux-unavailable-title">{title}</h2>
      {detail && <p className="acpmux-unavailable-detail">{detail}</p>}
      {action && (
        <div className="acpmux-unavailable-actions">
          <button type="button" className="acpmux-unavailable-action" data-action={action.kind} onClick={action.run}>
            {action.label}
          </button>
          {onResume && (
            <button type="button" className="acpmux-unavailable-action" data-action="resume" onClick={onResume}>
              {t("link.missing.resume")}
            </button>
          )}
        </div>
      )}
    </div>
  );
}
