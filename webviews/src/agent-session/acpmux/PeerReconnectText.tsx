import { usePageNow } from "../../ui/pageClock";
import { useT } from "./i18n";
import { type PeerReconnect, peerReconnectText } from "./peerReconnect";
import "./peerReconnect.css";

/// A shared, visible-page clock: no timer while connected, hidden, or given a gallery clock.
export function PeerReconnectText({ progress, now }: { progress: PeerReconnect; now?: number }) {
  const t = useT();
  const ticking = usePageNow(now === undefined && progress.since !== undefined);
  // Split at an interpolated marker, not the machine's text: names can occur in the translated
  // words too. The translation still owns word order, while only the name yields room to the timer.
  const [before, after] = peerReconnectText({ ...progress, machine: "\uFFFC" }, now ?? ticking, t).split("\uFFFC");
  return (
    <span className="acpmux-peer-reconnecting" data-peer-reconnecting={progress.machine}>
      {after === undefined ? (
        peerReconnectText(progress, now ?? ticking, t)
      ) : (
        <>
          <span className="acpmux-peer-reconnecting-part">{before}</span>
          <span className="acpmux-peer-reconnecting-name">{progress.machine}</span>
          <span className="acpmux-peer-reconnecting-part">{after}</span>
        </>
      )}
    </span>
  );
}
