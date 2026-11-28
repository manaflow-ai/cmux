// A connection's status pill: a dot in the state's tone and its words (connectStatus.ts). The app
// tiles put it in the shared connect card's head (agent-session/acpmux/ConnectCard.tsx `pill`), and
// the All connections list puts it on every row, so a connection reads the same everywhere.
// Leo, 2026-11-25: "are there deeper ergo things we can do wrt that? and other apps and whatnot?"
// The pill draws the words its host gives it (`label`): the host is the card or row that carries the
// state's one action (Connect, Reconnect), so a state like "Not connected" is said where it can be acted
// on (cmuxterm-hq docs/handbook/connection-state-with-no-action-or-bound.md). A host with no words of
// its own passes the pill's (`strings.t(CONNECT_STATUS_KEY[status])`, connectStatus.ts).
import { CONNECT_TONE, type ConnectStatus } from "./connectStatus";
import "./connectPill.css";

export function ConnectPill({
  status,
  label,
  hint,
  dataPrefix = "connect",
}: {
  status: ConnectStatus;
  /** The words for the state: the host's own (Connected · 14 tools) or the pill's (CONNECT_STATUS_KEY). */
  label: string;
  /** Hover text (an exact expiry time). */
  hint?: string;
  /** The pill carries `data-<prefix>-status`, so a host keeps its own selectors. */
  dataPrefix?: string;
}) {
  return (
    <span
      className="connect-pill"
      data-tone={CONNECT_TONE[status]}
      data-connect-pill={status}
      title={hint}
      {...{ [`data-${dataPrefix}-status`]: "" }}
    >
      <span className="connect-dot" aria-hidden="true" />
      <span className="connect-pill-text">{label}</span>
    </span>
  );
}
