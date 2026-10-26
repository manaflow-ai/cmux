import type { ReactNode } from "react";
import { Spinner } from "../conversation/icons";
import { Icon } from "../icons/Icon";

/** The slot stays in place; the problem label cannot resize it or move the header tools. Right's
 * Environment line uses this slot; Left uses the dedicated row below tabs. */
export function ChatHeaderStatus({
  status,
  detail,
  children,
  kind,
}: {
  status: string;
  detail?: string;
  kind?: "reconnecting" | "problem";
  children?: ReactNode;
}) {
  return (
    <div className="acpmux-header-status-slot">
      {status ? <StatusLabel status={status} detail={detail} kind={kind} /> : children}
    </div>
  );
}

/** The same label at the start of the tools, for a header in the pane's tab row: the slot's part of
 * that row is under the App's tabs, so a disconnected chat would show no warning at all. Without a
 * problem, Right's `children` (the compact Environment line) leads the tools instead. */
export function ChatHeaderInlineStatus({
  status,
  detail,
  children,
  kind,
}: {
  status: string;
  detail?: string;
  kind?: "reconnecting" | "problem";
  children?: ReactNode;
}) {
  return status ? <StatusLabel status={status} detail={detail} kind={kind} inline /> : (children ?? null);
}

function StatusLabel({
  status,
  detail,
  kind,
  inline,
}: {
  status: string;
  detail?: string;
  kind?: "reconnecting" | "problem";
  inline?: boolean;
}) {
  return (
    <output
      className={inline ? "acpmux-status acpmux-status--inline" : "acpmux-status"}
      /* tooltip-allow: the warning's detail, shown nowhere else */ title={detail}
      aria-label={detail}
    >
      {kind === "reconnecting" ? <Spinner size={13} loading /> : <Icon name="status.warning" size={13} />}
      <span>{status}</span>
    </output>
  );
}
