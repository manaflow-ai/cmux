import type { AutoResumeStatus } from "./autoResumeStatus";
import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import { retryLabel } from "./subagents/retryState";

/** One quiet line in the existing composer notice slot, shared by local and Cloud chats. */
export function AutoResumeNotice({ state }: { state: AutoResumeStatus | undefined }) {
  const t = useT();
  return (
    <Notice id="auto-resume" tier={state?.retry ? "status" : "hint"} when={state}>
      <output className="acpmux-switch-notice" data-auto-resume={state?.retry ? "waiting" : "resumed"}>
        {state?.retry
          ? retryLabel(t, state.retry)
          : state?.attempt
            ? t("retry.resumed", { attempt: state.attempt })
            : null}
      </output>
    </Notice>
  );
}
