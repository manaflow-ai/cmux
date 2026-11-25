// A connection's status pill: a dot in the state's tone and its words (connectStatus.ts). The app
// tiles put it in the shared connect card's head (agent-session/acpmux/ConnectCard.tsx `pill`), and
// the All connections list puts it on every row, so a connection reads the same everywhere.
// Leo, 2026-11-25: "are there deeper ergo things we can do wrt that? and other apps and whatnot?"
import { CONNECT_STATUS_KEY, CONNECT_TONE, type ConnectStatus } from "./connectStatus";
import { useConnectStrings } from "./strings";
import "./connectPill.css";

export function ConnectPill({
  status,
  label,
  hint,
  dataPrefix = "connect",
}: {
  status: ConnectStatus;
  /** The host's own words for the state (Connected · 14 tools); else the pill's. */
  label?: string | null;
  /** Hover text (an exact expiry time). */
  hint?: string;
  /** The pill carries `data-<prefix>-status`, so a host keeps its own selectors. */
  dataPrefix?: string;
}) {
  const strings = useConnectStrings();
  return (
    <span
      className="connect-pill"
      data-tone={CONNECT_TONE[status]}
      data-connect-pill={status}
      title={hint}
      {...{ [`data-${dataPrefix}-status`]: "" }}
    >
      <span className="connect-dot" aria-hidden="true" />
      <span className="connect-pill-text">{label || strings.t(CONNECT_STATUS_KEY[status])}</span>
    </span>
  );
}
