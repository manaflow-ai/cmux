// An existing chat whose rows are not in yet draws a loading state where its messages go, and an
// error with Try Again when they could not be read (ui-state-fixes M3, the rule for every surface):
// never a blank transcript, never the new-chat hero, never "loading" forever.
import { Spinner } from "./conversation/icons";
import { chatLoad, type ChatLoad } from "./emptyStateModel";
import { useT } from "./i18n";
import { useLoadDeadline, type LoadDeadlineOptions } from "./loadDeadline";
import type { AcpmuxSnapshot } from "./model";

/// How long the attach may take before "Loading conversation…" shows: a chat that opens at once
/// never flashes it (a fast open draws its rows straight away).
export const CHAT_LOAD_REVEAL_MS = 400;

/// What the transcript area shows for the chat now (chatLoad), with its deadline: "loading" past
/// CHAT_LOAD_REVEAL_MS, "failed" once the open was refused or LOAD_DEADLINE_MS passed. `retry`
/// starts a fresh deadline and calls `reopen` (the client attaches the chat again).
export function useChatLoad(
  snapshot: AcpmuxSnapshot,
  newSession: boolean,
  reopen: () => void,
  options: { deadline?: LoadDeadlineOptions; reveal?: LoadDeadlineOptions } = {},
): { state: ChatLoad | undefined; retry(): void } {
  const waiting = chatLoad(snapshot, newSession) !== undefined;
  const deadline = useLoadDeadline(waiting, snapshot.sessionId, options.deadline);
  const revealed = useLoadDeadline(waiting, snapshot.sessionId, { ms: CHAT_LOAD_REVEAL_MS, ...options.reveal });
  const state = chatLoad(snapshot, newSession, deadline.timedOut);
  const { restart } = deadline;
  return {
    state: state === "loading" && !revealed.timedOut ? undefined : state,
    retry: () => {
      restart();
      reopen();
    },
  };
}

/// Centered where the chat's messages go, over its (empty) transcript.
export function ChatLoadState({ state, onRetry }: { state: ChatLoad; onRetry(): void }) {
  const t = useT();
  if (state === "loading")
    return (
      <output
        className="acpmux-empty acpmux-unavailable acpmux-chat-load"
        data-chat-load="loading"
        aria-busy="true"
        data-enter="fade"
      >
        <Spinner size={28} loading className="acpmux-unavailable-spinner" />
        <span className="acpmux-unavailable-detail">{t("chatLoad.loading")}</span>
      </output>
    );
  return (
    <div
      className="acpmux-empty acpmux-unavailable acpmux-chat-load"
      data-chat-load="failed"
      role="alert"
      data-enter="fade"
    >
      <h2 className="acpmux-empty-title acpmux-unavailable-title">{t("chatLoad.failed")}</h2>
      <div className="acpmux-unavailable-actions">
        <button type="button" className="acpmux-unavailable-action" data-action="retry" onClick={onRetry}>
          {t("chatLoad.retry")}
        </button>
      </div>
    </div>
  );
}
