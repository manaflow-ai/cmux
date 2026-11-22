import type { AutoResumeStatus } from "./autoResumeStatus";
import { useConnectionQuiet } from "../../ui/lasting";
import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import { retryLabel } from "./subagents/retryState";

/// One quiet line in the existing composer notice slot, shared by local and Cloud chats: only while
/// the daemon waits to retry, and only once that wait has lasted the shared bound
/// (`useConnectionQuiet`, schemas/notice-timing): acpmux retries on its own and a retry that runs
/// within it says nothing (Leo, 2026-11-14, asked connectivity to stay quiet). A turn it already
/// resumed shows nothing; the reply says so itself.
export function AutoResumeNotice({ state }: { state: AutoResumeStatus | undefined }) {
  const t = useT();
  const retry = state?.retry;
  const said = useConnectionQuiet(retry !== undefined);
  const shown = said ? retry : undefined;
  return (
    <Notice id="auto-resume" tier="status" when={shown}>
      <output className="acpmux-switch-notice" data-auto-resume="waiting">
        {shown ? retryLabel(t, shown) : null}
      </output>
    </Notice>
  );
}
