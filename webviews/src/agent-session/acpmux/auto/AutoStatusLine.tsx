// RFD 0080: the status line beside RFD 0078's place button. It is empty while the chat simply runs
// where it is (and then takes no room); otherwise it says the one thing that is happening, with the
// action that fits. Pure presentation: the state arrives typed (computerStatus.ts), `nowMs` is the
// caller's clock so the elapsed seconds tick when the parent re-renders, and every action is a callback.
import "./computerAuto.css";
import { useT } from "../i18n";
import {
  statusChipText,
  statusLine,
  type ComputerStatus,
  type StatusActionId,
  type StatusLineText,
} from "./computerStatus";

/// `beside` sits next to the button (the RFD's pick); `row` is a quiet row above the composer;
/// `chip` is one pill with the headline only, the rest on hover.
export type StatusLineLook = "beside" | "row" | "chip";

export function AutoStatusLine({
  status,
  nowMs,
  look = "beside",
  offered,
  onAction,
}: {
  status: ComputerStatus;
  nowMs: number;
  look?: StatusLineLook;
  /// The actions the caller can run; the others are not drawn (every one when absent, as the gallery draws).
  offered?: readonly StatusActionId[];
  onAction(id: StatusActionId): void;
}) {
  const t = useT();
  const said: StatusLineText | undefined = statusLine(status, nowMs, t);
  if (!said) return null;
  const line = offered ? { ...said, actions: said.actions.filter((action) => offered.includes(action.id)) } : said;
  const chip = look === "chip";
  return (
    <output
      className="acpmux-computer-status"
      data-look={look}
      data-phase={status.phase}
      title={chip ? line.text : undefined}
    >
      <span className="acpmux-computer-status-text">{chip ? statusChipText(line) : line.text}</span>
      {line.actions.map((action) => (
        <button
          key={action.id}
          type="button"
          className="acpmux-computer-status-action"
          data-action={action.id}
          onClick={() => onAction(action.id)}
        >
          {action.label}
        </button>
      ))}
    </output>
  );
}
