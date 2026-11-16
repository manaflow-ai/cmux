import { usePageNow } from "../../ui/pageClock";
import { useT } from "./i18n";
import { type PeerReconnect, peerReconnectText } from "./peerReconnect";

/// A shared, visible-page clock: no timer while connected, hidden, or given a gallery clock.
export function PeerReconnectText({ progress, now }: { progress: PeerReconnect; now?: number }) {
  const t = useT();
  const ticking = usePageNow(now === undefined && progress.since !== undefined);
  return <span data-peer-reconnecting={progress.machine}>{peerReconnectText(progress, now ?? ticking, t)}</span>;
}
