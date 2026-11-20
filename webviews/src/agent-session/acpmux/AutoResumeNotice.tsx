import type { AutoResumeStatus } from "./autoResumeStatus";
import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import { rateLimitedLabel, retryLabel } from "./subagents/retryState";

/// One quiet line in the existing composer notice slot, shared by local and Cloud chats: only while
/// the daemon waits to retry, or holds the chat on its account's rate limit ("rate-limited until
/// 14:05Z", which says more than the retry's count). A turn it already resumed shows nothing; the
/// reply says so itself.
export function AutoResumeNotice({ state }: { state: AutoResumeStatus | undefined }) {
  const t = useT();
  const retry = state?.retry;
  const held = state?.rateLimitedUntil;
  const text = held !== undefined ? rateLimitedLabel(t, held) : retry ? retryLabel(t, retry) : undefined;
  return (
    <Notice id="auto-resume" tier="status" when={text}>
      <output className="acpmux-switch-notice" data-auto-resume={held !== undefined ? "held" : "waiting"}>
        {text ?? null}
      </output>
    </Notice>
  );
}
