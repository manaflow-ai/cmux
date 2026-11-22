import { useLinkDownSaid } from "./afterDelay";
import type { AutoResumeStatus } from "./autoResumeStatus";
import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import { retryLabel } from "./subagents/retryState";

/// One quiet line in the existing composer notice slot, shared by local and Cloud chats: only while
/// the daemon waits to retry. A turn it already resumed shows nothing; the reply says so itself.
/// The daemon retries on its own and nothing here waits on the person, so a wait shows only once it
/// has lasted the shared bound (afterDelay.ts LINK_DOWN_SAID_MS, 10 s): a retry that runs and works
/// inside it is never said (Leo, 2026-11-14: "i also want all our connectivity stuff to shut up and
/// load faster"). "Retrying (2/5) after a connection error" was drawn the moment the daemon scheduled it.
export function AutoResumeNotice({ state }: { state: AutoResumeStatus | undefined }) {
  const t = useT();
  const waiting = state?.retry;
  const said = useLinkDownSaid(waiting !== undefined);
  const retry = said ? waiting : undefined;
  return (
    <Notice id="auto-resume" tier="status" when={retry}>
      <output className="acpmux-switch-notice" data-auto-resume="waiting">
        {retry ? retryLabel(t, retry) : null}
      </output>
    </Notice>
  );
}
