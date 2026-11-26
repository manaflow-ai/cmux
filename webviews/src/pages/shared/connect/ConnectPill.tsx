// A connection's status pill: a dot in the state's tone and its words (connectStatus.ts). The app
// tiles put it in the shared connect card's head (agent-session/acpmux/ConnectCard.tsx `pill`), and
// the All connections list puts it on every row, so a connection reads the same everywhere.
// Leo, 2026-11-25: "are there deeper ergo things we can do wrt that? and other apps and whatnot?"
//
// The pill draws the words its host gives it, never its own: the host draws the connection's one
// action beside it (the card's button, the row's button), so the words and their action sit in one
// unit (scripts/cmux-next/check-connection-notices.py judges them there). The host's own words for
// the state (Connected · 14 tools), else `strings.t(CONNECT_STATUS_KEY[status])` (connectStatus.ts).
import { CONNECT_TONE, type ConnectStatus } from "./connectStatus";
import "./connectPill.css";

export function ConnectPill({
  status,
  text,
  hint,
  dataPrefix = "connect",
}: {
  status: ConnectStatus;
  /** Its words: the host's, else `CONNECT_STATUS_KEY[status]`'s. */
  text: string;
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
      <span className="connect-pill-text">{text}</span>
    </span>
  );
}
